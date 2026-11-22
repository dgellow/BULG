//! Glint: a small shading language and its compiler, in Zig, for programs that want one
//! shader source for Metal, WebGPU and OpenGL ES / WebGL 2. See README.md.
//!
//! v0.1 has the front of the front end: sources, spans, diagnostics, the lexer, the parser
//! and the syntax tree's printer. The checker, IR, emitters, reflection and interpreter
//! follow (CHANGELOG.md).
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

test {
    std.testing.refAllDecls(@This());
    _ = @import("Source.zig");
    _ = @import("Diagnostic.zig");
    _ = @import("syntax/Token.zig");
    _ = @import("syntax/Lexer.zig");
    _ = @import("syntax/Ast.zig");
    _ = @import("syntax/Parser.zig");
}
