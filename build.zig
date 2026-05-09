const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Import franky as a dependency.
    const franky_dep = b.dependency("franky", .{
        .target = target,
        .optimize = optimize,
    });
    const franky_module = franky_dep.module("franky");

    // ── The extension module ────────────────────────────────────────
    // This is the go-dev extension that other programs can import.
    // It provides:
    //   - goTool()                              — AgentTool factory
    //   - buildGoDevTools()                       — preset builder for subagent
    //   - extension()                             — ext.Extension factory
    //   - registerPreset(reg)                     — one-shot registration helper
    const go_dev_mod = b.addModule("franky-golang", .{
        .root_source_file = b.path("src/go_dev.zig"),
        .target = target,
        .optimize = optimize,
    });
    go_dev_mod.addImport("franky", franky_module);

    // ── Tests ───────────────────────────────────────────────────────
    const test_exe = b.addTest(.{
        .name = "franky-golang-tests",
        .root_module = go_dev_mod,
    });
    const run_tests = b.addRunArtifact(test_exe);
    b.step("test", "Run the go-dev extension tests").dependOn(&run_tests.step);

    // ── Custom binary (optional) ────────────────────────────────────
    // This builds a standalone binary that embeds the extension.
    // Useful for testing the extension in isolation or as a
    // demo/integration test.
    //
    // Usage:  zig build run -- --extensions go-dev "Your prompt here"
    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_module.addImport("franky", franky_module);
    exe_module.addImport("franky-golang", go_dev_mod);

    const exe = b.addExecutable(.{
        .name = "franky-go",
        .root_module = exe_module,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run franky with the go-dev extension pre-loaded").dependOn(&run_cmd.step);
}
