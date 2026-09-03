const Window = @This();

id: WindowID,

surface: *cwl.Surface,
viewport: *wp.Viewport,
xdg_surface: *xdg.Surface,
xdg_toplevel: *xdg.Toplevel,

viewport_key: ViewportKey,
input_focus_keyboard: ViewportKey,
input_focus_mouse: ViewportKey,

commited_once: bool,
configured: bool,

buffer_pixels: []align(std.heap.page_size_min) u8,
buffer: ClientResources.CpuBuffer,

pub fn create(
    wl: *Wayland,
    ws: *WindowSystem,
    window_id: WindowID,
    viewport_key: ViewportKey,
    requested_size: ptypes.Size,
) !*Window {
    const width, const height = utils.new_dimensions(
        @intCast(requested_size.width),
        @intCast(requested_size.height),
    );
    const window = try wl.gpa.create(Window);
    errdefer wl.gpa.destroy(window);

    const surface = try wl.compositor.createSurface();
    errdefer surface.destroy();
    const viewport = try wl.viewporter.getViewport(surface);
    viewport.setSource(
        .fromInt(0),
        .fromInt(0),
        .fromInt(@intCast(width)),
        .fromInt(@intCast(height)),
    );

    const xdg_surface = try wl.wm_base.getXdgSurface(surface);
    errdefer xdg_surface.destroy();

    const xdg_toplevel = try xdg_surface.getToplevel();
    xdg_toplevel.setAppId("agce-server");

    const format: ptypes.BufferFormat = .argb8888;
    const size = width * height * format.bytes_per_pixel();
    const fd: ptypes.CpuBufferFd = @enumFromInt(try std.posix.memfd_create("agce-wayland", 0));
    defer _ = std.os.linux.close(@intFromEnum(fd));

    if (std.posix.errno(std.posix.system.ftruncate(@intFromEnum(fd), size)) != .SUCCESS) return error.FtruncateFailed;
    const pixels = try std.posix.mmap(
        null,
        @intCast(size),
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .SHARED },
        @intFromEnum(fd),
        0,
    );

    const buffer = try ClientResources.buffer_create_cpu(
        wl.shm,
        fd,
        @intCast(width),
        @intCast(height),
        format,
    );

    window.* = .{
        .id = window_id,
        .surface = surface,
        .viewport = viewport,
        .viewport_key = viewport_key,
        .input_focus_keyboard = viewport_key,
        .input_focus_mouse = viewport_key,
        .xdg_surface = xdg_surface,
        .xdg_toplevel = xdg_toplevel,
        .commited_once = false,
        .configured = false,
        .buffer_pixels = pixels,
        .buffer = buffer,
    };

    xdg_surface.setListener(*Wayland, Wayland.xdg_surface_listener, wl);
    xdg_toplevel.setListener(*WindowSystem, Wayland.xdg_toplevel_listener, ws);

    return window;
}

pub fn destroy(window: *Window, gpa: std.mem.Allocator) void {
    window.xdg_toplevel.destroy();
    window.xdg_surface.destroy();
    window.viewport.destroy();
    window.surface.destroy();

    window.buffer.wl_buffer.destroy();
    std.posix.munmap(window.buffer_pixels);

    gpa.destroy(window);
}

pub fn commit(win: *Window) void {
    win.commited_once = true;
    win.surface.damage(0, 0, win.buffer.width, win.buffer.height);
    win.surface.attach(win.buffer.wl_buffer, 0, 0);
    win.surface.commit();
}

pub fn viewport_bound(win: *Window, wl: *Wayland) void {
    const rs = wl.resources_get(win.viewport_key.client_id) catch return;
    const vp = rs.viewports.get(win.viewport_key.viewport_id) orelse return;

    const width = @min(
        vp.render_size.width,
        win.buffer.width,
    );

    const height = @min(
        vp.render_size.height,
        win.buffer.height,
    );
    win.viewport.setSource(
        .fromInt(0),
        .fromInt(0),
        .fromInt(@intCast(width)),
        .fromInt(@intCast(height)),
    );
}

pub fn resize(win: *Window, wl: *Wayland, requested_size: ptypes.Size) !void {
    const width, const height = utils.new_dimensions(
        @intCast(requested_size.width),
        @intCast(requested_size.height),
    );

    if (width <= win.buffer.width and height <= win.buffer.height) {
        return;
    }

    const new_size = width * height * win.buffer.format.bytes_per_pixel();
    const fd: ptypes.CpuBufferFd = @enumFromInt(try std.posix.memfd_create("agce-wayland", 0));
    defer _ = std.os.linux.close(@intFromEnum(fd));

    if (std.posix.errno(std.posix.system.ftruncate(@intFromEnum(fd), new_size)) != .SUCCESS) return error.FtruncateFailed;

    const pixels = try std.posix.mmap(
        null,
        @intCast(new_size),
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .SHARED },
        @intFromEnum(fd),
        0,
    );
    errdefer std.posix.munmap(pixels);

    const new_buffer = try ClientResources.buffer_create_cpu(
        wl.shm,
        fd,
        @intCast(width),
        @intCast(height),
        win.buffer.format,
    );

    errdefer comptime unreachable;

    win.buffer.destroy();
    std.posix.munmap(win.buffer_pixels);

    win.buffer_pixels = pixels;
    win.buffer = new_buffer;

    win.fill_color();
}

fn fill_color(win: *Window) void {
    std.debug.assert(win.buffer.format.bytes_per_pixel() == 4);
    const ptr: [*]u32 = @ptrCast(@alignCast(win.buffer_pixels.ptr));
    const slice: []u32 = ptr[0 .. win.buffer_pixels.len / 4];
    const color = switch (@import("builtin").mode) {
        .Debug => 0xFF000000, // black
        else => 0, // transparent
    };

    for (0..slice.len) |i| {
        slice[i] = color;
    }
}

const std = @import("std");
const cwl = @import("wayland").client.wl;
const wp = @import("wayland").client.wp;
const xdg = @import("wayland").client.xdg;
const zwp = @import("wayland").client.zwp;
const ClientID = @import("../server/Clients.zig").ClientID;
const Viewport = @import("Viewport.zig");
const WindowSystem = @import("../WindowSystem.zig");
const ViewportKey = WindowSystem.ViewportKey;
const WindowID = WindowSystem.WindowID;
const log = std.log.scoped(.Wayland);
const utils = @import("utils");
const c_linux = @import("c_linux");
const Wayland = @import("Wayland.zig");
const ptypes = @import("protocol").types;
const ClientResources = @import("ClientResources.zig");
