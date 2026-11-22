//! Reflection's tests.

const std = @import("std");
const Session = @import("../Session.zig");
const R = @import("Reflection.zig");
const testing = std.testing;

const files = [_]struct { []const u8, []const u8 }{
    .{ "frame.glint", "uniform block Frame { vec4 uRes4 = vec4(1.); vec3 uSun; float uTime; mat3 uRot = mat3(1.); };" },
    .{
        "v.glint",
        \\layout(location = 0) in vec3 aPos;
        \\layout(location = 1) in vec2 aUv;
        \\in vec4 aUnused;
        \\flat out int vKind;
        \\out vec2 vUv;
        \\out float vOnlyVertex;
        \\uniform sampler2D uHeight;
        \\void main() { vKind = gl_InstanceID; vUv = aUv; vOnlyVertex = 1.; gl_Position = vec4(aPos + texture(uHeight, aUv).x, 1.); }
    },
    .{
        "f.glint",
        \\import "frame";
        \\spec bool FADE = false { label("Fade") };
        \\spec int STEPS = 48 { tiers(24, 48, 96) };
        \\param vec3 tint = vec3(1., .5, .25) { range(0., 2.), curve(exp), label("Tint") };
        \\param float unusedParam = 1.;
        \\uniform sampler2D uPrev, uNoise, uFadeTex;
        \\uniform vec4 uSite[4];
        \\flat in int vKind;
        \\in vec2 vUv;
        \\layout(location = 0) out vec4 color;
        \\void main() {
        \\    vec3 c = texture(uNoise, vUv).rgb * tint + texture(uPrev, vUv).rgb + uSun * uTime;
        \\    if (FADE) c *= texture(uFadeTex, vUv).r;
        \\    for (int i = 0; i < STEPS; i++) c += uSite[vKind & 3].xyz;
        \\    color = vec4(c, 1.);
        \\}
        \\program p { vertex "v"; fragment "f"; spec STEPS = 96; }
        \\program faded { vertex "v"; fragment "f"; spec FADE = true; }
    },
};

fn session() !Session {
    var s: Session = .init(testing.allocator, .{});
    errdefer s.deinit();
    for (files) |f| _ = try s.addSource(f[0], f[1]);
    try s.analyze();
    try testing.expectEqual(@as(u32, 0), s.errorCount());
    return s;
}

test "blocks, samplers, uniforms, params, specs and the stages' interfaces" {
    var s = try session();
    defer s.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const r = try R.reflect(&s, s.findProgram("p").?, arena.allocator());

    try testing.expectEqual(@as(usize, 1), r.blocks.len);
    const b = r.blocks[0];
    try testing.expectEqualStrings("Frame", b.name);
    try testing.expectEqualStrings("frame", b.module);
    try testing.expectEqual(@as(u32, 80), b.size);
    const offsets = [_]u32{ 0, 16, 28, 32 };
    for (b.members, offsets) |m, o| try testing.expectEqual(o, m.offset);
    try testing.expectEqual(@as(f32, 1), b.members[0].default.?[3].float);
    try testing.expectEqual(@as(?[]const @import("../ir/Ir.zig").Const, null), b.members[1].default);
    try testing.expectEqual(@as(usize, 9), b.members[3].default.?.len);
    try testing.expect(b.stages.fragment and !b.stages.vertex);

    // samplers: slots in the order of the texts, vertex first; the one only a folded
    // branch reads is not there
    try testing.expectEqual(@as(usize, 3), r.samplers.len);
    try testing.expectEqualStrings("uHeight", r.samplers[0].name);
    try testing.expectEqualStrings("uPrev", r.samplers[1].name);
    try testing.expectEqualStrings("uNoise", r.samplers[2].name);
    for (r.samplers, 0..) |sm, i| try testing.expectEqual(@as(u32, @intCast(i)), sm.slot);

    try testing.expectEqual(@as(usize, 1), r.uniforms.len);
    try testing.expectEqualStrings("uSite", r.uniforms[0].name);

    try testing.expectEqual(@as(usize, 1), r.params.len);
    const tint = r.params[0];
    try testing.expectEqualStrings("tint", tint.name);
    try testing.expectEqual(@as(f32, 0.25), tint.default[2].float);
    try testing.expectEqual(@as(usize, 3), tint.meta.len);
    try testing.expectEqualStrings("range", tint.meta[0].key);
    try testing.expectEqual(@as(f32, 2), tint.meta[0].args[1].value.float);
    try testing.expectEqualStrings("exp", tint.meta[1].args[0].word);
    try testing.expectEqualStrings("Tint", tint.meta[2].args[0].string);

    try testing.expectEqual(@as(usize, 2), r.specs.len);
    try testing.expectEqualStrings("FADE", r.specs[0].name);
    try testing.expect(!r.specs[0].value.bool);
    try testing.expectEqual(@as(i32, 96), r.specs[1].value.int);
    try testing.expectEqual(@as(i32, 48), r.specs[1].default.int);
    try testing.expectEqual(@as(usize, 3), r.specs[1].meta[0].args.len);

    // aUnused is not read: not an input of the program's text
    try testing.expectEqual(@as(usize, 2), r.inputs.len);
    try testing.expectEqual(@as(?u32, 1), r.inputs[1].location);
    try testing.expectEqual(@as(usize, 2), r.varyings.len);
    try testing.expect(r.varyings[0].flat);
    try testing.expectEqual(@as(usize, 1), r.outputs.len);
    try testing.expect(r.vertex_uses.instance_id and r.fragment_uses.textures);
    try testing.expectEqual(@as(usize, 3), r.files.len);

    // the other variant reads the third sampler of the fragment stage
    const faded = try R.reflect(&s, s.findProgram("faded").?, arena.allocator());
    try testing.expectEqual(@as(usize, 4), faded.samplers.len);
    try testing.expectEqualStrings("uFadeTex", faded.samplers[3].name);
}

test "the generated Zig compiles and says what reflection says" {
    var s = try session();
    defer s.deinit();
    const zig = @import("zig.zig");
    const text = try zig.generate(&s, .{}, testing.allocator);
    defer testing.allocator.free(text);
    // it parses as Zig
    const src = try testing.allocator.dupeSentinel(u8, text, 0);
    defer testing.allocator.free(src);
    var tree = try std.zig.Ast.parse(testing.allocator, src, .{});
    defer tree.deinit(testing.allocator);
    if (tree.errors.len > 0) {
        std.debug.print("{s}\n", .{text});
        return error.TestUnexpectedResult;
    }
    for ([_][]const u8{
        "pub const Frame = extern struct {",
        "uRes4: [4]f32 = .{ 1, 1, 1, 1 },",
        "uRot: [3][4]f32 = .{ .{ 1, 0, 0, 0 }, .{ 0, 1, 0, 0 }, .{ 0, 0, 1, 0 } },",
        "std.debug.assert(@offsetOf(@This(), \"uRot\") == 32);",
        "pub const uHeight = 0;",
        ".{ .name = \"tint\", .type = .vec3, .default = &.{ 1, 0.5, 0.25 }",
        ".{ .key = \"curve\", .args = &.{ .{ .word = \"exp\" } } }",
        ".{ .name = \"STEPS\", .type = .int, .value = 96, .default = 48",
        "pub const Program = enum {",
    }) |want| {
        if (std.mem.indexOf(u8, text, want) == null) {
            std.debug.print("missing: {s}\n", .{want});
            return error.TestUnexpectedResult;
        }
    }
}

test "the JSON is valid, versioned, and has the reflection" {
    var s = try session();
    defer s.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try @import("json.zig").write(&s, &out.writer, arena.allocator());
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out.written(), .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try testing.expectEqualStrings("glint.reflection/1", root.get("format").?.string);
    const progs = root.get("programs").?.array.items;
    try testing.expectEqual(@as(usize, 2), progs.len);
    const p = progs[0].object;
    try testing.expectEqualStrings("p", p.get("name").?.string);
    const member = p.get("blocks").?.array.items[0].object.get("members").?.array.items[3].object;
    try testing.expectEqualStrings("mat3", member.get("type").?.string);
    try testing.expectEqual(@as(i64, 32), member.get("offset").?.integer);
    const tint = p.get("params").?.array.items[0].object;
    try testing.expectEqualStrings("exp", tint.get("meta").?.array.items[1].object.get("args").?.array.items[0].object.get("word").?.string);
    try testing.expectEqual(@as(i64, 96), p.get("specs").?.array.items[1].object.get("value").?.integer);
    try testing.expectEqualStrings("vec4[4]", p.get("uniforms").?.array.items[0].object.get("type").?.string);
}

test "a tree is checked, emitted and reflected in a fixed buffer" {
    // the budget a host can size its buffer from: this tree (5 modules, two programs,
    // both dialects, reflection) needs a third of it
    const budget = 1 << 20;
    const buf = try testing.allocator.alloc(u8, budget);
    defer testing.allocator.free(buf);
    var fba: std.heap.FixedBufferAllocator = .init(buf);
    const gpa = fba.allocator();
    const sources = [_]struct { []const u8, []const u8 }{
        .{ "frame.glint", @embedFile("golden_world_frame") },
        .{ "fullscreen.glint", @embedFile("golden_world_fullscreen") },
        .{ "common.glint", @embedFile("golden_world_common") },
        .{ "world_main.glint", @embedFile("golden_world_world_main") },
        .{ "reef.glint", @embedFile("golden_world_reef") },
    };
    var s: Session = .init(gpa, .{});
    defer s.deinit();
    for (sources) |f| _ = try s.addSource(f[0], f[1]);
    try s.analyze();
    try testing.expectEqual(@as(u32, 0), s.errorCount());
    const glsl = @import("../emit/glsl.zig");
    for (s.programs) |*p| {
        if (p.is_template) continue;
        for ([_]glsl.Dialect{ .es300, .glsl330 }) |d| for ([_]@import("../ir/Ir.zig").Stage{ .vertex, .fragment }) |st| {
            var e = try glsl.emit(&s, p, st, d, s.arena());
            _ = &e;
        };
        _ = try R.reflect(&s, p, s.arena());
    }
    // 346 KiB when this was written: a jump past half the budget is a regression to look at
    try testing.expect(fba.end_index < budget / 2);
}
