//! The `glint` command: the library on files. It is the only part of the package that
//! touches the file system.
//!
//!   glint parse FILE...   parse each file; print diagnostics and how many files parsed
//!   glint print [--shape] FILE
//!                         print FILE's tree as canonical text (comments are not kept;
//!                         exit 1 if it does not parse); --shape puts every operand in
//!                         parentheses, to compare two trees

const std = @import("std");
const glint = @import("glint");

const usage =
    \\usage: glint parse FILE...
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
