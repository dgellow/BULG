//! The `bulg` command: the library on files. It is the only part of the package that
//! touches the file system.
//!
//!   bulg parse FILE...   parse each file; print diagnostics and how many files parsed
//!   bulg check [--meta-schema FILE] FILE...
//!                         check the files as the modules of one session: print
//!                         diagnostics, how many modules check and programs link
//!   bulg emit [--dialect es300|glsl330|msl] --out DIR FILE...
//!                         check the files, and write each linked program's stages as
//!                         DIR/NAME.vert and DIR/NAME.frag
//!   bulg gen --root DIR [--dialect D]... [--meta-schema FILE] --out FILE [--depfile FILE]
//!                         the shader tree under DIR (every .bulg file, named by its
//!                         path in DIR) as one Zig source: texts and reflection
//!   bulg set-default --root DIR [--meta-schema FILE] MODULE NAME VALUE...
//!   bulg set-default --root DIR [--meta-schema FILE] --from FILE
//!                         write a param's default into its source (MODULE is its path
//!                         in DIR without .bulg); --from takes lines `MODULE NAME
//!                         VALUE...` (`#` starts a comment). The tree is checked with
//!                         the new values first: on an error nothing is written
//!
//! `--meta-schema` names the host's metadata keys, as ZON (bulg.MetaSchema): with it, a
//! key that neither BULG nor the schema has is an error.
//!   bulg reflect FILE...  check the files, and print every program's reflection as JSON
//!                         (bulg.reflection/1)
//!   bulg print [--shape] FILE
//!                         print FILE's tree as canonical text (comments are not kept;
//!                         exit 1 if it does not parse); --shape puts every operand in
//!                         parentheses, to compare two trees

const std = @import("std");
const bulg = @import("bulg");

const usage =
    \\usage: bulg parse FILE...
    \\       bulg check [--meta-schema FILE] FILE...
    \\       bulg emit [--dialect es300|glsl330|msl] --out DIR FILE...
    \\       bulg gen --root DIR [--dialect D]... [--meta-schema FILE] --out FILE [--depfile FILE]
    \\       bulg set-default --root DIR [--meta-schema FILE] (MODULE NAME VALUE... | --from FILE)
    \\       bulg reflect FILE...
    \\       bulg print [--shape] FILE
    \\
;

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var out_buf: [64 * 1024]u8 = undefined;
    var out_w = std.Io.File.stdout().writer(io, &out_buf);
    const out = &out_w.interface;
    var err_buf: [16 * 1024]u8 = undefined;
    var err_w = std.Io.File.stderr().writer(io, &err_buf);
    const err = &err_w.interface;
    defer out.flush() catch {};
    defer err.flush() catch {};

    if (args.len < 3) {
        try err.writeAll(usage);
        return 2;
    }
    const cmd = args[1];
    const files = args[2..];
    if (std.mem.eql(u8, cmd, "parse")) {
        var ok: usize = 0;
        for (files) |path| {
            if (try parseFile(gpa, io, path, err, null)) ok += 1;
        }
        try out.print("{d} of {d} files parse\n", .{ ok, files.len });
        return if (ok == files.len) 0 else 1;
    }
    if (std.mem.eql(u8, cmd, "check")) return check(gpa, io, files, out, err);
    if (std.mem.eql(u8, cmd, "emit")) return emit(gpa, io, files, out, err);
    if (std.mem.eql(u8, cmd, "gen")) return gen(gpa, io, files, err);
    if (std.mem.eql(u8, cmd, "set-default")) return setDefault(gpa, io, files, out, err);
    if (std.mem.eql(u8, cmd, "reflect")) {
        var s: bulg.Session = .init(gpa, .{});
        defer s.deinit();
        if (!try load(gpa, io, &s, files, err)) return 1;
        try s.analyze();
        for (s.diagnostics()) |d| try d.render(err, s.source(d.span.src));
        if (s.errorCount() > 0) return 1;
        bulg.reflection_json.write(&s, out, s.arena()) catch |e| switch (e) {
            error.NotChecked => unreachable, // no errors
            else => |x| return x,
        };
        try out.writeByte('\n');
        return 0;
    }
    if (std.mem.eql(u8, cmd, "print")) {
        const shape = files.len == 2 and std.mem.eql(u8, files[0], "--shape");
        if (files.len == 1 or shape) {
            const options: bulg.Ast.PrintOptions = .{ .all_parens = shape };
            return if (try parseFile(gpa, io, files[files.len - 1], err, .{ .w = out, .options = options })) 0 else 1;
        }
    }
    try err.writeAll(usage);
    return 2;
}

/// Parses one file, rendering its diagnostics to `err`; with `print`, writes its canonical
/// form there when it parsed. Returns whether it parsed without errors.
const Print = struct { w: *std.Io.Writer, options: bulg.Ast.PrintOptions };

fn parseFile(gpa: std.mem.Allocator, io: std.Io, path: []const u8, err: *std.Io.Writer, print: ?Print) !bool {
    const limits: bulg.Limits = .{};
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(limits.source_bytes)) catch |e| {
        try err.print("{s}: cannot read: {t}\n", .{ path, e });
        return false;
    };
    defer gpa.free(text);
    var src = try bulg.Source.init(gpa, path, text);
    defer src.deinit(gpa);
    var diags: bulg.Diagnostic.List = .{ .limit = limits.diagnostics };
    defer diags.deinit(gpa);
    var ast = try bulg.parse(gpa, @fromBackingInt(@intCast(0)), text, limits, &diags);
    defer ast.deinit(gpa);
    for (diags.items.items) |d| try d.render(err, &src);
    if (diags.dropped > 0) try err.print("{s}: {d} more diagnostics\n", .{ path, diags.dropped });
    if (diags.errors > 0) return false;
    if (print) |p| try ast.printWith(p.w, p.options);
    return true;
}

fn check(gpa: std.mem.Allocator, io: std.Io, raw: []const [:0]const u8, out: *std.Io.Writer, err: *std.Io.Writer) !u8 {
    var schema_arena: std.heap.ArenaAllocator = .init(gpa);
    defer schema_arena.deinit();
    var files = raw;
    var schema: ?bulg.MetaSchema = null;
    if (files.len >= 2 and std.mem.eql(u8, files[0], "--meta-schema")) {
        schema = (try loadSchema(gpa, io, schema_arena.allocator(), files[1], err)) orelse return 1;
        files = files[2..];
    }
    var s: bulg.Session = .init(gpa, .{ .meta_schema = if (schema) |*sc| sc else null });
    defer s.deinit();
    if (!try load(gpa, io, &s, files, err)) return 1;
    try s.analyze();
    const bad = try s.arena().alloc(bool, files.len);
    @memset(bad, false);
    for (s.diagnostics()) |d| {
        try d.render(err, s.source(d.span.src));
        bad[@backingInt(d.span.src)] = true;
    }
    if (s.diags.dropped > 0) try err.print("{d} more diagnostics\n", .{s.diags.dropped});
    var ok: usize = 0;
    for (bad) |b| ok += @intFromBool(!b);
    var programs: usize = 0;
    var linked: usize = 0;
    for (s.programs) |*p| {
        if (p.is_template) continue;
        programs += 1;
        if (s.programChecked(p)) linked += 1;
    }
    try out.print("{d} of {d} modules check, {d} of {d} programs link\n", .{ ok, files.len, linked, programs });
    return if (s.errorCount() == 0) 0 else 1;
}

fn load(gpa: std.mem.Allocator, io: std.Io, s: *bulg.Session, files: []const [:0]const u8, err: *std.Io.Writer) !bool {
    for (files) |path| {
        const text = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(s.limits.source_bytes)) catch |e| {
            try err.print("{s}: cannot read: {t}\n", .{ path, e });
            return false;
        };
        defer gpa.free(text);
        _ = try s.addSource(path, text);
    }
    return true;
}

fn emit(gpa: std.mem.Allocator, io: std.Io, raw: []const [:0]const u8, out: *std.Io.Writer, err: *std.Io.Writer) !u8 {
    var dialect: bulg.emit.Dialect = .glsl330;
    var dir: ?[]const u8 = null;
    var i: usize = 0;
    while (i + 1 < raw.len and std.mem.startsWith(u8, raw[i], "--")) : (i += 2) {
        if (std.mem.eql(u8, raw[i], "--out")) {
            dir = raw[i + 1];
        } else if (std.mem.eql(u8, raw[i], "--dialect")) {
            dialect = std.meta.stringToEnum(bulg.emit.Dialect, raw[i + 1]) orelse {
                try err.print("unknown dialect `{s}` (es300, glsl330, msl)\n", .{raw[i + 1]});
                return 2;
            };
        } else break;
    }
    const out_dir = dir orelse {
        try err.writeAll(usage);
        return 2;
    };
    const files = raw[i..];
    var s: bulg.Session = .init(gpa, .{});
    defer s.deinit();
    if (!try load(gpa, io, &s, files, err)) return 1;
    try s.analyze();
    for (s.diagnostics()) |d| try d.render(err, s.source(d.span.src));
    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, out_dir) catch {};
    var d = try cwd.openDir(io, out_dir, .{});
    defer d.close(io);
    var written: usize = 0;
    var programs: usize = 0;
    for (s.programs) |*p| {
        if (p.is_template) continue;
        programs += 1;
        if (!s.programChecked(p)) continue;
        const ok = for ([_]bulg.Ir.Stage{ .vertex, .fragment }) |stage| {
            var why: []const u8 = "";
            var e = bulg.emit.emitWhy(&s, p, stage, dialect, gpa, &why) catch |x| switch (x) {
                error.Unsupported => {
                    try err.print("{s} ({t}): {t} cannot say {s} yet\n", .{ p.name, stage, dialect, why });
                    break false;
                },
                else => |y| return y,
            };
            defer e.deinit(gpa);
            const name = try std.fmt.allocPrint(s.arena(), "{s}.{s}", .{ p.name, dialect.extension(stage) });
            try d.writeFile(io, .{ .sub_path = name, .data = e.text });
        } else true;
        if (ok) written += 1;
    }
    try out.print("{d} of {d} programs emitted ({t})\n", .{ written, programs, dialect });
    return if (s.errorCount() == 0 and written == programs) 0 else 1;
}

fn gen(gpa: std.mem.Allocator, io: std.Io, raw: []const [:0]const u8, err: *std.Io.Writer) !u8 {
    var root: ?[]const u8 = null;
    var out_path: ?[]const u8 = null;
    var dep_path: ?[]const u8 = null;
    var schema_path: ?[]const u8 = null;
    var dialects: std.ArrayList(bulg.emit.Dialect) = .empty;
    defer dialects.deinit(gpa);
    var i: usize = 0;
    while (i + 1 < raw.len) : (i += 2) {
        const v = raw[i + 1];
        if (std.mem.eql(u8, raw[i], "--root")) {
            root = v;
        } else if (std.mem.eql(u8, raw[i], "--out")) {
            out_path = v;
        } else if (std.mem.eql(u8, raw[i], "--depfile")) {
            dep_path = v;
        } else if (std.mem.eql(u8, raw[i], "--meta-schema")) {
            schema_path = v;
        } else if (std.mem.eql(u8, raw[i], "--dialect")) {
            try dialects.append(gpa, std.meta.stringToEnum(bulg.emit.Dialect, v) orelse {
                try err.print("unknown dialect `{s}` (es300, glsl330, msl)\n", .{v});
                return 2;
            });
        } else break;
    }
    if (root == null or out_path == null or i != raw.len) {
        try err.writeAll(usage);
        return 2;
    }
    if (dialects.items.len == 0) try dialects.appendSlice(gpa, &.{ .es300, .glsl330 });

    var schema_arena: std.heap.ArenaAllocator = .init(gpa);
    defer schema_arena.deinit();
    var schema: ?bulg.MetaSchema = null;
    if (schema_path) |sp| schema = (try loadSchema(gpa, io, schema_arena.allocator(), sp, err)) orelse return 1;
    var s: bulg.Session = .init(gpa, .{ .meta_schema = if (schema) |*sc| sc else null });
    defer s.deinit();
    const a = s.arena();
    const tree = try readTree(gpa, io, a, root.?, s.limits);
    for (tree) |f| _ = try s.addSource(f.name, f.text);
    try s.analyze();
    for (s.diagnostics()) |d| try d.render(err, s.source(d.span.src));
    if (s.errorCount() > 0) {
        try err.print("bulg gen: {d} errors in {s}\n", .{ s.errorCount(), root.? });
        return 1;
    }
    const text = bulg.zig_gen.generate(&s, .{ .dialects = dialects.items }, gpa) catch |e| switch (e) {
        error.NotChecked => unreachable, // no errors
        error.OutOfMemory => return error.OutOfMemory,
        error.Unsupported => {
            try err.print("bulg gen: a program the dialects asked for cannot say (bulg emit names it)\n", .{});
            return 1;
        },
    };
    defer gpa.free(text);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path.?, .data = text });

    if (dep_path) |dp| {
        // `out: every source`, for the build system to know when to run again
        var dep: std.Io.Writer.Allocating = .init(gpa);
        defer dep.deinit();
        try dep.writer.print("{s}:", .{out_path.?});
        for (tree) |f| {
            const full = try std.fs.path.join(a, &.{ root.?, f.path });
            try dep.writer.writeAll(" ");
            for (full) |ch| {
                if (ch == ' ') try dep.writer.writeByte('\\');
                try dep.writer.writeByte(ch);
            }
        }
        try dep.writer.writeByte('\n');
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dp, .data = dep.written() });
    }
    return 0;
}

/// A file of a shader tree: its path in the root, its module name (`/` on every system),
/// its text.
const TreeFile = struct { path: []const u8, name: []const u8, text: []const u8 };

/// Every .bulg file under `root`, in a fixed order, read into `a`.
fn readTree(gpa: std.mem.Allocator, io: std.Io, a: std.mem.Allocator, root: []const u8, limits: bulg.Limits) ![]TreeFile {
    var dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    var paths: std.ArrayList([]const u8) = .empty;
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |e| {
        if (e.kind == .file and std.mem.endsWith(u8, e.path, ".bulg")) try paths.append(a, try a.dupe(u8, e.path));
    }
    std.mem.sort([]const u8, paths.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.lt);
    const out = try a.alloc(TreeFile, paths.items.len);
    for (paths.items, out) |p, *f| {
        const name = try a.dupe(u8, p);
        std.mem.replaceScalar(u8, name, '\\', '/');
        f.* = .{ .path = p, .name = name, .text = try dir.readFileAlloc(io, p, a, .limited(limits.source_bytes)) };
    }
    return out;
}

/// The host's metadata schema from a ZON file, or null (and why, on `err`).
fn loadSchema(gpa: std.mem.Allocator, io: std.Io, a: std.mem.Allocator, path: []const u8, err: *std.Io.Writer) !?bulg.MetaSchema {
    const text = std.Io.Dir.cwd().readFileAllocOptions(io, path, a, .limited(1 << 20), .of(u8), 0) catch |e| {
        try err.print("{s}: cannot read: {t}\n", .{ path, e });
        return null;
    };
    var diags: std.zon.parse.Diagnostics = .{ .errors = &.{} };
    var why: []const u8 = "";
    return bulg.MetaSchema.parse(gpa, a, text, &diags, &why) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseZon => {
            try err.print("{f}\n", .{diags.fmt(path)});
            return null;
        },
        error.BadSchema => {
            try err.print("{s}: {s}\n", .{ path, why });
            return null;
        },
    };
}

/// One value to write: a param of a module.
const Change = struct { module: []const u8, name: []const u8, values: []const f64 };

fn setDefault(gpa: std.mem.Allocator, io: std.Io, raw: []const [:0]const u8, out: *std.Io.Writer, err: *std.Io.Writer) !u8 {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var root: ?[]const u8 = null;
    var schema_path: ?[]const u8 = null;
    var from: ?[]const u8 = null;
    var i: usize = 0;
    while (i + 1 < raw.len and std.mem.startsWith(u8, raw[i], "--")) : (i += 2) {
        const v = raw[i + 1];
        if (std.mem.eql(u8, raw[i], "--root")) {
            root = v;
        } else if (std.mem.eql(u8, raw[i], "--meta-schema")) {
            schema_path = v;
        } else if (std.mem.eql(u8, raw[i], "--from")) {
            from = v;
        } else break;
    }
    const rest = raw[i..];
    if (root == null or (from == null and rest.len < 3) or (from != null and rest.len > 0)) {
        try err.writeAll(usage);
        return 2;
    }
    var changes: std.ArrayList(Change) = .empty;
    if (from) |f| {
        const text = std.Io.Dir.cwd().readFileAlloc(io, f, a, .limited(1 << 20)) catch |e| {
            try err.print("{s}: cannot read: {t}\n", .{ f, e });
            return 1;
        };
        var lines = std.mem.splitScalar(u8, text, '\n');
        var ln: usize = 0;
        while (lines.next()) |line_raw| {
            ln += 1;
            const line = if (std.mem.indexOfScalar(u8, line_raw, '#')) |h| line_raw[0..h] else line_raw;
            var words: std.ArrayList([]const u8) = .empty;
            var it = std.mem.tokenizeAny(u8, line, " \t\r");
            while (it.next()) |w| try words.append(a, w);
            if (words.items.len == 0) continue;
            if (words.items.len < 3) {
                try err.print("{s}:{d}: a line is `MODULE NAME VALUE...`\n", .{ f, ln });
                return 1;
            }
            const c = (try change(a, words.items, err)) orelse {
                try err.print("{s}:{d}: that line\n", .{ f, ln });
                return 1;
            };
            try changes.append(a, c);
        }
    } else {
        try changes.append(a, (try change(a, rest, err)) orelse return 1);
    }

    var schema: ?bulg.MetaSchema = null;
    if (schema_path) |sp| schema = (try loadSchema(gpa, io, a, sp, err)) orelse return 1;
    const limits: bulg.Limits = .{};
    const tree = try readTree(gpa, io, a, root.?, limits);
    const texts = try a.alloc([]const u8, tree.len);
    for (tree, texts) |f, *t| t.* = f.text;
    for (changes.items) |c| {
        const k = for (tree, 0..) |f, k| {
            if (std.mem.eql(u8, bulg.Session.moduleName(f.name), c.module)) break k;
        } else {
            try err.print("bulg set-default: no module `{s}` in {s}\n", .{ c.module, root.? });
            return 1;
        };
        const r = try bulg.edit.setDefault(a, texts[k], c.name, c.values);
        switch (r) {
            .text => |t| texts[k] = t,
            .problem => |p| {
                switch (p.why) {
                    .not_parsed => try err.print("bulg set-default: {s} does not parse\n", .{tree[k].path}),
                    .no_param => try err.print("bulg set-default: {s} declares no param `{s}`\n", .{ tree[k].path, c.name }),
                    .wrong_count => try err.print("bulg set-default: `{s}` takes {d} value{s}, not {d}\n", .{ c.name, p.want, if (p.want == 1) "" else "s", c.values.len }),
                    .unsupported_type => try err.print("bulg set-default: `{s}` is of a type set-default cannot write (a scalar or a vector can be)\n", .{c.name}),
                    .bad_value => try err.print("bulg set-default: a value for `{s}` is not one of its type\n", .{c.name}),
                }
                return 1;
            },
        }
    }
    // the tree with the new values must check, metadata included
    var s: bulg.Session = .init(gpa, .{ .meta_schema = if (schema) |*sc| sc else null });
    defer s.deinit();
    for (tree, texts) |f, t| _ = try s.addSource(f.name, t);
    try s.analyze();
    for (s.diagnostics()) |d| try d.render(err, s.source(d.span.src));
    if (s.errorCount() > 0) {
        try err.print("bulg set-default: with the new values, {s} has {d} error{s}; nothing written\n", .{ root.?, s.errorCount(), if (s.errorCount() == 1) "" else "s" });
        return 1;
    }
    var dir = try std.Io.Dir.cwd().openDir(io, root.?, .{});
    defer dir.close(io);
    for (tree, texts) |f, t| {
        if (t.ptr == f.text.ptr) continue;
        try dir.writeFile(io, .{ .sub_path = f.path, .data = t });
    }
    for (changes.items) |c| {
        try out.print("{s}: {s} =", .{ c.module, c.name });
        for (c.values) |v| try out.print(" {d}", .{@as(f32, @floatCast(v))});
        try out.writeByte('\n');
    }
    return 0;
}

/// `MODULE NAME VALUE...` as a change, or null (and why, on `err`).
fn change(a: std.mem.Allocator, words: []const []const u8, err: *std.Io.Writer) !?Change {
    const values = try a.alloc(f64, words.len - 2);
    for (words[2..], values) |w, *v| {
        v.* = if (std.mem.eql(u8, w, "true")) 1 else if (std.mem.eql(u8, w, "false")) 0 else std.fmt.parseFloat(f64, std.mem.trimEnd(u8, w, "u")) catch {
            try err.print("bulg set-default: `{s}` is not a number\n", .{w});
            return null;
        };
    }
    return .{ .module = bulg.Session.moduleName(words[0]), .name = words[1], .values = values };
}
