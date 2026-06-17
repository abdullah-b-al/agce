const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    switch (target.result.os.tag) {
        .windows => {
            const win32 = b.dependency("win32", .{});
            const exe = b.addExecutable(.{
                .name = "agce",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("src/main_windows.zig"),
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{
                        .{ .name = "win32", .module = win32.module("win32") },
                    },
                }),
            });

            b.installArtifact(exe);
            const check = b.step("check", "Check the compilation");
            check.dependOn(&exe.step);
        },
        .linux => {
            const Scanner = @import("wayland").Scanner;
            const scanner = Scanner.create(b, .{});

            const wayland = b.createModule(.{ .root_source_file = scanner.result });

            scanner.addSystemProtocol("stable/xdg-shell/xdg-shell.xml");

            scanner.generate("wl_seat", 1);
            scanner.generate("wl_compositor", 1);
            scanner.generate("wl_shm", 1);
            scanner.generate("xdg_wm_base", 1);

            const exe = b.addExecutable(.{
                .name = "agce",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("src/main_wayland.zig"),
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{
                        .{ .name = "wayland", .module = wayland },
                    },
                }),
            });

            exe.root_module.linkSystemLibrary("wayland-client", .{});
            b.installArtifact(exe);
            const check = b.step("check", "Check the compilation");
            check.dependOn(&exe.step);
        },
        else => return error.UnsupportedOS,
    }
}
