//! The checked program of one module: typed, structured (statements and expressions as
//! written, no SSA and no control-flow graph), with every name resolved. Names, literal
//! spellings and compound assignments are kept, so that an emitter can print text that
//! reads like the source and, on GL, compiles to the same code.

const std = @import("std");
const types = @import("../sema/types.zig");
const builtins = @import("../sema/builtins.zig");
const Source = @import("../Source.zig");
const Type = types.Type;

pub const ExprId = enum(u32) { none = std.math.maxInt(u32), _ };
pub const StmtId = enum(u32) { none = std.math.maxInt(u32), _ };

/// A range in `extra`.
pub const List = struct { start: u32 = 0, len: u32 = 0 };

/// A declaration of some module: modules refer to each other's functions and globals.
pub const Ref = struct { module: u32, index: u32 };

/// A compile-time scalar.
pub const Const = union(enum) {
    bool: bool,
    int: i32,
    uint: u32,
    float: f32,

    pub fn eql(a: Const, b: Const) bool {
        return switch (a) {
            .bool => |x| b == .bool and b.bool == x,
            .int => |x| b == .int and b.int == x,
            .uint => |x| b == .uint and b.uint == x,
            .float => |x| b == .float and @as(u32, @bitCast(b.float)) == @as(u32, @bitCast(x)),
        };
    }
};

pub const UnaryOp = enum(u8) { neg, plus, not, bit_not, pre_inc, pre_dec, post_inc, post_dec };

pub const BinaryOp = enum(u8) {
    add,
    sub,
    mul,
    div,
    rem,
    shl,
    shr,
    bit_and,
    bit_or,
    bit_xor,
    log_and,
    log_or,
    log_xor,
    eq,
    ne,
    lt,
    gt,
    le,
    ge,
};

/// `=` or a compound assignment (kept as written).
pub const AssignOp = enum(u8) { set, add, sub, mul, div, rem, shl, shr, bit_and, bit_or, bit_xor };

pub const Expr = struct {
    type: Type,
    /// the token the expression is about, in its module's source
    tok: u32,
    data: Data,

    pub const Data = union(enum) {
        /// value and spelling (the token) of a literal
        literal: Const,
        /// a string (the token, quotes included): only in metadata
        string,
        /// a local variable of the function (index into Function.locals)
        local: u32,
        /// a parameter of the function
        param: u32,
        /// a global of some module (a uniform block's members are globals too)
        global: Ref,
        /// `gl_FragCoord` and the like: an index into builtins.variables
        builtin_var: u8,
        /// an alias, used where it is named; the emitter prints its expression there
        alias: Ref,
        call: struct { callee: Ref, args: List },
        /// a built-in function: an index into builtins.functions
        builtin_call: struct { func: u16, args: List },
        /// `vec3(...)`, `mat3(...)`, `float[9](...)`, `Hit(...)`: the type is the result
        construct: List,
        unary: struct { op: UnaryOp, operand: ExprId },
        binary: struct { op: BinaryOp, lhs: ExprId, rhs: ExprId },
        assign: struct { op: AssignOp, lhs: ExprId, rhs: ExprId },
        ternary: struct { cond: ExprId, then: ExprId, @"else": ExprId },
        index: struct { base: ExprId, index: ExprId },
        /// up to four components, 0-3 (x/r/s ... w/a/q); the letters as written are the
        /// token's text
        swizzle: struct { base: ExprId, comps: [4]u2, len: u3 },
        field: struct { base: ExprId, index: u32 },
        /// `a.length()` of an array: a constant
        array_length: struct { base: ExprId, len: u32 },
    };
};

pub const Stmt = struct {
    tok: u32,
    data: Data,

    pub const Data = union(enum) {
        block: List,
        /// a local variable comes into scope (with its initialiser, if any)
        local: struct { local: u32, init: ExprId },
        expr: ExprId,
        @"if": struct { cond: ExprId, then: StmtId, @"else": StmtId },
        /// `init` is a `local` statement, an `expr` one, or none
        @"for": struct { init: StmtId, cond: ExprId, step: ExprId, body: StmtId },
        @"return": ExprId,
        @"break",
        @"continue",
        discard,
    };
};

pub const Local = struct {
    name: []const u8,
    type: Type,
    is_const: bool,
    tok: u32,
};

pub const ParamDir = enum(u8) { in, out, inout };

pub const Param = struct {
    name: []const u8,
    type: Type,
    dir: ParamDir,
    is_const: bool,
};

pub const Function = struct {
    name: []const u8,
    ret: Type,
    params: []const Param,
    /// a block, or none for a prototype or an `extern`
    body: StmtId,
    is_extern: bool,
    locals: []const Local,
    /// the module's node of the declaration (for messages)
    tok: u32,
    /// what the function uses itself (not through its callees)
    uses: Uses,
    /// user functions it calls
    calls: []const Ref,
};

/// What code uses, for stage checks and capabilities.
pub const Uses = packed struct(u16) {
    discard: bool = false,
    derivatives: bool = false,
    textures: bool = false,
    frag_coord: bool = false,
    front_facing: bool = false,
    point_coord: bool = false,
    position: bool = false,
    point_size: bool = false,
    vertex_id: bool = false,
    instance_id: bool = false,
    _: u6 = 0,

    pub fn merge(a: Uses, b: Uses) Uses {
        return @bitCast(@as(u16, @bitCast(a)) | @as(u16, @bitCast(b)));
    }
};

pub const GlobalKind = enum(u8) {
    uniform,
    /// a vertex input or a varying into the fragment stage
    in,
    out,
    @"const",
    /// a plain global: mutable, private to each invocation
    mutable,
    /// a host-tweakable value: a uniform with a default and metadata
    param,
    /// a value fixed per variant
    spec,
};

pub const Meta = struct {
    key: []const u8,
    /// the arguments' expressions (constants, strings as literals)
    args: List,
};

pub const Global = struct {
    name: []const u8,
    type: Type,
    kind: GlobalKind,
    flat: bool,
    location: ?u32,
    init: ExprId,
    meta: []const Meta,
    /// the uniform block it is a member of, if any (index into Module.blocks)
    block: ?u32,
    tok: u32,
};

pub const Block = struct {
    name: []const u8,
    /// the globals that are its members, in order
    members: []const u32,
    /// std140 offset of each member
    offsets: []const u32,
    size: u32,
    tok: u32,
};

pub const Alias = struct {
    name: []const u8,
    value: ExprId,
    tok: u32,
};

pub const Module = struct {
    /// `art/art_core` for art/art_core.glint
    name: []const u8,
    src: Source.Id,
    globals: []const Global,
    functions: []const Function,
    aliases: []const Alias,
    blocks: []const Block,
    structs: []const Type,
    /// the name token of each struct's declaration
    struct_toks: []const u32,
    exprs: []const Expr,
    stmts: []const Stmt,
    extra: []const u32,

    pub fn expr(m: *const Module, e: ExprId) Expr {
        return m.exprs[@backingInt(e)];
    }
    pub fn stmt(m: *const Module, s: StmtId) Stmt {
        return m.stmts[@backingInt(s)];
    }
    pub fn list(m: *const Module, l: List) []const u32 {
        return m.extra[l.start..][0..l.len];
    }
};

pub const Stage = enum(u8) { vertex, fragment };

/// A program: two stages, each a set of modules linked into one, with spec values.
pub const Program = struct {
    name: []const u8,
    /// the module that declares it, and the token of its name
    module: u32,
    tok: u32,
    is_template: bool,
    vertex: ?StageInfo,
    fragment: ?StageInfo,
    specs: []const SpecValue,
};

pub const StageInfo = struct {
    /// the module with `main`
    entry: u32,
    main: Ref,
    /// every module linked into the stage (the entry, the links, the declaring module
    /// and everything they import), in a fixed order
    modules: []const u32,
    /// each `extern` used, with the function that fills it
    externs: []const Extern,
    /// the user functions reachable from main, callees first
    functions: []const Ref,
    uses: Uses,
};

pub const Extern = struct { hole: Ref, fill: Ref };

pub const SpecValue = struct {
    /// the spec global
    spec: Ref,
    value: Const,
};
