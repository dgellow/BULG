//! Glint builds and tests on its own: nothing here reaches outside this directory.
//! Packages that depend on it use `addShaderTree` (below).
//!   zig build         the `glint` command, in zig-out/bin
//!   zig build test    unit tests on the host
//!   zig build check   formatting, unit tests, the golden texts, examples/hello (built
//!                     with addShaderTree), the freestanding self-test under node, and a
//!                     compile for iOS (no SDK needed)
//!   zig build update-golden   record the emitters' texts as tests/golden's expected ones
//!   zig build check-gpu       the golden ES 3.00 texts compiled in Chromium's WebGL 2
//!                     (needs node and Playwright)

const std = @import("std");

/// The dialects a shader tree can be generated in.
pub const Dialect = enum { es300, glsl330 };

pub const ShaderTreeOptions = struct {
    /// the directory of .glint files (each named by its path in it)
    root: std.Build.LazyPath,
    /// the dialects whose texts the module has
    dialects: []const Dialect = &.{ .es300, .glsl330 },
};

/// A shader tree as a Zig module: every program's texts and reflection (see
/// src/reflect/zig.zig), made by the `glint` command at build time. The module imports
/// only `std`, so nothing of the compiler is linked.
///
///     const glint_dep = b.dependency("glint", .{ .target = b.graph.host, .optimize = .ReleaseSafe });
///     const shaders = @import("glint").addShaderTree(b, glint_dep, .{ .root = b.path("shaders") });
///     exe.root_module.addImport("shaders", shaders);
///
/// The tree is read again at every build (it takes milliseconds), so that a new file is
/// never missed; the module is recompiled only when its text changes.
pub fn addShaderTree(b: *std.Build, glint_dep: *std.Build.Dependency, options: ShaderTreeOptions) *std.Build.Module {
    const run = b.addRunArtifact(glint_dep.artifact("glint"));
    run.addArgs(&.{ "gen", "--root" });
    run.addDirectoryArg(options.root);
    for (options.dialects) |d| run.addArgs(&.{ "--dialect", @tagName(d) });
    run.addArg("--out");
    const out = run.addOutputFileArg("shaders.zig");
    run.has_side_effects = true;
    return b.createModule(.{ .root_source_file = out });
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // the library, for packages that depend on this one
    const glint = b.addModule("glint", .{
        .root_source_file = b.path("src/glint.zig"),
        .target = target,
        .optimize = optimize,
    });

    // the command line tool
    const exe = b.addExecutable(.{
        .name = "glint",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "glint", .module = glint }},
        }),
    });
    b.installArtifact(exe);
    const run_exe = b.addRunArtifact(exe);
    run_exe.addPassthruArgs();
    b.step("run", "Run the glint command: zig build run -- parse FILE...").dependOn(&run_exe.step);

    // the tests get the README too, to check that its example parses
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/glint.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addAnonymousImport("README.md", .{ .root_source_file = b.path("README.md") });
    // a golden tree, for the fixed-buffer test
    for ([_][]const u8{ "frame", "fullscreen", "common", "world_main", "reef" }) |name| {
        test_mod.addAnonymousImport(b.fmt("golden_world_{s}", .{name}), .{ .root_source_file = b.path(b.fmt("tests/golden/world/{s}.glint", .{name})) });
    }
    const tests = b.addTest(.{ .root_module = test_mod });
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
    // the golden texts (tests/golden): emitted now, against what was recorded
    const golden = b.addExecutable(.{
        .name = "golden",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli/golden.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "glint", .module = glint }},
        }),
    });
    const run_golden = b.addRunArtifact(golden);
    run_golden.addDirectoryArg(b.path("tests/golden"));
    run_golden.has_side_effects = true;
    const update_golden = b.addRunArtifact(golden);
    update_golden.addDirectoryArg(b.path("tests/golden"));
    update_golden.addArg("--update");
    b.step("update-golden", "Record what the emitters write now as tests/golden's expected texts").dependOn(&update_golden.step);

    // the golden ES 3.00 texts, compiled and linked by a real driver (ANGLE, in Chromium)
    const webgl = b.addSystemCommand(&.{"node"});
    webgl.addFileArg(b.path("tests/webgl_es300.mjs"));
    webgl.addDirectoryArg(b.path("tests/golden"));
    webgl.has_side_effects = true;
    webgl.step.dependOn(&run_golden.step);
    b.step("check-gpu", "The golden ES 3.00 texts compiled and linked in Chromium's WebGL 2").dependOn(&webgl.step);

    // the build-time path end to end: a package that depends on this one and uses
    // addShaderTree, built and tested on its own
    const example = b.addSystemCommand(&.{ b.graph.zig_exe, "build", "test" });
    example.setCwd(b.path("examples/hello"));
    example.has_side_effects = true;

    const check = b.step("check", "Formatting, unit tests, golden texts, the example, the freestanding self-test, an iOS compile");
    check.dependOn(&fmt.step);
    check.dependOn(&run_tests.step);
    check.dependOn(&run_selftest.step);
    check.dependOn(&ios.step);
    check.dependOn(&exe.step);
    check.dependOn(&run_golden.step);
    check.dependOn(&example.step);
}
