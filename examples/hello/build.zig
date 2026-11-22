//! How a program uses BULG at build time: its shaders become a Zig module.
//!   zig build test

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // the compiler runs on the machine that builds
    const bulg_dep = b.dependency("bulg", .{ .target = b.graph.host, .optimize = .ReleaseSafe });
    const shaders = @import("bulg").addShaderTree(b, bulg_dep, .{
        .root = b.path("shaders"),
        .dialects = &.{.es300},
    });
    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "shaders", .module = shaders }},
    });
    const tests = b.addTest(.{ .root_module = mod });
    b.step("test", "Use the generated module").dependOn(&b.addRunArtifact(tests).step);
}
