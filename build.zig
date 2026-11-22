//! Glint builds and tests on its own: nothing here reaches outside this directory.
//!   zig build test    unit tests on the host
//!   zig build check   formatting, unit tests, the freestanding self-test under node, and
//!                     a compile for iOS (no SDK needed)

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // the library, for packages that depend on this one
    const glint = b.addModule("glint", .{
        .root_source_file = b.path("src/glint.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tests = b.addTest(.{ .root_module = glint });
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run the unit tests").dependOn(&run_tests.step);

    // the core on a target with no libc, files or threads, run by node
    const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const selftest = b.addExecutable(.{
        .name = "glint_selftest",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/selftest.zig"),
            .target = wasm_target,
            .optimize = .small,
            .imports = &.{.{ .name = "glint", .module = b.createModule(.{
                .root_source_file = b.path("src/glint.zig"),
                .target = wasm_target,
                .optimize = .small,
            }) }},
        }),
    });
    selftest.entry = .disabled;
    selftest.rdynamic = true;
    const run_selftest = b.addSystemCommand(&.{"node"});
    run_selftest.addFileArg(b.path("tests/wasm_selftest.mjs"));
    run_selftest.addArtifactArg(selftest);

    // the core compiles for the Apple slices too (no SDK needed: nothing is linked)
    const ios = b.addObject(.{
        .name = "glint-ios",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/glint.zig"),
            .target = b.resolveTargetQuery(.{ .cpu_arch = .aarch64, .os_tag = .ios }),
            .optimize = .fast,
        }),
    });

    const fmt = b.addFmt(.{ .paths = &.{ b.path("build.zig"), b.path("src") }, .check = true });
    const check = b.step("check", "Formatting, unit tests, the freestanding self-test, an iOS compile");
    check.dependOn(&fmt.step);
    check.dependOn(&run_tests.step);
    check.dependOn(&run_selftest.step);
    check.dependOn(&ios.step);
}
