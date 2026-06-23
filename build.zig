const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const check = b.step("check", "Check the compilation");
    const c_linux = b.addTranslateC(.{
        .root_source_file = b.path("src/c_linux.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    { // client cli
        const exe = b.addExecutable(.{
            .name = "agce-client",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main_client.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "c_linux", .module = c_linux.createModule() },
                },
            }),
        });
        b.installArtifact(exe);
        check.dependOn(&exe.step);
    }

    switch (target.result.os.tag) {
        .windows => {
            const win32 = b.dependency("win32", .{});
            const exe = b.addExecutable(.{
                .name = "agce",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("src/main.zig"),
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{
                        .{ .name = "win32", .module = win32.module("win32") },
                    },
                }),
            });

            b.installArtifact(exe);
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
                    .root_source_file = b.path("src/main.zig"),
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{
                        .{ .name = "wayland", .module = wayland },
                        .{ .name = "c_linux", .module = c_linux.createModule() },
                    },
                }),
            });

            exe.root_module.linkSystemLibrary("wayland-client", .{});
            b.installArtifact(exe);
            check.dependOn(&exe.step);
        },
        else => return error.UnsupportedOS,
    }
}
