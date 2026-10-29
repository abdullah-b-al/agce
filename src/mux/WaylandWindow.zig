const WaylandWindow = @This();

surface: *cwl.Surface,
viewport: *wp.Viewport,
xdg_surface: *xdg.Surface,
xdg_toplevel: *xdg.Toplevel,

commited_once: bool,
configured: bool,

buffer_pixels: []align(std.heap.page_size_min) u8,
buffer: CpuBuffer,

pub fn init(
    mux: *Mux,
    requested_size: ptypes.Size,
) !WaylandWindow {
    const width, const height = utils.new_dimensions(
        @intCast(requested_size.width),
        @intCast(requested_size.height),
    );

    const surface = try mux.wayland_objects.compositor.createSurface();
    errdefer surface.destroy();
    const viewport = try mux.wayland_objects.viewporter.getViewport(surface);
    viewport.setSource(
        .fromInt(0),
        .fromInt(0),
        .fromInt(@intCast(width)),
        .fromInt(@intCast(height)),
    );

    const xdg_surface = try mux.wayland_objects.wm_base.getXdgSurface(surface);
    errdefer xdg_surface.destroy();

    const xdg_toplevel = try xdg_surface.getToplevel();
    xdg_toplevel.setAppId(mux.compositor.class_of_window);

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

    const buffer: CpuBuffer = try .buffer_create_cpu(
        mux.wayland_objects.shm,
        fd,
        .{ .width = width, .height = height },
        format,
    );

    const window: WaylandWindow = .{
        .surface = surface,
        .viewport = viewport,
        .xdg_surface = xdg_surface,
        .xdg_toplevel = xdg_toplevel,
        .commited_once = false,
        .configured = false,
        .buffer_pixels = pixels,
        .buffer = buffer,
    };

    xdg_surface.setListener(*Mux, listener_xdg_surface, mux);
    xdg_toplevel.setListener(*Mux, listener_xdg_toplevel, mux);

    return window;
}

pub fn deinit(window: *WaylandWindow) void {
    window.xdg_toplevel.destroy();
    window.xdg_surface.destroy();
    window.viewport.destroy();
    window.surface.destroy();

    window.buffer.wl_buffer.destroy();
    std.posix.munmap(window.buffer_pixels);
}

pub fn commit(win: *WaylandWindow) void {
    win.commited_once = true;
    win.surface.damage(0, 0, win.buffer.size.width, win.buffer.size.height);
    win.surface.attach(win.buffer.wl_buffer, 0, 0);
    win.surface.commit();
}

pub fn resize(win: *WaylandWindow, mux: *Mux, requested_size: ptypes.Size) !void {
    const width, const height = utils.new_dimensions(
        @intCast(requested_size.width),
        @intCast(requested_size.height),
    );

    if (width <= win.buffer.size.width and height <= win.buffer.size.height) {
        return;
    }

    const new_size = width * height * win.buffer.format.bytes_per_pixel();
    const fd: ptypes.CpuBufferHandle = @enumFromInt(try std.posix.memfd_create("agce-mux-wayland", 0));
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

    const new_buffer: CpuBuffer = try .buffer_create_cpu(
        mux.wayland_objects.shm,
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

fn fill_color(win: *WaylandWindow) void {
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

pub fn listener_xdg_surface(xdg_surface: *xdg.Surface, event: xdg.Surface.Event, mux: *Mux) void {
    switch (event) {
        .configure => |configure| {
            xdg_surface.ackConfigure(configure.serial);
            const id = window_id_from_xdg_surface(mux, xdg_surface);
            const win = mux.windows.get(id).?;
            win.linux.wayland.surface.commit();
            win.linux.wayland.configured = true;
        },
    }
}

pub fn listener_xdg_toplevel(tl: *xdg.Toplevel, event: xdg.Toplevel.Event, mux: *Mux) void {
    const window_id = window_id_from_toplevel(mux, tl);

    const win = mux.windows.get(window_id) orelse {
        return;
    };

    switch (event) {
        .configure => |configure| {
            if (configure.width == 0 or configure.height == 0) return;

            const size: ptypes.Size = .{
                .width = @intCast(configure.width),
                .height = @intCast(configure.height),
            };
            win.linux.wayland.resize(mux, size) catch return;
            win.linux.wayland.surface.commit();

            mux.compositor.window_update_size(win.id, size) catch |err| switch (err) {
                error.WindowNotRegistered => unreachable,
            };

            mux.compositor.server_events.ensure_unused_capacity(1) catch return;
            mux.compositor.server_events.push_assume_capacity(.{
                .viewport_resize = .{
                    .client_id = win.viewport_key.client_id,
                    .payload = .{
                        .viewport_id = win.viewport_key.viewport_id,
                        .size = size,
                    },
                },
            });
        },

        .close => {
            mux.compositor.deferred_events.appendAssumeCapacity(.{
                .viewport_should_close = .{ .viewport_key = win.viewport_key },
            });
        },
    }
}

pub fn listener_keyboard(_: *cwl.Keyboard, event: cwl.Keyboard.Event, mux: *Mux) void {
    switch (event) {
        inline .leave, .enter => |e, tag| {
            const surface = e.surface orelse {
                log.warn("Dropping keyboard event .{t}: No surface", .{tag});
                return;
            };

            const window_id = window_id_from_window_surface(mux, surface) orelse {
                return;
            };

            const win = mux.windows.get(window_id) orelse return;

            mux.compositor.window_focused_by_keyboard(win.viewport_key);
        },
        else => {},
    }
}

fn window_id_from_window_surface(mux: *Mux, surface: *cwl.Surface) ?WindowID {
    for (mux.windows.values()) |win| {
        if (win.linux.wayland.surface == surface) {
            return win.id;
        }
    }

    return null;
}

pub fn window_id_from_toplevel(mux: *const Mux, tl: *xdg.Toplevel) WindowID {
    const id = tl.getId();
    for (mux.windows.values()) |win| {
        if (win.linux.wayland.xdg_toplevel.getId() == id) return win.id;
    }

    unreachable;
}

pub fn window_id_from_xdg_surface(mux: *const Mux, xdg_surface: *xdg.Surface) WindowID {
    const id = xdg_surface.getId();
    for (mux.windows.values()) |win| {
        if (win.linux.wayland.xdg_surface.getId() == id) return win.id;
    }

    unreachable;
}

pub const CpuBuffer = struct {
    wl_buffer: *cwl.Buffer,
    size: ptypes.Size,
    format: ptypes.BufferFormat,

    pub fn buffer_create_cpu(
        shm: *cwl.Shm,
        fd: ptypes.CpuBufferHandle,
        size: ptypes.Size,
        format: ptypes.BufferFormat,
    ) !CpuBuffer {
        const stride = size.width * format.bytes_per_pixel();
        const byte_size = size.width * size.height * format.bytes_per_pixel();
        const pool = try shm.createPool(@intFromEnum(fd), byte_size);
        defer pool.destroy();

        const wl_format: cwl.Shm.Format = switch (format) {
            .argb8888 => .argb8888,
        };

        const buffer = try pool.createBuffer(0, size.width, size.height, stride, wl_format);

        return .{
            .wl_buffer = buffer,
            .size = size,
            .format = format,
        };
    }

    pub fn destroy(cpu: CpuBuffer) void {
        cpu.wl_buffer.destroy();
    }
};

const std = @import("std");
const cwl = @import("wayland").client.wl;
const wp = @import("wayland").client.wp;
const xdg = @import("wayland").client.xdg;
const zwp = @import("wayland").client.zwp;
const Mux = @import("Mux.zig");
const WindowID = @import("compositor").Compositor.WindowID;
const log = std.log.scoped(.Mux);
const utils = @import("utils");
const c_linux = @import("c_linux");
const ptypes = @import("protocol").types;
const Compositor = @import("compositor").Compositor;
