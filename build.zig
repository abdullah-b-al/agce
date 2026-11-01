var step_check: *Build.Step = undefined;
var step_all: *Build.Step = undefined;

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const known_folders = b.dependency("known_folders", .{
        .target = target,
        .optimize = optimize,
    }).module("known-folders");

    const zio = b.dependency("zio", .{
        .target = target,
        .optimize = optimize,
    }).module("zio");

    const win32 = b.dependency("win32", .{});

    if (target.result.os.tag == .windows) {
        const meets_minimum_version =
            target.result.os.version_range.windows.isAtLeast(.win10_cu) orelse false;
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

    const constants = b.createModule(.{
        .root_source_file = b.path("src/constants.zig"),
        .target = target,
        .optimize = optimize,
    });

    const utils = b.createModule(.{
        .root_source_file = b.path("src/utils.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "constants", .module = constants },
        },
    });

    const protocol = blk: {
        const module = b.createModule(.{
            .root_source_file = b.path("src/protocol/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "utils", .module = utils },
                .{ .name = "constants", .module = constants },
                .{ .name = "zio", .module = zio },
            },
        });

        if (c_linux) |c| module.addImport("c_linux", c);

        break :blk module;
    };

    const d3d = blk: {
        if (target.result.os.tag != .windows) break :blk null;

        const module = b.createModule(.{
            .root_source_file = b.path("src/d3d/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "protocol", .module = protocol },
                .{ .name = "win32", .module = win32.module("win32") },
            },
        });

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
                .{ .name = "constants", .module = constants },
                .{ .name = "known-folders", .module = known_folders },
            },
        });

        if (c_linux) |c| module.addImport("c_linux", c);
        if (target.result.os.tag == .windows) {
            module.addImport("win32", win32.module("win32"));
            module.addImport("d3d", d3d.?);
        }

        module.linkLibrary(glad.lib);

        break :blk module;
    };

    const step_mux = b.step("mux", "Build the multiplexer");

    step_check = b.step("check", "Check the compilation");
    step_all = b.step("all", "Build everything");

    const wayland = blk: {
        if (target.result.os.tag != .linux) break :blk null;

        const Scanner = @import("wayland").Scanner;
        const scanner = Scanner.create(b, .{});

        const wayland = b.createModule(.{ .root_source_file = scanner.result });

        scanner.addSystemProtocol("stable/xdg-shell/xdg-shell.xml");
        scanner.addSystemProtocol("stable/linux-dmabuf/linux-dmabuf-v1.xml");
        scanner.addSystemProtocol("stable/viewporter/viewporter.xml");
        scanner.addSystemProtocol("stable/tablet/tablet-v2.xml");
        scanner.addSystemProtocol("staging/linux-drm-syncobj/linux-drm-syncobj-v1.xml");
        scanner.addSystemProtocol("staging/cursor-shape/cursor-shape-v1.xml");

        scanner.generate("wl_seat", 4);
        scanner.generate("wl_compositor", 1);
        scanner.generate("wl_subcompositor", 1);
        scanner.generate("wl_shm", 1);
        scanner.generate("xdg_wm_base", 1);
        scanner.generate("zwp_linux_dmabuf_v1", 1);
        scanner.generate("wp_viewporter", 1);
        scanner.generate("wp_linux_drm_syncobj_manager_v1", 1);
        scanner.generate("wp_cursor_shape_manager_v1", 1);

        break :blk wayland;
    };

    const compositor = b.createModule(.{
        .root_source_file = b.path("src/compositor/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "protocol", .module = protocol },
            .{ .name = "utils", .module = utils },
            .{ .name = "constants", .module = constants },
            .{ .name = "zio", .module = zio },
            .{ .name = "known-folders", .module = known_folders },
        },
    });

    const mux = b.createModule(.{
        .root_source_file = b.path("src/mux/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "protocol", .module = protocol },
            .{ .name = "utils", .module = utils },
            .{ .name = "constants", .module = constants },
            .{ .name = "zio", .module = zio },
            .{ .name = "compositor", .module = compositor },
        },
    });

    const embeded = b.createModule(.{
        .root_source_file = b.path("src/embeded/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "protocol", .module = protocol },
            .{ .name = "utils", .module = utils },
            .{ .name = "constants", .module = constants },
            .{ .name = "zio", .module = zio },
            .{ .name = "compositor", .module = compositor },
        },
    });

    inline for (&.{ compositor, mux }) |m| {
        switch (target.result.os.tag) {
            .windows => {
                m.addImport("win32", win32.module("win32"));
                m.addImport("d3d", d3d.?);
            },
            .linux => {
                m.addImport("wayland", wayland.?);
                m.addImport("c_linux", c_linux.?);

                m.linkSystemLibrary("wayland-client", .{});
            },
            else => return error.UnsupportedOS,
        }
    }

    install_exe(b, "agce-mux", mux, step_mux);

    build_tests(b, target, optimize, client, compositor, constants, glad);
    build_sdl_test(b, target, optimize, embeded);
}

fn build_tests(
    b: *Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    client: *Build.Module,
    compositor: *Build.Module,
    constants: *Build.Module,
    glad: Glad,
) void {
    const z2d = b.dependency("z2d", .{
        .target = target,
        .optimize = optimize,
    }).module("z2d");

    const test_step = b.step("test", "Build tests");

    {
        const module = b.createModule(.{
            .root_source_file = b.path("src/tests/tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "client", .module = client },
                .{ .name = "glad", .module = glad.c },
                .{ .name = "compositor", .module = compositor },
                .{ .name = "constants", .module = constants },
                .{ .name = "z2d", .module = z2d },
            },
        });

        module.linkLibrary(glad.lib);

        const t = b.addExecutable(.{
            .name = "tests",
            .root_module = module,
        });
        const artifact = b.addInstallArtifact(t, .{});
        test_step.dependOn(&artifact.step);
        step_all.dependOn(&artifact.step);

        const t_check = b.addExecutable(.{ .name = "tests-check", .root_module = module, .use_llvm = false });
        step_check.dependOn(&t_check.step);
    }

    const helper_processes = .{
        "src/tests/sub_viewport_recursive.zig",
        "src/tests/sub_viewport_filled_rect.zig",
    };

    inline for (helper_processes) |path| {
        const module = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "client", .module = client },
            },
        });

        const name = std.fs.path.stem(std.fs.path.basename(path));
        const t = b.addExecutable(.{
            .name = name,
            .root_module = module,
        });
        const artifact = b.addInstallArtifact(t, .{});
        test_step.dependOn(&artifact.step);
        step_all.dependOn(&artifact.step);

        const t_check = b.addTest(.{ .root_module = module, .use_llvm = false });
        step_check.dependOn(&t_check.step);
    }
}

fn build_sdl_test(
    b: *Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    embeded: *Build.Module,
) void {
    const step = b.step("sdl3", "Build SDL3 test");

    const sdl = b.dependency("sdl", .{
        .target = target,
        .optimize = optimize,
    });
    const sdl3 = sdl.artifact("SDL3");

    const header = blk: {
        const c = b.addTranslateC(.{
            .root_source_file = b.addWriteFiles().add("c.h",
                \\#include <SDL3/SDL.h>
            ),
            .target = target,
            .optimize = optimize,
        });

        c.linkSystemLibrary("SDL3", .{});
        const module = c.createModule();
        module.linkLibrary(sdl3);

        break :blk module;
    };

    const module = b.createModule(.{
        .root_source_file = b.path("src/tests/sdl.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sdl", .module = header },
            .{ .name = "embeded", .module = embeded },
        },
    });
    module.linkLibrary(sdl3);

    install_exe(b, "sdl3", module, step);
}

const Glad = struct {
    lib: *Step.Compile,
    c: *Build.Module,
};
fn build_glad(b: *Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) Glad {
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

fn install_exe(b: *Build, name: []const u8, root: *Build.Module, exe_step: ?*Build.Step) void {
    const exe = b.addExecutable(.{ .name = name, .root_module = root });
    const art = b.addInstallArtifact(exe, .{});
    if (exe_step) |s| s.dependOn(&art.step);
    step_all.dependOn(&art.step);

    const exe_check = b.addExecutable(.{ .name = name, .root_module = root, .use_llvm = false });
    step_check.dependOn(&exe_check.step);
}

const std = @import("std");
const Build = std.Build;
const Step = std.Build.Step;
