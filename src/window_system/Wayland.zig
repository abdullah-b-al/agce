const Wayland = @This();

io: std.Io,
gpa: std.mem.Allocator,

shm: *cwl.Shm,
compositor: *cwl.Compositor,
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
    };

    registry.setListener(*MaybeGlobals, registry_listener, &globals);
    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

    const shm = globals.shm orelse return error.NoWlShm;
    const compositor = globals.compositor orelse return error.NoWlCompositor;
    const wm_base = globals.wm_base orelse return error.NoXdgWmBase;
    const seat = globals.seat orelse return error.NoWlSeat;

    state.* = .{
        .io = io,
        .gpa = gpa,

        .shm = shm,
        .compositor = compositor,
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

pub fn window_create(wl: *Wayland, ws: *WindowSystem, base: WindowBase) !*Window {
    try wl.windows.ensureUnusedCapacity(wl.gpa, 1);

    const window = try wl.gpa.create(Window);
    errdefer wl.gpa.destroy(window);

    var buffer = try Buffer.init(wl.shm, 1280, 720);
    errdefer buffer.deinit();

    const surface = try wl.compositor.createSurface();
    errdefer surface.destroy();

    const xdg_surface = try wl.wm_base.getXdgSurface(surface);
    errdefer xdg_surface.destroy();

    const xdg_toplevel = try xdg_surface.getToplevel();
    xdg_toplevel.setAppId("agce-server");

    window.* = .{
        .base = base,
        .surface = surface,
        .xdg_surface = xdg_surface,
        .xdg_toplevel = xdg_toplevel,
        .configured = false,
        .running = true,
        .buffer = buffer,
    };
    wl.windows.putAssumeCapacityNoClobber(base.id, window);

    xdg_surface.setListener(*WindowSystem, xdg_surface_listener, ws);
    xdg_toplevel.setListener(*WindowSystem, xdg_toplevel_listener, ws);

    return window;
}

pub fn window_commit(_: *Wayland, win: *Window) void {
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
                log.err("Dispatch failed", .{});
            }
        }

        window.surface.attach(window.buffer.buffer, 0, 0);
        window.surface.commit();
    }
}

pub fn window_buffer_resize(wl: *Wayland, window: *Window, width: i32, height: i32) void {
    const old_size = window.buffer.width * window.buffer.height * window.buffer.bpp;
    const new_size = width * height * window.buffer.bpp;

    if (new_size > old_size) {
        const new_buffer = Buffer.init(
            wl.shm,
            width,
            height,
        ) catch return;
        window.buffer.deinit();
        window.buffer = new_buffer;
    } else if (width != window.buffer.width or height != window.buffer.height) {
        window.buffer.down_size(width, height) catch return;
    }
}

pub fn window_buffer_copy_from_front_buffer(_: *Wayland, ws: *const WindowSystem, win: *Window) !void {
    const viewport = ws.viewports.getPtr(win.base.viewport_key) orelse return error.ViewportDoesNotExist;

    if (viewport.size.bpp != win.buffer.bpp) {
        @panic("TODO: Support any BPP");
    }

    for (0..@intCast(win.buffer.width * win.buffer.height)) |i| {
        const pi = i * win.buffer.bpp;
        win.buffer.data[pi + 0] = 0x00; // B
        win.buffer.data[pi + 1] = 0x00; // G
        win.buffer.data[pi + 2] = 0x00; // R
        win.buffer.data[pi + 3] = 0xFF; // A
    }

    utils.pixels_copy(
        win.buffer.data,
        .{
            .width = win.buffer.width,
            .height = win.buffer.height,
            .bpp = win.buffer.bpp,
        },
        viewport.front_buffer,
        .{
            .width = @intCast(viewport.size.width),
            .height = @intCast(viewport.size.height),
            .bpp = viewport.size.bpp,
        },
    );
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
        if (win.xdg_toplevel.getId() == id) return win.base.id;
    }

    unreachable;
}

pub fn window_id_from_xdg_surface(wl: *const Wayland, xdg_surface: *xdg.Surface) WindowID {
    const id = xdg_surface.getId();
    for (wl.windows.values()) |win| {
        if (win.xdg_surface.getId() == id) return win.base.id;
    }

    unreachable;
}

pub const MaybeGlobals = struct {
    shm: ?*cwl.Shm,
    compositor: ?*cwl.Compositor,
    wm_base: ?*xdg.WmBase,
    seat: ?*cwl.Seat,
};

pub const Window = struct {
    base: WindowBase,
    surface: *cwl.Surface,
    xdg_surface: *xdg.Surface,
    xdg_toplevel: *xdg.Toplevel,

    configured: bool,
    running: bool,

    buffer: Buffer,

    pub fn destroy(window: *Window) void {
        window.xdg_toplevel.destroy();
        window.xdg_surface.destroy();
        window.surface.destroy();
    }
};

pub const Buffer = struct {
    data: []align(std.heap.page_size_min) u8,
    pool: *cwl.ShmPool,
    buffer: *cwl.Buffer,
    memfd: c_int,
    width: i32,
    height: i32,
    bpp: u8,
    format: cwl.Shm.Format,

    pub fn init(shm: *cwl.Shm, width: i32, height: i32) !Buffer {
        const bpp = 4;
        const stride = width * bpp;
        const size = stride * height;

        const fd = try std.posix.memfd_create("agce-wayland", 0);
        if (std.posix.errno(std.posix.system.ftruncate(fd, size)) != .SUCCESS) return error.FtruncateFailed;
        const data = try std.posix.mmap(
            null,
            @intCast(size),
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED },
            fd,
            0,
        );

        const pool = try shm.createPool(fd, size);

        const format: cwl.Shm.Format = .argb8888;
        return .{
            .buffer = try pool.createBuffer(0, width, height, stride, format),
            .pool = pool,
            .memfd = fd,
            .width = width,
            .height = height,
            .bpp = bpp,
            .data = data,
            .format = format,
        };
    }

    pub fn deinit(buffer: *Buffer) void {
        buffer.buffer.destroy();
        buffer.pool.destroy();
        std.posix.munmap(buffer.data);
        _ = std.os.linux.close(buffer.memfd);
    }

    pub fn down_size(buffer: *Buffer, width: i32, height: i32) !void {
        std.debug.assert(
            width * height * buffer.bpp <
                buffer.width * buffer.height * buffer.bpp,
        );

        const new_buffer = try buffer.pool.createBuffer(
            0,
            width,
            height,
            width * buffer.bpp,
            buffer.format,
        );

        buffer.buffer.destroy();
        buffer.buffer = new_buffer;
        buffer.width = width;
        buffer.height = height;
    }
};

const std = @import("std");
const cwl = @import("wayland").client.wl;
const xdg = @import("wayland").client.xdg;
const protocol = @import("../server/protocol.zig");
const ClientID = @import("../server/Clients.zig").ClientID;
const Viewport = @import("Viewport.zig");
const WindowSystem = @import("WindowSystem.zig");
const WindowBase = @import("WindowBase.zig");
const WindowID = WindowBase.WindowID;
const log = std.log.scoped(.Wayland);
const utils = @import("../server/utils.zig");
