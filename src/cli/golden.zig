//! The golden texts: each directory of tests/golden is one session's modules; every
//! program they declare is emitted in every dialect, and each text must be the one in
//! that directory's `expected/` (`zig build update-golden` writes them instead).
//!   golden ROOT [--update]

const std = @import("std");
const glint = @import("glint");

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) return 2;
    const update = args.len > 2 and std.mem.eql(u8, args[2], "--update");
    var err_buf: [4096]u8 = undefined;
    var err_w = std.Io.File.stderr().writer(io, &err_buf);
    const err = &err_w.interface;
    defer err.flush() catch {};

    var root = try std.Io.Dir.cwd().openDir(io, args[1], .{ .iterate = true });
    defer root.close(io);
    var dirs: std.ArrayList([]const u8) = .empty;
    var it = root.iterate();
    while (try it.next(io)) |e| if (e.kind == .directory) try dirs.append(arena, try arena.dupe(u8, e.name));
    std.mem.sort([]const u8, dirs.items, {}, lessThan);

    var texts: usize = 0;
    var differ: usize = 0;
    for (dirs.items) |name| {
        var dir = try root.openDir(io, name, .{ .iterate = true });
        defer dir.close(io);
        var files: std.ArrayList([]const u8) = .empty;
        var fit = dir.iterate();
        while (try fit.next(io)) |e| if (e.kind == .file and std.mem.endsWith(u8, e.name, ".glint")) try files.append(arena, try arena.dupe(u8, e.name));
        std.mem.sort([]const u8, files.items, {}, lessThan);

        var s: glint.Session = .init(gpa, .{});
        defer s.deinit();
        for (files.items) |f| {
            const text = try dir.readFileAlloc(io, f, gpa, .limited(1 << 20));
            defer gpa.free(text);
            _ = try s.addSource(f, text);
        }
        try s.analyze();
        for (s.diagnostics()) |d| try d.render(err, s.source(d.span.src));
        if (s.errorCount() != 0) {
            try err.print("golden: {s} does not check\n", .{name});
            return 1;
        }
        dir.createDirPath(io, "expected") catch {};
        var expected = try dir.openDir(io, "expected", .{});
        defer expected.close(io);
        for (s.programs) |*p| {
            if (p.is_template) continue;
            for ([_]glint.glsl.Dialect{ .es300, .glsl330 }) |dialect| for ([_]glint.Ir.Stage{ .vertex, .fragment }) |stage| {
                var e = try glint.glsl.emit(&s, p, stage, dialect, gpa);
                defer e.deinit(gpa);
                const file = try std.fmt.allocPrint(arena, "{s}.{t}.{s}", .{ p.name, dialect, if (stage == .vertex) "vert" else "frag" });
                texts += 1;
                if (update) {
                    try expected.writeFile(io, .{ .sub_path = file, .data = e.text });
                    continue;
                }
                const want = expected.readFileAlloc(io, file, gpa, .limited(1 << 20)) catch {
                    try err.print("golden: {s}/expected/{s} is missing (zig build update-golden)\n", .{ name, file });
                    differ += 1;
                    continue;
                };
                defer gpa.free(want);
                if (!std.mem.eql(u8, want, e.text)) {
                    try err.print("golden: {s}/expected/{s} differs from what is emitted now:\n{s}\n", .{ name, file, e.text });
                    differ += 1;
                }
            };
        }
    }
    if (update) {
        try err.print("golden: wrote {d} texts\n", .{texts});
        return 0;
    }
    if (differ > 0) return 1;
    try err.print("golden: {d} texts as expected\n", .{texts});
    return 0;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}
