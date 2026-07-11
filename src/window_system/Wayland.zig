const Wayland = @This();

io: std.Io,
gpa: std.mem.Allocator,

shm: *cwl.Shm,
compositor: *cwl.Compositor,
subcompositor: *cwl.Subcompositor,
wm_base: *xdg.WmBase,
seat: *cwl.Seat,
display: *cwl.Display,
registry: *cwl.Registry,

windows: std.array_hash_map.Auto(WindowID, *Window),

pub fn init(gpa: std.mem.Allocator, io: std.Io) !*Wayland {
    const state = try gpa.create(Wayland);
    const display = try cwl.Display.connect(null);
    const registry = try display.getRegistry();

    var globals = MaybeGlobals{
        .shm = null,
        .compositor = null,
        .wm_base = null,
        .seat = null,
        .subcompositor = null,
    };

    registry.setListener(*MaybeGlobals, registry_listener, &globals);
    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

    const shm = globals.shm orelse return error.NoWlShm;
    const compositor = globals.compositor orelse return error.NoWlCompositor;
    const wm_base = globals.wm_base orelse return error.NoXdgWmBase;
    const seat = globals.seat orelse return error.NoWlSeat;
    const subcompositor = globals.subcompositor orelse return error.NoWlSubcompositor;

    state.* = .{
        .io = io,
        .gpa = gpa,

        .shm = shm,
        .compositor = compositor,
        .subcompositor = subcompositor,
        .wm_base = wm_base,
        .seat = seat,
        .registry = registry,
        .display = display,

        .windows = .empty,
    };

    return state;
}

pub fn deinit(state: *Wayland) void {
    state.wm_base.destroy();
    state.compositor.destroy();
    state.shm.destroy();

    state.registry.destroy();
    state.display.disconnect();

    state.gpa.destroy(state);
}

pub fn set_listeners(wl: *Wayland, ws: *WindowSystem) !void {
    const keyboard = try wl.seat.getKeyboard();
    keyboard.setListener(*WindowSystem, keyboard_listener, ws);
}

pub fn window_create(wl: *Wayland, ws: *WindowSystem, window_id: WindowID, viewport: Viewport) !*Window {
    try wl.windows.ensureUnusedCapacity(wl.gpa, 1);

    const window = try wl.gpa.create(Window);
    errdefer wl.gpa.destroy(window);

    const surface = try wl.compositor.createSurface();
    errdefer surface.destroy();

    const xdg_surface = try wl.wm_base.getXdgSurface(surface);
    errdefer xdg_surface.destroy();

    const xdg_toplevel = try xdg_surface.getToplevel();
    xdg_toplevel.setAppId("agce-server");

    const subsurface = try wl.window_subsurface_create(surface, viewport);

    const bytes_per_pixel = 4;
    const size = viewport.size.width * viewport.size.height * bytes_per_pixel;
    const fd = try std.posix.memfd_create("agce-wayland", 0);
    if (std.posix.errno(std.posix.system.ftruncate(fd, size)) != .SUCCESS) return error.FtruncateFailed;
    const pixels = try std.posix.mmap(
        null,
        @intCast(size),
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .SHARED },
        fd,
        0,
    );

    const width: i32 = @intCast(viewport.size.width);
    const height: i32 = @intCast(viewport.size.height);
    const buffer = try CpuBuffer.init(wl, fd, width, height, bytes_per_pixel);

    window.* = .{
        .id = window_id,
        .surface = surface,
        .subsurface = subsurface,
        .xdg_surface = xdg_surface,
        .xdg_toplevel = xdg_toplevel,
        .configured = false,
        .running = true,
        .buffer_fd = fd,
        .buffer_pixels = pixels,
        .buffer = buffer,
    };
    wl.windows.putAssumeCapacityNoClobber(window_id, window);

    xdg_surface.setListener(*WindowSystem, xdg_surface_listener, ws);
    xdg_toplevel.setListener(*WindowSystem, xdg_toplevel_listener, ws);

    return window;
}

pub fn viewport_overridden(wl: *Wayland, viewport: Viewport) !void {
    for (wl.windows.values()) |win| {
        if (!std.meta.eql(win.subsurface.buffer.viewport_key, viewport.key)) {
            continue;
        }

        var buffer_back = try CpuBuffer.init(
            wl,
            viewport.back_fd,
            @intCast(viewport.size.width),
            @intCast(viewport.size.height),
            viewport.size.bpp,
        );
        errdefer buffer_back.deinit();

        var buffer_front = try CpuBuffer.init(
            wl,
            viewport.front_fd,
            @intCast(viewport.size.width),
            @intCast(viewport.size.height),
            viewport.size.bpp,
        );
        errdefer buffer_front.deinit();

        switch (win.subsurface.buffer.front) {
            .cpu => {
                win.subsurface.buffer.front.cpu.deinit();
                win.subsurface.buffer.back.cpu.deinit();
            },
            .gpu => @panic("TODO"),
        }
        win.subsurface.buffer = .{
            .viewport_key = viewport.key,
            .back = .{ .cpu = buffer_back },
            .front = .{ .cpu = buffer_front },
        };
    }
}

pub fn window_subsurface_create(wl: *Wayland, parent_surface: *cwl.Surface, viewport: Viewport) !Subsurface {
    var buffer_back = try CpuBuffer.init(
        wl,
        viewport.back_fd,
        @intCast(viewport.size.width),
        @intCast(viewport.size.height),
        viewport.size.bpp,
    );
    errdefer buffer_back.deinit();

    var buffer_front = try CpuBuffer.init(
        wl,
        viewport.front_fd,
        @intCast(viewport.size.width),
        @intCast(viewport.size.height),
        viewport.size.bpp,
    );
    errdefer buffer_front.deinit();

    const surface = try wl.compositor.createSurface();
    errdefer surface.destroy();

    const subsurface = try wl.subcompositor.getSubsurface(surface, parent_surface);

    return .{
        .surface = surface,
        .subsurface = subsurface,
        .buffer = .{
            .viewport_key = viewport.key,
            .back = .{ .cpu = buffer_back },
            .front = .{ .cpu = buffer_front },
        },
        .viewport_key = viewport.key,
        .damaged = true,
    };
}

pub fn window_commit(_: *Wayland, win: *Window) void {
    if (win.subsurface.damaged) {
        win.subsurface.surface.damage(0, 0, win.subsurface.buffer.width(), win.subsurface.buffer.height());
        win.subsurface.surface.attach(win.subsurface.buffer.wl_buffer(), 0, 0);
        win.subsurface.surface.commit();
        win.subsurface.damaged = false;
    }

    win.surface.damage(0, 0, win.buffer.width, win.buffer.height);
    win.surface.attach(win.buffer.buffer, 0, 0);

    win.surface.commit();
}

pub fn dispatch(wl: *Wayland) void {
    if (wl.display.dispatch() != .SUCCESS) {
        log.err("Dispatch failed", .{});
        return;
    }
}

pub fn window_ensure_configured(state: *Wayland, window: *Window) void {
    if (!window.configured) {
        window.surface.commit();
        while (!window.configured) {
            if (state.display.dispatch() != .SUCCESS) {
                // TODO: Should we break from here ?
                log.err("Dispatch failed", .{});
            }
        }

        window.surface.attach(window.buffer.buffer, 0, 0);
        window.surface.commit();
    }
}

pub fn buffers_swap(_: *Wayland, subsurface: *Subsurface) !void {
    subsurface.damaged = true;

    subsurface.buffer.swap();
}

pub fn buffer_size_set_to_viewport(wl: *Wayland, viewport: Viewport) void {
    for (wl.windows.values()) |win| {
        if (std.meta.eql(win.subsurface.viewport_key, viewport.key)) {
            win.subsurface.buffer.resize(
                wl,
                viewport,
                @intCast(viewport.size.width),
                @intCast(viewport.size.height),
            );
        }
    }
}

fn registry_listener(registry: *cwl.Registry, event: cwl.Registry.Event, globals: *MaybeGlobals) void {
    switch (event) {
        .global => |global| {
            if (std.mem.orderZ(u8, global.interface, cwl.Compositor.interface.name) == .eq) {
                globals.compositor = registry.bind(global.name, cwl.Compositor, 1) catch return;
            } else if (std.mem.orderZ(u8, global.interface, cwl.Shm.interface.name) == .eq) {
                globals.shm = registry.bind(global.name, cwl.Shm, 1) catch return;
            } else if (std.mem.orderZ(u8, global.interface, xdg.WmBase.interface.name) == .eq) {
                globals.wm_base = registry.bind(global.name, xdg.WmBase, 1) catch return;
            } else if (std.mem.orderZ(u8, global.interface, cwl.Seat.interface.name) == .eq) {
                globals.seat = registry.bind(global.name, cwl.Seat, 1) catch return;
            } else if (std.mem.orderZ(u8, global.interface, cwl.Subcompositor.interface.name) == .eq) {
                globals.subcompositor = registry.bind(global.name, cwl.Subcompositor, 1) catch return;
            }
        },
        .global_remove => {},
    }
}

fn xdg_surface_listener(xdg_surface: *xdg.Surface, event: xdg.Surface.Event, ws: *WindowSystem) void {
    const wl = ws.native.wayland;
    switch (event) {
        .configure => |configure| {
            xdg_surface.ackConfigure(configure.serial);
            const id = wl.window_id_from_xdg_surface(xdg_surface);
            const win = wl.windows.get(id).?;
            win.surface.commit();
            win.configured = true;
        },
    }
}

fn xdg_toplevel_listener(tl: *xdg.Toplevel, event: xdg.Toplevel.Event, ws: *WindowSystem) void {
    const wl = ws.native.wayland;
    const window_id = wl.window_id_from_toplevel(tl);
    const window = wl.windows.get(window_id).?;

    switch (event) {
        .configure => |configure| {
            if (configure.width == 0 or configure.height == 0) return;

            if (configure.width != window.buffer.width or configure.height != window.buffer.height) {
                ws.event_handle(.{
                    .window_resize_by_display_server = .{
                        .id = window_id,
                        .width = configure.width,
                        .height = configure.height,
                    },
                }) catch return;
            }
        },

        .close => {
            window.running = false;
        },
    }
}

fn keyboard_listener(keyboard: *cwl.Keyboard, event: cwl.Keyboard.Event, ws: *WindowSystem) void {
    _ = event;
    _ = ws;
    _ = keyboard;
}

pub fn window_id_from_toplevel(wl: *const Wayland, tl: *xdg.Toplevel) WindowID {
    const id = tl.getId();
    for (wl.windows.values()) |win| {
        if (win.xdg_toplevel.getId() == id) return win.id;
    }

    unreachable;
}

pub fn window_id_from_xdg_surface(wl: *const Wayland, xdg_surface: *xdg.Surface) WindowID {
    const id = xdg_surface.getId();
    for (wl.windows.values()) |win| {
        if (win.xdg_surface.getId() == id) return win.id;
    }

    unreachable;
}

pub const MaybeGlobals = struct {
    shm: ?*cwl.Shm,
    compositor: ?*cwl.Compositor,
    wm_base: ?*xdg.WmBase,
    seat: ?*cwl.Seat,
    subcompositor: ?*cwl.Subcompositor,
};

pub const Window = struct {
    id: WindowID,
    surface: *cwl.Surface,
    subsurface: Subsurface,

    xdg_surface: *xdg.Surface,
    xdg_toplevel: *xdg.Toplevel,

    configured: bool,
    running: bool,

    buffer_fd: c_int,
    buffer_pixels: []align(std.heap.page_size_min) u8,
    buffer: CpuBuffer,

    pub fn destroy(window: *Window) void {
        window.xdg_toplevel.destroy();
        window.xdg_surface.destroy();
        window.surface.destroy();
    }

    pub fn buffer_resize(win: *Window, wl: *Wayland, width: i32, height: i32) !void {
        const new_size = width * height * win.buffer.bytes_per_pixel;
        const old_size = win.buffer.width * win.buffer.height * win.buffer.bytes_per_pixel;
        if (new_size < old_size) {
            try win.buffer.down_size(width, height);
        } else {
            const fd = try std.posix.memfd_create("agce-wayland", 0);
            if (std.posix.errno(std.posix.system.ftruncate(fd, new_size)) != .SUCCESS) return error.FtruncateFailed;
            const pixels = try std.posix.mmap(
                null,
                @intCast(new_size),
                .{ .READ = true, .WRITE = true },
                .{ .TYPE = .SHARED },
                fd,
                0,
            );

            const buffer = try CpuBuffer.init(wl, fd, width, height, win.buffer.bytes_per_pixel);

            errdefer comptime unreachable;

            std.posix.munmap(win.buffer_pixels);
            win.buffer.deinit();
            _ = std.os.linux.close(win.buffer_fd);

            win.buffer_pixels = pixels;
            win.buffer_fd = fd;
            win.buffer = buffer;
        }
    }
};

pub const Subsurface = struct {
    surface: *cwl.Surface,
    subsurface: *cwl.Subsurface,
    buffer: Buffer,
    viewport_key: ViewportKey,
    damaged: bool,
};

pub const Buffer = struct {
    viewport_key: ViewportKey,
    back: Source,
    front: Source,

    pub fn swap(b: *Buffer) void {
        std.mem.swap(Source, &b.back, &b.front);
    }

    pub fn width(b: *Buffer) i32 {
        return switch (b.front) {
            .cpu => |*buffer| buffer.width,
            .gpu => @panic("TODO"),
        };
    }

    pub fn height(b: *Buffer) i32 {
        return switch (b.front) {
            .cpu => |*buffer| buffer.height,
            .gpu => @panic("TODO"),
        };
    }

    pub fn wl_buffer(buffer: *Buffer) *cwl.Buffer {
        return switch (buffer.front) {
            .gpu => |b| b.buffer,
            .cpu => |b| b.buffer,
        };
    }
    pub fn resize(b: *Buffer, wl: *Wayland, vp: Viewport, w: i32, h: i32) void {
        switch (b.front) {
            .cpu => |*buffer| buffer.resize(wl, vp.front_fd, w, h),
            .gpu => @panic("TODO"),
        }
        switch (b.back) {
            .cpu => |*buffer| buffer.resize(wl, vp.back_fd, w, h),
            .gpu => @panic("TODO"),
        }
    }

    const Source = union(enum) {
        gpu: GpuBuffer,
        cpu: CpuBuffer,
    };
};

pub const GpuBuffer = struct {
    buffer: *cwl.Buffer,
    width: i32,
    height: i32,
};

pub const CpuBuffer = struct {
    pool: *cwl.ShmPool,
    buffer: *cwl.Buffer,
    width: i32,
    height: i32,
    bytes_per_pixel: u8,
    format: cwl.Shm.Format,

    pub fn init(wl: *Wayland, fd: c_int, width: i32, height: i32, byte_per_pixel: u8) !CpuBuffer {
        const stride = width * byte_per_pixel;
        const size = stride * height;

        const pool = try wl.shm.createPool(fd, @intCast(size));

        const format: cwl.Shm.Format = .argb8888;
        return .{
            .pool = pool,
            .buffer = try pool.createBuffer(0, width, height, @intCast(stride), format),
            .width = width,
            .height = height,
            .bytes_per_pixel = byte_per_pixel,
            .format = format,
        };
    }

    pub fn deinit(buffer: *CpuBuffer) void {
        buffer.buffer.destroy();
        buffer.pool.destroy();
    }

    pub fn resize(buffer: *CpuBuffer, wl: *Wayland, fd: c_int, width: i32, height: i32) void {
        const old_size = buffer.width * buffer.height * buffer.bytes_per_pixel;
        const new_size = width * height * buffer.bytes_per_pixel;

        if (new_size > old_size) {
            const new_buffer = CpuBuffer.init(wl, fd, width, height, buffer.bytes_per_pixel) catch return;
            buffer.deinit();
            buffer.* = new_buffer;
        } else if (width != buffer.width or height != buffer.height) {
            buffer.down_size(width, height) catch return;
        }
    }

    pub fn down_size(buffer: *CpuBuffer, width: i32, height: i32) !void {
        std.debug.assert(
            width * height * buffer.bytes_per_pixel <
                buffer.width * buffer.height * buffer.bytes_per_pixel,
        );

        const stride = width * buffer.bytes_per_pixel;
        const new_buffer = try buffer.pool.createBuffer(0, width, height, stride, buffer.format);
        buffer.buffer.destroy();
        buffer.buffer = new_buffer;

        buffer.width = width;
        buffer.height = height;
    }
};

pub fn fill_black(buffer: []u8, width: i32, height: i32, bpp: u8) void {
    for (0..@intCast(width * height)) |i| {
        const pi = i * bpp;
        buffer[pi + 0] = 0x00; // B
        buffer[pi + 1] = 0x00; // G
        buffer[pi + 2] = 0x00; // R
        buffer[pi + 3] = 0xFF; // A
    }
}

const std = @import("std");
const cwl = @import("wayland").client.wl;
const xdg = @import("wayland").client.xdg;
const ClientID = @import("../server/Clients.zig").ClientID;
const Viewport = @import("Viewport.zig");
const WindowSystem = @import("WindowSystem.zig");
const ViewportKey = WindowSystem.ViewportKey;
const WindowBase = @import("WindowBase.zig");
const WindowID = WindowBase.WindowID;
const log = std.log.scoped(.Wayland);
const utils = @import("../server/utils.zig");
