//! A compilation: sources in, checked modules and programs out. Everything a session makes
//! lives in its arena and goes with `deinit`; the caller's allocator is used for nothing
//! else.
//!
//!     var s: Session = .init(gpa, .{});
//!     defer s.deinit();
//!     _ = try s.addSource("common.bulg", text);
//!     try s.analyze();
//!     for (s.diagnostics()) |d| ...

const std = @import("std");
const Source = @import("Source.zig");
const Diagnostic = @import("Diagnostic.zig");
const Limits = @import("limits.zig").Limits;
const Ast = @import("syntax/Ast.zig");
const Parser = @import("syntax/Parser.zig");
const types = @import("sema/types.zig");
const Ir = @import("ir/Ir.zig");
const Checker = @import("sema/Checker.zig");
const meta = @import("sema/meta.zig");

pub const Error = error{OutOfMemory};

pub const Options = struct {
    limits: Limits = .{},
    /// the host's metadata keys: with a schema, keys neither it nor BULG has are errors
    /// (sema/meta.zig). It must outlive the session.
    meta_schema: ?*const meta.Schema = null,
};

const Session = @This();

arena_state: std.heap.ArenaAllocator,
limits: Limits,
meta_schema: ?*const meta.Schema,
sources: std.ArrayList(Source) = .empty,
asts: std.ArrayList(Ast) = .empty,
diags: Diagnostic.List,
pool: types.Pool = .{},
/// after `analyze`: one module per source, in the order they were added
modules: []const Ir.Module = &.{},
/// after `analyze`: every `program` of every module
programs: []const Ir.Program = &.{},
analyzed: bool = false,

pub fn init(gpa: std.mem.Allocator, options: Options) Session {
    return .{
        .arena_state = .init(gpa),
        .limits = options.limits,
        .meta_schema = options.meta_schema,
        .diags = .{ .limit = options.limits.diagnostics },
    };
}

pub fn deinit(s: *Session) void {
    s.arena_state.deinit();
    s.* = undefined;
}

pub fn arena(s: *Session) std.mem.Allocator {
    return s.arena_state.allocator();
}

/// Adds and parses a source. `path` names the module: `art/art_core.bulg` is the module
/// `art/art_core` (a path without `.bulg` is the module's name as it is). The text is
/// copied.
pub fn addSource(s: *Session, path: []const u8, text: []const u8) Error!Source.Id {
    std.debug.assert(!s.analyzed);
    const a = s.arena();
    const id: Source.Id = @fromBackingInt(@intCast(@as(u32, @intCast(s.sources.items.len))));
    const own_path = try a.dupe(u8, path);
    const own_text = try a.dupe(u8, text);
    try s.sources.append(a, try Source.init(a, own_path, own_text));
    try s.asts.append(a, try Parser.parse(a, id, own_text, s.limits, &s.diags));
    return id;
}

/// Checks every module and program. Call once, after the last `addSource`.
pub fn analyze(s: *Session) Error!void {
    std.debug.assert(!s.analyzed);
    s.analyzed = true;
    try Checker.run(s);
    try meta.check(s, s.meta_schema);
}

pub fn diagnostics(s: *const Session) []const Diagnostic {
    return s.diags.items.items;
}

pub fn errorCount(s: *const Session) u32 {
    return s.diags.errors;
}

pub fn source(s: *const Session, id: Source.Id) *const Source {
    return &s.sources.items[@backingInt(id)];
}

/// The module name of a source path.
pub fn moduleName(path: []const u8) []const u8 {
    return if (std.mem.endsWith(u8, path, ".bulg")) path[0 .. path.len - ".bulg".len] else path;
}

/// The module named `name`, if there is one.
pub fn findModule(s: *const Session, name: []const u8) ?u32 {
    for (s.sources.items, 0..) |src, i| {
        if (std.mem.eql(u8, moduleName(src.path), name)) return @intCast(i);
    }
    return null;
}

/// Whether a stage of a program can be emitted: it linked, and neither its modules nor the
/// module declaring the program have errors.
pub fn stageChecked(s: *const Session, prog: *const Ir.Program, stage: Ir.StageInfo) bool {
    if (s.diags.errorsIn(s.modules[prog.module].src) > 0) return false;
    for (stage.modules) |m| if (s.diags.errorsIn(s.modules[m].src) > 0) return false;
    return true;
}

/// Whether both stages of a program can be emitted.
pub fn programChecked(s: *const Session, prog: *const Ir.Program) bool {
    const v = prog.vertex orelse return false;
    const f = prog.fragment orelse return false;
    return s.stageChecked(prog, v) and s.stageChecked(prog, f);
}

pub fn findProgram(s: *const Session, name: []const u8) ?*const Ir.Program {
    for (s.programs) |*p| if (std.mem.eql(u8, p.name, name)) return p;
    return null;
}
