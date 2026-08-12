pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    if (target.result.os.tag == .windows) {
        const meets_minimum_version =
            target.result.os.version_range.windows.isAtLeast(.win10_rs4) orelse false;
        if (!meets_minimum_version) {
            return error.UnsupportedWindowsVersion;
        }
    }

    const c_linux =
        switch (target.result.os.tag) {
            .linux => blk: {
                const c = b.addTranslateC(.{
                    .root_source_file = b.path("src/c_linux.h"),
                    .target = target,
                    .optimize = optimize,
                    .link_libc = true,
                });

                c.linkSystemLibrary("egl", .{});
                c.linkSystemLibrary("gbm", .{});
                c.linkSystemLibrary("drm", .{});
                c.linkSystemLibrary("xkbcommon", .{});
                break :blk c.createModule();
            },
            else => null,
        };

    const glad = build_glad(b, target, optimize);

    const utils = b.createModule(.{
        .root_source_file = b.path("src/utils.zig"),
        .target = target,
        .optimize = optimize,
    });

    const protocol = blk: {
        const module = b.createModule(.{
            .root_source_file = b.path("src/protocol/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "utils", .module = utils },
            },
        });

        if (c_linux) |c| module.addImport("c_linux", c);

        break :blk module;
    };

    const client = blk: {
        const module = b.addModule("client", .{
            .root_source_file = b.path("src/client/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "protocol", .module = protocol },
                .{ .name = "utils", .module = utils },
                .{ .name = "glad", .module = glad.c },
            },
        });

        if (c_linux) |c| module.addImport("c_linux", c);

        module.linkLibrary(glad.lib);

        break :blk module;
    };

    const check = b.step("check", "Check the compilation");

    { // client cli
        const exe = b.addExecutable(.{
            .name = "agce-client",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main_client.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "glad", .module = glad.c },
                    .{ .name = "client", .module = client },
                },
            }),
        });

        if (c_linux) |c| exe.root_module.addImport("c_linux", c);

        exe.root_module.linkLibrary(glad.lib);

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
            scanner.addSystemProtocol("stable/linux-dmabuf/linux-dmabuf-v1.xml");
            scanner.addSystemProtocol("stable/viewporter/viewporter.xml");
            scanner.addSystemProtocol("staging/linux-drm-syncobj/linux-drm-syncobj-v1.xml");

            scanner.generate("wl_seat", 4);
            scanner.generate("wl_compositor", 1);
            scanner.generate("wl_subcompositor", 1);
            scanner.generate("wl_shm", 1);
            scanner.generate("xdg_wm_base", 1);
            scanner.generate("zwp_linux_dmabuf_v1", 1);
            scanner.generate("wp_viewporter", 1);
            scanner.generate("wp_linux_drm_syncobj_manager_v1", 1);

            const exe = b.addExecutable(.{
                .name = "agce",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("src/main.zig"),
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{
                        .{ .name = "wayland", .module = wayland },
                        .{ .name = "c_linux", .module = c_linux.? },
                        .{ .name = "protocol", .module = protocol },
                        .{ .name = "utils", .module = utils },
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

fn build_glad(b: *Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) struct {
    lib: *Step.Compile,
    c: *Build.Module,
} {
    const lib = b.addLibrary(.{
        .name = "glad",
        .root_module = b.createModule(.{
            .root_source_file = null,
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    lib.root_module.addIncludePath(b.path("src/glad/include"));
    lib.root_module.addCSourceFiles(.{
        .root = b.path("src/glad"),
        .files = &.{
            "src/egl.c",
            "src/gles2.c",
        },
    });

    const c = b.addTranslateC(.{
        .root_source_file = b.path("src/glad/translate_glad.h"),
        .target = target,
        .optimize = optimize,
    });
    c.addIncludePath(b.path("src/glad/include"));

    return .{
        .lib = lib,
        .c = c.createModule(),
    };
}

const std = @import("std");
const Build = std.Build;
const Step = std.Build.Step;
