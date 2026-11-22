//! The `glint` command: the library on files. It is the only part of the package that
//! touches the file system.
//!
//!   glint parse FILE...   parse each file; print diagnostics and how many files parsed
//!   glint check FILE...   check the files as the modules of one session: print
//!                         diagnostics, how many modules check and programs link
//!   glint emit [--dialect es300|glsl330] --out DIR FILE...
//!                         check the files, and write each linked program's stages as
//!                         DIR/NAME.vert and DIR/NAME.frag
//!   glint print [--shape] FILE
//!                         print FILE's tree as canonical text (comments are not kept;
//!                         exit 1 if it does not parse); --shape puts every operand in
//!                         parentheses, to compare two trees

const std = @import("std");
const glint = @import("glint");

const usage =
    \\usage: glint parse FILE...
    \\       glint check FILE...
    \\       glint emit [--dialect es300|glsl330] --out DIR FILE...
    \\       glint print [--shape] FILE
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
    if (std.mem.eql(u8, cmd, "print")) {
        const shape = files.len == 2 and std.mem.eql(u8, files[0], "--shape");
        if (files.len == 1 or shape) {
            const options: glint.Ast.PrintOptions = .{ .all_parens = shape };
            return if (try parseFile(gpa, io, files[files.len - 1], err, .{ .w = out, .options = options })) 0 else 1;
        }
    }
    try err.writeAll(usage);
    return 2;
}

/// Parses one file, rendering its diagnostics to `err`; with `print`, writes its canonical
/// form there when it parsed. Returns whether it parsed without errors.
const Print = struct { w: *std.Io.Writer, options: glint.Ast.PrintOptions };

fn parseFile(gpa: std.mem.Allocator, io: std.Io, path: []const u8, err: *std.Io.Writer, print: ?Print) !bool {
    const limits: glint.Limits = .{};
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(limits.source_bytes)) catch |e| {
        try err.print("{s}: cannot read: {t}\n", .{ path, e });
        return false;
    };
    defer gpa.free(text);
    var src = try glint.Source.init(gpa, path, text);
    defer src.deinit(gpa);
    var diags: glint.Diagnostic.List = .{ .limit = limits.diagnostics };
    defer diags.deinit(gpa);
    var ast = try glint.parse(gpa, @fromBackingInt(@intCast(0)), text, limits, &diags);
    defer ast.deinit(gpa);
    for (diags.items.items) |d| try d.render(err, &src);
    if (diags.dropped > 0) try err.print("{s}: {d} more diagnostics\n", .{ path, diags.dropped });
    if (diags.errors > 0) return false;
    if (print) |p| try ast.printWith(p.w, p.options);
    return true;
}

fn check(gpa: std.mem.Allocator, io: std.Io, files: []const [:0]const u8, out: *std.Io.Writer, err: *std.Io.Writer) !u8 {
    var s: glint.Session = .init(gpa, .{});
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

fn load(gpa: std.mem.Allocator, io: std.Io, s: *glint.Session, files: []const [:0]const u8, err: *std.Io.Writer) !bool {
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
    var dialect: glint.glsl.Dialect = .glsl330;
    var dir: ?[]const u8 = null;
    var i: usize = 0;
    while (i + 1 < raw.len and std.mem.startsWith(u8, raw[i], "--")) : (i += 2) {
        if (std.mem.eql(u8, raw[i], "--out")) {
            dir = raw[i + 1];
        } else if (std.mem.eql(u8, raw[i], "--dialect")) {
            dialect = std.meta.stringToEnum(glint.glsl.Dialect, raw[i + 1]) orelse {
                try err.print("unknown dialect `{s}` (es300, glsl330)\n", .{raw[i + 1]});
                return 2;
            };
        } else break;
    }
    const out_dir = dir orelse {
        try err.writeAll(usage);
        return 2;
    };
    const files = raw[i..];
    var s: glint.Session = .init(gpa, .{});
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
        for ([_]glint.Ir.Stage{ .vertex, .fragment }) |stage| {
            var e = try glint.glsl.emit(&s, p, stage, dialect, gpa);
            defer e.deinit(gpa);
            const name = try std.fmt.allocPrint(s.arena(), "{s}.{s}", .{ p.name, if (stage == .vertex) "vert" else "frag" });
            try d.writeFile(io, .{ .sub_path = name, .data = e.text });
        }
        written += 1;
    }
    try out.print("{d} of {d} programs emitted ({t})\n", .{ written, programs, dialect });
    return if (s.errorCount() == 0) 0 else 1;
}
