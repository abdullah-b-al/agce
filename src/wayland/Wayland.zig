const Wayland = @This();

io: std.Io,
gpa: std.mem.Allocator,

shm: *cwl.Shm,
compositor: *cwl.Compositor,
subcompositor: *cwl.Subcompositor,
wm_base: *xdg.WmBase,
seat: *cwl.Seat,
dmabuf: *zwp.LinuxDmabufV1,
display: *cwl.Display,
registry: *cwl.Registry,

windows: std.array_hash_map.Auto(WindowID, *Window),
buffers: Buffers,

pub fn create(gpa: std.mem.Allocator, io: std.Io) !*Wayland {
    const state = try gpa.create(Wayland);
    const display = try cwl.Display.connect(null);
    const registry = try display.getRegistry();

    var globals = MaybeGlobals{
        .shm = null,
        .compositor = null,
        .wm_base = null,
        .seat = null,
        .subcompositor = null,
        .dmabuf = null,
    };

    registry.setListener(*MaybeGlobals, registry_listener, &globals);
    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

    const shm = globals.shm orelse return error.NoWlShm;
    const compositor = globals.compositor orelse return error.NoWlCompositor;
    const wm_base = globals.wm_base orelse return error.NoXdgWmBase;
    const seat = globals.seat orelse return error.NoWlSeat;
    const subcompositor = globals.subcompositor orelse return error.NoWlSubcompositor;
    const dmabuf = globals.dmabuf orelse return error.NoZwpDmaBuf;

    state.* = .{
        .io = io,
        .gpa = gpa,

        .shm = shm,
        .compositor = compositor,
        .subcompositor = subcompositor,
        .wm_base = wm_base,
        .seat = seat,
        .dmabuf = dmabuf,
        .registry = registry,
        .display = display,

        .windows = .empty,
        .buffers = .init,
    };

    return state;
}

pub fn destroy(state: *Wayland) void {
    state.wm_base.destroy();
    state.compositor.destroy();
    state.shm.destroy();

    state.registry.destroy();
    state.display.disconnect();

    state.gpa.destroy(state);
}

pub fn buffer_create_gpu_with_fd(wl: *Wayland, dispatch: *Dispatch, args: Dispatch.WindowSystemEvent.BufferCreateGpuWithFd) !void {
    const key: BufferKey = .{
        .client_id = args.client_id,
        .buffer_id = args.buffer_id,
    };

    try wl.buffers.buffer_create_and_register_gpu_async(
        dispatch,
        wl,
        key,
        args.fd,
        @intCast(args.width),
        @intCast(args.height),
        args.format,
        args.gbm_bo_modifier,
    );
}

pub fn buffer_create_cpu_with_fd(wl: *Wayland, dispatch: *Dispatch, args: Dispatch.WindowSystemEvent.BufferCreateCpuWithFd) !void {
    const key: BufferKey = .{
        .client_id = args.client_id,
        .buffer_id = args.buffer_id,
    };

    try wl.buffers.buffer_create_and_register_cpu(
        dispatch,
        wl.gpa,
        wl.shm,
        key,
        args.fd,
        @intCast(args.width),
        @intCast(args.height),
        args.format,
    );
}

pub fn buffer_present(wl: *Wayland, args: Dispatch.WindowSystemEvent.BufferPresent) !void {
    const buffer_key: BufferKey = .{ .client_id = args.client_id, .buffer_id = args.buffer_id };
    const viewport_key: ViewportKey = .{ .client_id = args.client_id, .viewport_id = args.viewport_id };

    const result = wl.subsurface_and_window_from_viewport_key(viewport_key) orelse {
        log.err("Viewport does not exist {}", .{viewport_key});
        return;
    };
    const buffer = wl.buffers.buffer_get(buffer_key) orelse {
        log.err("Buffer does not exist {}", .{buffer_key});
        return;
    };

    try wl.buffers.viewport_mark_commit(wl.gpa, buffer_key, viewport_key.viewport_id);
    result.subsurface.surface.damage(0, 0, buffer.width(), buffer.height());
    result.subsurface.surface.attach(buffer.wl_buffer(), 0, 0);
    result.subsurface.surface.commit();
    log.debug("buffer_present: commited subsurface for {} {}", .{ buffer_key, viewport_key });

    result.window.commit();
    _ = wl.display.flush();
}

pub fn window_create(wl: *Wayland, ws: *WindowSystem, args: Dispatch.WindowSystemEvent.WindowCreate) !void {
    try wl.windows.ensureUnusedCapacity(wl.gpa, 1);

    const id = ws.window_next_id.increment();

    const key: ViewportKey = .{ .client_id = args.client_id, .viewport_id = args.viewport_id };

    const window = try Window.create(
        wl,
        ws,
        id,
        key,
        @intCast(args.width),
        @intCast(args.height),
    );
    wl.windows.putAssumeCapacityNoClobber(id, window);

    window.ensure_configured(wl);
}

pub fn window_resize_by_display_server(wl: *Wayland, args: Dispatch.WindowSystemEvent.WindowResize) !Dispatch.ServerEvent.ViewportResize {
    const win = wl.windows.get(args.id) orelse {
        return error.WindowDoesNotExist;
    };

    try win.buffer_resize(wl, args.width, args.height);
    fill_black(
        win.buffer_pixels,
        win.buffer.width,
        win.buffer.height,
        win.buffer.format.bytes_per_pixel(),
    );
    win.commit();
    _ = wl.display.flush();

    return .{
        .client_id = win.subsurface.viewport_key.client_id,
        .resize = .{
            .viewport_id = win.subsurface.viewport_key.viewport_id,
            .width = @intCast(args.width),
            .height = @intCast(args.height),
        },
    };
}

pub fn set_listeners(wl: *Wayland, ws: *WindowSystem) !void {
    const keyboard = try wl.seat.getKeyboard();
    keyboard.setListener(*WindowSystem, keyboard_listener, ws);
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
            } else if (std.mem.orderZ(u8, global.interface, zwp.LinuxDmabufV1.interface.name) == .eq) {
                globals.dmabuf = registry.bind(global.name, zwp.LinuxDmabufV1, 1) catch return;
            }
        },
        .global_remove => {},
    }
}

pub fn xdg_surface_listener(xdg_surface: *xdg.Surface, event: xdg.Surface.Event, wl: *Wayland) void {
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

pub fn xdg_toplevel_listener(tl: *xdg.Toplevel, event: xdg.Toplevel.Event, ws: *WindowSystem) void {
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

pub fn subsurface_and_window_from_viewport_key(wl: *const Wayland, key: ViewportKey) ?struct { window: *Window, subsurface: *Subsurface } {
    for (wl.windows.values()) |win| {
        if (std.meta.eql(win.subsurface.viewport_key, key)) {
            return .{ .window = win, .subsurface = &win.subsurface };
        }
    }

    return null;
}

pub const MaybeGlobals = struct {
    shm: ?*cwl.Shm,
    compositor: ?*cwl.Compositor,
    wm_base: ?*xdg.WmBase,
    seat: ?*cwl.Seat,
    subcompositor: ?*cwl.Subcompositor,
    dmabuf: ?*zwp.LinuxDmabufV1,
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
const zwp = @import("wayland").client.zwp;
const ClientID = @import("../server/Clients.zig").ClientID;
const WindowSystem = @import("../WindowSystem.zig");
const WindowID = WindowSystem.WindowID;
const log = std.log.scoped(.Wayland);
const utils = @import("../server/utils.zig");
const Buffers = @import("Buffers.zig");
const Window = @import("Window.zig");
const Subsurface = @import("Subsurface.zig");
const c_linux = @import("c_linux");
const DoubleBuffer = Buffers.DoubleBuffer;
const BufferID = Buffers.BufferID;
const Dispatch = @import("../Dispatch.zig");
const BufferKey = WindowSystem.BufferKey;
const ViewportKey = WindowSystem.ViewportKey;
