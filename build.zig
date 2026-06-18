const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Prioritize performance, safety, or binary size") orelse .ReleaseFast;

    const zlua_dep = b.dependency("zlua", .{
        .target = target,
        .optimize = optimize,
        .lang = .lua55,
    });

    const version_module = b.createModule(.{
        .root_source_file = b.path("src/version.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "loam",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zlua", .module = zlua_dep.module("zlua") },
                .{ .name = "version", .module = version_module },
            },
        }),
    });

    b.installArtifact(exe);

    const mcp_exe = b.addExecutable(.{
        .name = "loam-mcp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/mcp.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "version", .module = version_module },
            },
        }),
    });
    b.installArtifact(mcp_exe);

    const run_step = b.step("run", "Run the loam ascii particle painter");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_tests.step);
}
