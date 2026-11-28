//! Metadata: the `{ key, key(args) }` after a `param`, `spec` or `uniform`.
//!
//! BULG checks the keys it knows (the core: `range`, `step`, `label`, `group`, `unit`,
//! `color`, `tiers`) and passes every key to the host through reflection. A host may also
//! give a `Schema` of its own keys (Kykeon's `meta.zon`): then a key that is neither the
//! core's nor the schema's is an error, and the schema's keys have their arguments checked.
//! Without a schema, keys BULG does not know pass unchecked.

const std = @import("std");
const Session = @import("../Session.zig");
const Diagnostic = @import("../Diagnostic.zig");
const Ir = @import("../ir/Ir.zig");
const eval = @import("../ir/eval.zig");
const types = @import("types.zig");
const Type = types.Type;

pub const Error = error{OutOfMemory};

/// The keys a host adds to the core's, with their arguments. As ZON (see `parse`):
///
///     .{ .keys = .{
///         .{ .name = "mod", .doc = "...", .on = .{.param},
///            .args = .{ .{ .kind = .string }, .{ .kind = .number, .optional = true } } },
///         .{ .name = "curve", .args = .{ .{ .kind = .word, .words = .{ "lin", "exp" } } } },
///     } }
pub const Schema = struct {
    keys: []const Key = &.{},

    pub const Kind = enum { param, spec, uniform };
    pub const ArgKind = enum {
        /// a constant expression BULG computes now
        number,
        /// a string literal
        string,
        /// a bare word nothing declares (`curve(exp)`)
        word,
    };
    pub const Arg = struct {
        kind: ArgKind,
        /// for a word: the words it may be (empty: any)
        words: []const []const u8 = &.{},
        /// may be left out, with every argument after it
        optional: bool = false,
        /// stands for any number of arguments, at least one unless also optional (the last
        /// argument only)
        rest: bool = false,
    };
    pub const Key = struct {
        name: []const u8,
        args: []const Arg = &.{},
        /// the declarations it may be on
        on: []const Kind = &.{ .param, .spec, .uniform },
        /// may be given more than once on one declaration
        repeat: bool = false,
        /// what it means, for tools that list the keys
        doc: []const u8 = "",
    };

    pub fn find(s: *const Schema, name: []const u8) ?*const Key {
        for (s.keys) |*k| if (std.mem.eql(u8, k.name, name)) return k;
        return null;
    }

    /// Parses a schema from ZON. Results are in `arena`; `diagnostics` says what is wrong
    /// when the result is `error.ParseZon`. A schema that parses but is not sound (a core
    /// key redefined, an argument after a `rest`, ...) gives `error.BadSchema`, and
    /// `why` says which.
    pub fn parse(gpa: std.mem.Allocator, arena: std.mem.Allocator, text: [:0]const u8, diagnostics: *std.zon.parse.Diagnostics, why: *[]const u8) error{ OutOfMemory, ParseZon, BadSchema }!Schema {
        const s = try std.zon.parse.fromSlice(Schema, .{ .gpa = gpa, .arena = arena, .source = text, .diagnostics = diagnostics });
        if (s.problem()) |p| {
            why.* = p;
            return error.BadSchema;
        }
        return s;
    }

    /// What makes the schema unusable, if anything.
    pub fn problem(s: *const Schema) ?[]const u8 {
        for (s.keys, 0..) |k, i| {
            if (core.find(k.name) != null) return "a key of the schema has the name of a core key (range, step, label, group, unit, color, tiers)";
            if (k.name.len == 0 or !isWord(k.name)) return "a key's name is letters, digits and `_`, not starting with a digit";
            for (s.keys[0..i]) |o| if (std.mem.eql(u8, o.name, k.name)) return "a key is in the schema twice";
            var optional = false;
            for (k.args, 0..) |a, j| {
                if (a.rest and j + 1 != k.args.len) return "only a key's last argument may be `rest`";
                if (optional and !a.optional) return "an argument after an optional one must be optional";
                optional = optional or a.optional;
                if (a.words.len > 0 and a.kind != .word) return "`words` is for an argument of kind `word`";
            }
            if (k.on.len == 0) return "a key with an empty `on` can go nowhere";
        }
        return null;
    }
};

fn isWord(s: []const u8) bool {
    if (std.ascii.isDigit(s[0])) return false;
    for (s) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '_')) return false;
    return true;
}

const any_numeric: []const Schema.Kind = &.{ .param, .spec, .uniform };

/// The keys BULG knows. Their arguments are checked here like a host's; what they mean is
/// checked in `checkCore`.
pub const core: Schema = .{ .keys = &.{
    .{ .name = "range", .args = &.{ .{ .kind = .number }, .{ .kind = .number } }, .doc = "the least and the greatest value a tool offers; the default lies between them" },
    .{ .name = "step", .args = &.{.{ .kind = .number }}, .doc = "the smallest change a tool makes" },
    .{ .name = "label", .args = &.{.{ .kind = .string }}, .doc = "the name a tool shows" },
    .{ .name = "group", .args = &.{.{ .kind = .string }}, .doc = "the heading a tool shows it under" },
    .{ .name = "unit", .args = &.{.{ .kind = .string }}, .doc = "the unit a tool writes after the value" },
    .{ .name = "color", .doc = "a colour: a tool shows a swatch (a vec3 or vec4)" },
    .{ .name = "tiers", .args = &.{.{ .kind = .number, .rest = true }}, .on = &.{.spec}, .doc = "the values a host chooses between by quality, lowest first" },
} };

/// Checks the metadata of every module's declarations. Run after the checker, on finished
/// modules.
pub fn check(s: *Session, schema: ?*const Schema) Error!void {
    for (s.modules, 0..) |*m, mi| {
        for (m.globals) |*g| {
            if (g.meta.len == 0) continue;
            const kind: Schema.Kind = switch (g.kind) {
                .param => .param,
                .spec => .spec,
                .uniform => .uniform,
                else => continue,
            };
            var c: Ctx = .{ .s = s, .mi = @intCast(mi), .g = g, .kind = kind };
            for (g.meta, 0..) |me, i| {
                for (g.meta[0..i]) |o| if (std.mem.eql(u8, o.key, me.key)) {
                    const k = core.find(me.key) orelse if (schema) |sc| sc.find(me.key) else null;
                    if (k == null or !k.?.repeat) try c.report(me.tok, "`{s}` is given twice", .{me.key});
                    break;
                };
                if (core.find(me.key)) |k| {
                    if (try c.args(me, k)) try c.checkCore(me);
                } else if (schema) |sc| {
                    if (sc.find(me.key)) |k| {
                        _ = try c.args(me, k);
                    } else {
                        try c.unknown(me, sc);
                    }
                }
            }
        }
    }
}

const Ctx = struct {
    s: *Session,
    mi: u32,
    g: *const Ir.Global,
    kind: Schema.Kind,

    fn module(c: *const Ctx) *const Ir.Module {
        return &c.s.modules[c.mi];
    }

    fn reportCode(c: *Ctx, code: Diagnostic.Code, tok: u32, hint: ?[]const u8, comptime fmt: []const u8, a: anytype) Error!void {
        const ast = &c.s.asts.items[c.mi];
        const t = ast.tokens[tok];
        const arena = c.s.arena();
        try c.s.diags.add(arena, .{
            .severity = .@"error",
            .code = code,
            .span = .{ .src = c.module().src, .start = t.start, .end = t.end },
            .message = try std.fmt.allocPrint(arena, fmt, a),
            .hint = hint,
        });
    }

    fn report(c: *Ctx, tok: u32, comptime fmt: []const u8, a: anytype) Error!void {
        return c.reportCode(.bad_metadata, tok, null, fmt, a);
    }

    /// A key neither the core nor the schema has: an error, with the nearest known key as
    /// the hint when one is close.
    fn unknown(c: *Ctx, me: Ir.Meta, sc: *const Schema) Error!void {
        var best: ?[]const u8 = null;
        var best_d: usize = 3;
        for ([_]*const Schema{ &core, sc }) |set| for (set.keys) |k| {
            const d = distance(me.key, k.name);
            if (d < best_d) {
                best_d = d;
                best = k.name;
            }
        };
        const hint = if (best) |b| try std.fmt.allocPrint(c.s.arena(), "did you mean `{s}`?", .{b}) else null;
        try c.reportCode(.unknown_metadata, me.tok, hint, "no metadata key `{s}`: neither BULG nor the host's schema has it", .{me.key});
    }

    /// Checks a key's arguments against its signature. False if they are wrong.
    fn args(c: *Ctx, me: Ir.Meta, k: *const Schema.Key) Error!bool {
        if (std.mem.indexOfScalar(Schema.Kind, k.on, c.kind) == null) {
            try c.report(me.tok, "`{s}` is not for a {s}", .{ me.key, kindName(c.kind) });
            return false;
        }
        const ids = c.module().list(me.args);
        var least: usize = 0;
        for (k.args) |a| {
            if (a.optional) break;
            least += 1;
        }
        const rest = k.args.len > 0 and k.args[k.args.len - 1].rest;
        if (ids.len < least or (!rest and ids.len > k.args.len)) {
            if (k.args.len == 0) {
                try c.report(me.tok, "`{s}` takes no arguments", .{me.key});
            } else if (rest) {
                try c.report(me.tok, "`{s}` takes at least {d} argument{s}", .{ me.key, least, plural(least) });
            } else if (least == k.args.len) {
                try c.report(me.tok, "`{s}` takes {d} argument{s}", .{ me.key, least, plural(least) });
            } else {
                try c.report(me.tok, "`{s}` takes {d} to {d} arguments", .{ me.key, least, k.args.len });
            }
            return false;
        }
        var ok = true;
        for (ids, 0..) |id, i| {
            const a = k.args[@min(i, k.args.len - 1)];
            const e: Ir.ExprId = @fromBackingInt(@intCast(id));
            const ex = c.module().expr(e);
            if (ex.type == .invalid) {
                ok = false;
                continue;
            }
            const got: Schema.ArgKind = if (ex.data == .string) (if (c.text(ex.tok)[0] == '"') .string else .word) else .number;
            if (got != a.kind) {
                try c.report(ex.tok, "argument {d} of `{s}` is a {s}, not a {s}", .{ i + 1, me.key, argName(a.kind), argName(got) });
                ok = false;
                continue;
            }
            switch (a.kind) {
                .number => if (c.number(e) == null) {
                    // the checker has said so if it is no constant at all
                    if (!c.reported(ex.tok)) try c.report(ex.tok, "argument {d} of `{s}` must be a number known now", .{ i + 1, me.key });
                    ok = false;
                },
                .word => if (a.words.len > 0) {
                    const w = c.text(ex.tok);
                    for (a.words) |allowed| {
                        if (std.mem.eql(u8, allowed, w)) break;
                    } else {
                        try c.report(ex.tok, "`{s}` is not one of the words `{s}` takes ({s})", .{ w, me.key, try c.wordList(a.words) });
                        ok = false;
                    }
                },
                .string => {},
            }
        }
        return ok;
    }

    /// What the core keys mean, beyond their arguments' kinds.
    fn checkCore(c: *Ctx, me: Ir.Meta) Error!void {
        const t = c.g.type;
        const numeric = t.vectorLen() != null and t.isNumeric();
        if (std.mem.eql(u8, me.key, "range")) {
            if (!numeric) return c.report(me.tok, "`range` is for a number or a vector of numbers, not a `{s}`", .{c.typeName(t)});
            const ids = c.module().list(me.args);
            const lo = c.number(@fromBackingInt(@intCast(ids[0]))).?;
            const hi = c.number(@fromBackingInt(@intCast(ids[1]))).?;
            if (!(lo < hi)) return c.report(me.tok, "`range({d}, {d})`: the least value must be less than the greatest", .{ lo, hi });
            var buf: [16]Ir.Const = undefined;
            if (c.g.init != .none) if (eval.components(c.s.modules, c.mi, c.g.init, .{ .values = &.{} }, &buf)) |vs| {
                for (vs) |v| {
                    const x = asF64(v) orelse continue;
                    if (x < lo or x > hi) return c.report(c.module().expr(c.g.init).tok, "the default {d} of `{s}` is outside its `range({d}, {d})`", .{ x, c.g.name, lo, hi });
                }
            };
            // a spec's tiers are values it takes: they lie in its range too
            for (c.g.meta) |o| if (std.mem.eql(u8, o.key, "tiers")) for (c.module().list(o.args)) |id| {
                const e: Ir.ExprId = @fromBackingInt(@intCast(id));
                const x = c.number(e) orelse continue;
                if (x < lo or x > hi) return c.report(c.module().expr(e).tok, "the tier {d} of `{s}` is outside its `range({d}, {d})`", .{ x, c.g.name, lo, hi });
            };
        } else if (std.mem.eql(u8, me.key, "step")) {
            if (!numeric) return c.report(me.tok, "`step` is for a number or a vector of numbers, not a `{s}`", .{c.typeName(t)});
            const ids = c.module().list(me.args);
            const st = c.number(@fromBackingInt(@intCast(ids[0]))).?;
            if (!(st > 0)) return c.report(me.tok, "`step({d})`: a step is greater than 0", .{st});
        } else if (std.mem.eql(u8, me.key, "color")) {
            const ok = (t == .vec3 or t == .vec4 or t == .hvec3 or t == .hvec4);
            if (!ok) return c.report(me.tok, "`color` is for a `vec3` or a `vec4`, not a `{s}`", .{c.typeName(t)});
        } else if (std.mem.eql(u8, me.key, "tiers")) {
            if (!numeric or t == .bool) return c.report(me.tok, "`tiers` is for an `int`, `uint` or `float` spec constant", .{});
            const ids = c.module().list(me.args);
            var prev: ?f64 = null;
            for (ids) |id| {
                const e: Ir.ExprId = @fromBackingInt(@intCast(id));
                const x = c.number(e).?;
                if (prev) |p| if (!(x > p)) return c.report(c.module().expr(e).tok, "tiers go from the lowest to the highest: {d} after {d}", .{ x, p });
                prev = x;
            }
        }
    }

    /// Whether an error is already reported at this token.
    fn reported(c: *const Ctx, tok: u32) bool {
        const start = c.s.asts.items[c.mi].tokens[tok].start;
        for (c.s.diags.items.items) |d| if (d.span.src == c.module().src and d.span.start == start) return true;
        return false;
    }

    fn text(c: *const Ctx, tok: u32) []const u8 {
        return c.s.asts.items[c.mi].tokenText(tok);
    }

    fn number(c: *const Ctx, e: Ir.ExprId) ?f64 {
        const v = eval.constant(c.s.modules, c.mi, e, .{ .values = &.{} }) orelse return null;
        return asF64(v);
    }

    fn typeName(c: *Ctx, t: Type) []const u8 {
        var buf: [128]u8 = undefined;
        return c.s.arena().dupe(u8, c.s.pool.name(t, &buf)) catch "(type)";
    }

    fn wordList(c: *Ctx, words: []const []const u8) Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (words, 0..) |w, i| {
            if (i > 0) try out.appendSlice(c.s.arena(), ", ");
            try out.appendSlice(c.s.arena(), w);
        }
        return out.items;
    }
};

fn asF64(v: Ir.Const) ?f64 {
    return switch (v) {
        .float => |f| f,
        .int => |i| @floatFromInt(i),
        .uint => |u| @floatFromInt(u),
        .bool => null,
    };
}

fn kindName(k: Schema.Kind) []const u8 {
    return switch (k) {
        .param => "`param`",
        .spec => "`spec` constant",
        .uniform => "`uniform`",
    };
}

fn argName(k: Schema.ArgKind) []const u8 {
    return switch (k) {
        .number => "number",
        .string => "string",
        .word => "bare word",
    };
}

fn plural(n: usize) []const u8 {
    return if (n == 1) "" else "s";
}

/// The edit distance between two short names (insertions, deletions, substitutions); 99
/// for names too long to bother with.
fn distance(a: []const u8, b: []const u8) usize {
    if (a.len > 31 or b.len > 31) return 99;
    var row: [32]usize = undefined;
    for (0..b.len + 1) |j| row[j] = j;
    for (a, 0..) |ca, i| {
        var prev = row[0];
        row[0] = i + 1;
        for (b, 0..) |cb, j| {
            const cur = row[j + 1];
            row[j + 1] = @min(@min(row[j + 1] + 1, row[j] + 1), prev + @intFromBool(ca != cb));
            prev = cur;
        }
    }
    return row[b.len];
}

test distance {
    try std.testing.expectEqual(@as(usize, 2), distance("rnage", "range"));
    try std.testing.expectEqual(@as(usize, 0), distance("mod", "mod"));
    try std.testing.expectEqual(@as(usize, 1), distance("rang", "range"));
    try std.testing.expectEqual(@as(usize, 3), distance("", "abc"));
}
