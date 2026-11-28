//! BULG: a small shading language and its compiler, in Zig, for programs that want one
//! shader source for Metal, WebGPU and OpenGL ES / WebGL 2. See README.md.
//!
//! v0.1 is the front end: the lexer, the parser and its printer, the checker and the typed
//! IR, in a `Session`. The emitters, reflection and the interpreter follow (CHANGELOG.md).
//!
//! The core uses nothing but the allocator it is given: no globals, no I/O, no threads,
//! no clock, no libc. It builds for any target, `wasm32-freestanding` included.

const std = @import("std");

pub const version: std.SemanticVersion = .{ .major = 0, .minor = 1, .patch = 0 };

pub const Source = @import("Source.zig");
pub const Span = Source.Span;
pub const SourceId = Source.Id;
pub const Diagnostic = @import("Diagnostic.zig");
pub const Limits = @import("limits.zig").Limits;
pub const Token = @import("syntax/Token.zig");
pub const Lexer = @import("syntax/Lexer.zig");
pub const Ast = @import("syntax/Ast.zig");
pub const Parser = @import("syntax/Parser.zig");
pub const parse = Parser.parse;
pub const Session = @import("Session.zig");
pub const Ir = @import("ir/Ir.zig");
pub const types = @import("sema/types.zig");
pub const builtins = @import("sema/builtins.zig");
/// Metadata keys: the core's, and the `Schema` a host gives for its own.
pub const meta = @import("sema/meta.zig");
pub const MetaSchema = meta.Schema;
/// The emitters: GLSL ES 3.00, GLSL 3.30 and MSL.
pub const emit = @import("emit/emit.zig");
pub const reflect = @import("reflect/Reflection.zig");
pub const zig_gen = @import("reflect/zig.zig");
pub const reflection_json = @import("reflect/json.zig");
/// Edits of source text: `setDefault` writes a tuned param's value back.
pub const edit = @import("edit.zig");

test {
    std.testing.refAllDecls(@This());
    _ = @import("Source.zig");
    _ = @import("Diagnostic.zig");
    _ = @import("syntax/Token.zig");
    _ = @import("syntax/Lexer.zig");
    _ = @import("syntax/Ast.zig");
    _ = @import("syntax/Parser.zig");
    _ = @import("sema/types.zig");
    _ = @import("sema/builtins.zig");
    _ = @import("sema/Checker.zig");
    _ = @import("sema/meta.zig");
    _ = @import("sema/tests.zig");
    _ = @import("ir/eval.zig");
    _ = @import("emit/emit.zig");
    _ = @import("emit/msl.zig");
    _ = @import("emit/tests.zig");
    _ = @import("ir/reach.zig");
    _ = @import("reflect/Reflection.zig");
    _ = @import("reflect/tests.zig");
    _ = @import("reflect/zig.zig");
    _ = @import("reflect/json.zig");
    _ = @import("edit.zig");
}
