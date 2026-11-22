//! What a host does with the generated module: pick a program, hand its texts to the
//! driver, bind its samplers and fill its blocks.

const std = @import("std");
const shaders = @import("shaders");

test "the programs, their texts and their reflection" {
    const rings = shaders.programs.get(.rings);
    try std.testing.expect(std.mem.startsWith(u8, rings.fragment.get(.es300), "#version 300 es"));
    try std.testing.expectEqual(@as(usize, 1), rings.samplers.len);
    try std.testing.expectEqual(0, shaders.rings.samplers.uNoise);
    try std.testing.expectEqual(@as(usize, 2), rings.params.len);
    try std.testing.expectEqualStrings("speed", rings.params[0].name);
    try std.testing.expectEqual(@as(f64, 4), rings.params[0].meta[0].args[1].number);
    try std.testing.expectEqual(@as(f64, 16), shaders.programs.get(.rings_fine).specs[0].value);
    // the specialised text has the variant's constant
    try std.testing.expect(std.mem.indexOf(u8, shaders.rings_fine.fragment.get(.es300), "const int RINGS = 16;") != null);
}

test "a block is an extern struct with its defaults, laid out by std140" {
    const frame: shaders.blocks.Frame = .{};
    try std.testing.expectEqual(@as(usize, 80), @sizeOf(shaders.blocks.Frame));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(shaders.blocks.Frame, "uTime"));
    try std.testing.expectEqual(@as(usize, 32), @offsetOf(shaders.blocks.Frame, "uView"));
    try std.testing.expectEqual(@as(f32, 640), frame.uRes4[0]);
    try std.testing.expectEqual(@as(f32, 1), frame.uView[2][2]);
    try std.testing.expectEqual(@as(f32, 0), frame.uView[2][3]);
    // the bytes a host uploads
    const bytes = std.mem.asBytes(&frame);
    try std.testing.expectEqual(@as(usize, 80), bytes.len);
}
