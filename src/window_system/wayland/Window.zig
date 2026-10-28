const Window = @This();

base: *WindowSystem.Window,

surface: *cwl.Surface,
viewport: *wp.Viewport,
xdg_surface: *xdg.Surface,
xdg_toplevel: *xdg.Toplevel,

commited_once: bool,
configured: bool,

buffer_pixels: []align(std.heap.page_size_min) u8,
buffer: Wayland.Buffer.Cpu,

pub fn init(
    wl: *Wayland,
    ws: *WindowSystem,
    base: *WindowSystem.Window,
    requested_size: ptypes.Size,
) !Window {
    const width, const height = utils.new_dimensions(
        @intCast(requested_size.width),
        @intCast(requested_size.height),
    );

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
    xdg_toplevel.setAppId(ws.class_of_window);

    const format: ptypes.BufferFormat = .argb8888;
    const size = width * height * format.bytes_per_pixel();
    const fd: ptypes.CpuBufferHandle = @enumFromInt(try std.posix.memfd_create("agce-wayland", 0));
    defer fd.close();

    if (std.posix.errno(std.posix.system.ftruncate(@intFromEnum(fd), size)) != .SUCCESS) return error.FtruncateFailed;
    const pixels = try std.posix.mmap(
        null,
        @intCast(size),
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .SHARED },
        @intFromEnum(fd),
        0,
    );

    const buffer = try Wayland.buffer_create_cpu(
        wl.shm,
        fd,
        .{ .width = width, .height = height },
        format,
    );

    const window: Window = .{
        .base = base,

        .surface = surface,
        .viewport = viewport,
        .xdg_surface = xdg_surface,
        .xdg_toplevel = xdg_toplevel,
        .commited_once = false,
        .configured = false,
        .buffer_pixels = pixels,
        .buffer = buffer,
    };

    xdg_surface.setListener(*WindowSystem, Wayland.xdg_surface_listener, ws);
    xdg_toplevel.setListener(*WindowSystem, Wayland.xdg_toplevel_listener, ws);

    return window;
}

pub fn deinit(window: *Window) void {
    window.xdg_toplevel.destroy();
    window.xdg_surface.destroy();
    window.viewport.destroy();
    window.surface.destroy();

    window.buffer.wl_buffer.destroy();
    std.posix.munmap(window.buffer_pixels);
}

pub fn commit(win: *Window) void {
    win.commited_once = true;
    win.surface.damage(0, 0, win.buffer.size.width, win.buffer.size.height);
    win.surface.attach(win.buffer.wl_buffer, 0, 0);
    win.surface.commit();
}

pub fn viewport_bound(_: *Window, _: *WindowSystem) void {
    log.err("Removed feature. Should be handled by Mux", .{});
    // const key = win.base.viewport_key orelse return;
    // const rs = ws.resources.getPtr(key.client_id) orelse return;
    // const vp = rs.viewports.get(key.viewport_id) orelse return;

    // const width = @min(
    //     vp.render_size.width,
    //     win.buffer.size.width,
    // );

    // const height = @min(
    //     vp.render_size.height,
    //     win.buffer.size.height,
    // );
    // win.viewport.setSource(
    //     .fromInt(0),
    //     .fromInt(0),
    //     .fromInt(@intCast(width)),
    //     .fromInt(@intCast(height)),
    // );
}

pub fn resize(win: *Window, wl: *Wayland, requested_size: ptypes.Size) !void {
    const width, const height = utils.new_dimensions(
        @intCast(requested_size.width),
        @intCast(requested_size.height),
    );

    if (width <= win.buffer.size.width and height <= win.buffer.size.height) {
        return;
    }

    const new_size = width * height * win.buffer.format.bytes_per_pixel();
    const fd: ptypes.CpuBufferHandle = @enumFromInt(try std.posix.memfd_create("agce-wayland", 0));
    defer fd.close();

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

    const new_buffer = try Wayland.buffer_create_cpu(
        wl.shm,
        fd,
        .{ .width = width, .height = height },
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

const log = std.log.scoped(.Wayland);

const std = @import("std");

const c_linux = @import("c_linux");
const cwl = @import("wayland").client.wl;
const ptypes = @import("protocol").types;
const utils = @import("utils");
const wp = @import("wayland").client.wp;
const xdg = @import("wayland").client.xdg;
const zwp = @import("wayland").client.zwp;

const ClientID = @import("../server/Clients.zig").ClientID;
const WindowSystem = @import("../WindowSystem.zig");
const ViewportKey = WindowSystem.ViewportKey;
const WindowID = WindowSystem.WindowID;
const Viewport = @import("Viewport.zig");
const Wayland = @import("Wayland.zig");
