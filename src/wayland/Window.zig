const Window = @This();

id: WindowID,
surface: *cwl.Surface,

viewport_key: ViewportKey,

xdg_surface: *xdg.Surface,
xdg_toplevel: *xdg.Toplevel,

configured: bool,
running: bool,

buffer_fd: ptypes.CpuBufferFd,
buffer_pixels: []align(std.heap.page_size_min) u8,
buffer: ClientResources.CpuBuffer,

pub fn create(wl: *Wayland, ws: *WindowSystem, window_id: WindowID, viewport_key: ViewportKey, width: i32, height: i32) !*Window {
    const window = try wl.gpa.create(Window);
    errdefer wl.gpa.destroy(window);

    const surface = try wl.compositor.createSurface();
    errdefer surface.destroy();

    const xdg_surface = try wl.wm_base.getXdgSurface(surface);
    errdefer xdg_surface.destroy();

    const xdg_toplevel = try xdg_surface.getToplevel();
    xdg_toplevel.setAppId("agce-server");

    const bytes_per_pixel = 4;
    const size = width * height * bytes_per_pixel;
    const fd: ptypes.CpuBufferFd = @enumFromInt(try std.posix.memfd_create("agce-wayland", 0));
    if (std.posix.errno(std.posix.system.ftruncate(@intFromEnum(fd), size)) != .SUCCESS) return error.FtruncateFailed;
    const pixels = try std.posix.mmap(
        null,
        @intCast(size),
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .SHARED },
        @intFromEnum(fd),
        0,
    );

    const buffer = try ClientResources.buffer_create_cpu(wl.shm, fd, width, height, .argb8888);

    window.* = .{
        .id = window_id,
        .surface = surface,
        .viewport_key = viewport_key,
        .xdg_surface = xdg_surface,
        .xdg_toplevel = xdg_toplevel,
        .configured = false,
        .running = true,
        .buffer_fd = fd,
        .buffer_pixels = pixels,
        .buffer = buffer,
    };

    xdg_surface.setListener(*Wayland, Wayland.xdg_surface_listener, wl);
    xdg_toplevel.setListener(*WindowSystem, Wayland.xdg_toplevel_listener, ws);

    return window;
}

pub fn destroy(window: *Window) void {
    window.xdg_toplevel.destroy();
    window.xdg_surface.destroy();
    window.surface.destroy();
}

pub fn commit(win: *Window) void {
    win.surface.damage(0, 0, win.buffer.width, win.buffer.height);
    win.surface.attach(win.buffer.wl_buffer, 0, 0);
    win.surface.commit();
}

pub fn ensure_configured(win: *Window, wl: *Wayland) void {
    if (!win.configured) {
        win.surface.commit();
        while (!win.configured) {
            if (wl.display.dispatch() != .SUCCESS) {
                // TODO: Should we break from here ?
                log.err("Dispatch failed", .{});
            }
        }

        win.surface.attach(win.buffer.wl_buffer, 0, 0);
        win.surface.commit();
    }
}

pub fn buffer_resize(win: *Window, wl: *Wayland, width: i32, height: i32) !void {
    const new_size = width * height * win.buffer.format.bytes_per_pixel();
    const old_size = win.buffer.width * win.buffer.height * win.buffer.format.bytes_per_pixel();
    if (new_size < old_size) {
        const new_buffer = try ClientResources.buffer_create_cpu(
            wl.shm,
            win.buffer_fd,
            width,
            height,
            win.buffer.format,
        );

        win.buffer.wl_buffer.destroy();
        win.buffer = new_buffer;
    } else {
        const fd: ptypes.CpuBufferFd = @enumFromInt(try std.posix.memfd_create("agce-wayland", 0));
        if (std.posix.errno(std.posix.system.ftruncate(@intFromEnum(fd), new_size)) != .SUCCESS) return error.FtruncateFailed;
        const pixels = try std.posix.mmap(
            null,
            @intCast(new_size),
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED },
            @intFromEnum(fd),
            0,
        );
        const new_buffer = try ClientResources.buffer_create_cpu(
            wl.shm,
            fd,
            width,
            height,
            win.buffer.format,
        );

        errdefer comptime unreachable;

        std.posix.munmap(win.buffer_pixels);
        _ = std.os.linux.close(@intFromEnum(win.buffer_fd));

        win.buffer_pixels = pixels;
        win.buffer_fd = fd;
        win.buffer = new_buffer;
    }
}

const std = @import("std");
const cwl = @import("wayland").client.wl;
const xdg = @import("wayland").client.xdg;
const zwp = @import("wayland").client.zwp;
const ClientID = @import("../server/Clients.zig").ClientID;
const Viewport = @import("Viewport.zig");
const WindowSystem = @import("../WindowSystem.zig");
const ViewportKey = WindowSystem.ViewportKey;
const WindowID = WindowSystem.WindowID;
const log = std.log.scoped(.Wayland);
const utils = @import("../server/utils.zig");
const c_linux = @import("c_linux");
const Wayland = @import("Wayland.zig");
const ptypes = @import("../protocol/types.zig");
const ClientResources = @import("ClientResources.zig");
