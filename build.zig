const std = @import("std");
const debug = std.debug;

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    {
        const exe = b.addExecutable(.{
            .name = "zig-present",

            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        });

        b.installArtifact(exe);

        const run_cmd = b.addRunArtifact(exe);

        run_cmd.step.dependOn(b.getInstallStep());

        if (b.args) |args| {
            run_cmd.addArgs(args);
        }

        const run_step = b.step("run", "Run the app");
        run_step.dependOn(&run_cmd.step);
    }

    {
        const dist_step = b.step("dist", "cross-compile the app for distribution");

        const cross_targets = .{
            "aarch64-linux",
            "aarch64-macos",
            "x86_64-linux",
        };
        inline for (cross_targets) |cross_target| {
            const x = b.addExecutable(.{
                .name = "zig-present-" ++ cross_target,
                .root_source_file = b.path("src/main.zig"),
                .target = b.resolveTargetQuery(
                    try std.zig.CrossTarget.parse(.{
                        .arch_os_abi = cross_target,
                    }),
                ),
                .optimize = optimize,
            });

            dist_step.dependOn(&x.step);
        }
    }

    {
        const unit_tests = b.addTest(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        });

        const run_unit_tests = b.addRunArtifact(unit_tests);

        const test_step = b.step("test", "Run unit tests");
        test_step.dependOn(&run_unit_tests.step);
    }
}
