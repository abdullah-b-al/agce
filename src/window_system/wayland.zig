pub fn init(gpa: std.mem.Allocator, io: std.Io) !*State {
    const state = try gpa.create(State);
    const display = try wl.Display.connect(null);
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

        .windows = .init,
    };

    const keyboard = try state.seat.getKeyboard();

    keyboard.setListener(*State, keyboard_listener, state);

    return state;
}

pub fn window_create(state: *State) !void {
    const buffer = try Buffer.init(state.shm, 128, 128);

    const surface = try state.compositor.createSurface();
    const xdg_surface = try state.wm_base.getXdgSurface(surface);
    const xdg_toplevel = try xdg_surface.getToplevel();

    try state.windows.append(state.gpa, .{
        .surface = surface,
        .xdg_surface = xdg_surface,
        .xdg_toplevel = xdg_toplevel,
        .configured = false,
        .running = true,
        .buffer = buffer,
    });

    xdg_surface.setListener(*State, xdg_surface_listener, state);
    xdg_toplevel.setListener(*State, xdg_toplevel_listener, state);
}

pub fn deinit(state: *State) void {
    var i = state.windows.list.items.len;
    while (i > 0) {
        i -= 1;
        state.windows.remove(i);
    }
    state.windows.list.deinit(state.gpa);

    state.wm_base.destroy();
    state.compositor.destroy();
    state.shm.destroy();

    state.registry.destroy();
    state.display.disconnect();

    state.gpa.destroy(state);
}

fn registry_listener(registry: *wl.Registry, event: wl.Registry.Event, globals: *MaybeGlobals) void {
    switch (event) {
        .global => |global| {
            if (std.mem.orderZ(u8, global.interface, wl.Compositor.interface.name) == .eq) {
                globals.compositor = registry.bind(global.name, wl.Compositor, 1) catch return;
            } else if (std.mem.orderZ(u8, global.interface, wl.Shm.interface.name) == .eq) {
                globals.shm = registry.bind(global.name, wl.Shm, 1) catch return;
            } else if (std.mem.orderZ(u8, global.interface, xdg.WmBase.interface.name) == .eq) {
                globals.wm_base = registry.bind(global.name, xdg.WmBase, 1) catch return;
            } else if (std.mem.orderZ(u8, global.interface, wl.Seat.interface.name) == .eq) {
                globals.seat = registry.bind(global.name, wl.Seat, 1) catch return;
            }
        },
        .global_remove => {},
    }
}

fn xdg_surface_listener(xdg_surface: *xdg.Surface, event: xdg.Surface.Event, state: *State) void {
    switch (event) {
        .configure => |configure| {
            xdg_surface.ackConfigure(configure.serial);
            const win = state.window_from_xdg_surface(xdg_surface);
            win.surface.commit();
            win.configured = true;
        },
    }
}

fn xdg_toplevel_listener(tl: *xdg.Toplevel, event: xdg.Toplevel.Event, state: *State) void {
    const window = state.window_from_toplevel(tl);
    switch (event) {
        .configure => |configure| {
            if (configure.width == 0 or configure.height == 0) return;
            const old_size = window.buffer.width * window.buffer.height;
            const new_size = configure.width * configure.height;

            if (new_size == old_size) {
                return;
            } else if (new_size > old_size) {
                const new_buffer = Buffer.init(
                    state.shm,
                    configure.width,
                    configure.height,
                ) catch return;

                window.buffer.deinit();
                window.buffer = new_buffer;
            } else if (new_size < old_size) {
                window.buffer.down_size(configure.width, configure.height) catch return;
            }

            window.surface.attach(window.buffer.buffer, 0, 0);
            window.surface.commit();
        },
        .close => window.running = false,
    }
}

fn keyboard_listener(keyboard: *wl.Keyboard, event: wl.Keyboard.Event, data: *State) void {
    _ = event;
    _ = data;
    _ = keyboard;
}

pub const MaybeGlobals = struct {
    shm: ?*wl.Shm,
    compositor: ?*wl.Compositor,
    wm_base: ?*xdg.WmBase,
    seat: ?*wl.Seat,
};

pub const State = struct {
    io: std.Io,
    gpa: std.mem.Allocator,

    shm: *wl.Shm,
    compositor: *wl.Compositor,
    wm_base: *xdg.WmBase,
    seat: *wl.Seat,
    display: *wl.Display,

    registry: *wl.Registry,
    windows: Windows,

    pub fn last_window(state: *State) Window {
        return state.windows.list.getLast();
    }

    pub fn window_from_toplevel(state: *State, tl: *xdg.Toplevel) *Window {
        const id = tl.getId();
        for (state.windows.list.items) |*win| {
            if (win.xdg_toplevel.getId() == id) return win;
        }

        unreachable;
    }

    pub fn window_from_xdg_surface(state: *State, xdg_surface: *xdg.Surface) *Window {
        const id = xdg_surface.getId();
        for (state.windows.list.items) |*win| {
            if (win.xdg_surface.getId() == id) return win;
        }

        unreachable;
    }
};

pub const Windows = struct {
    pub const init: Windows = .{
        .list = .empty,
    };

    list: std.ArrayList(Window),

    pub fn append(ws: *Windows, gpa: std.mem.Allocator, window: Window) !void {
        try ws.list.append(gpa, window);
    }

    pub fn remove(ws: *Windows, i: usize) void {
        const window = ws.list.orderedRemove(i);
        window.xdg_toplevel.destroy();
        window.xdg_surface.destroy();
        window.surface.destroy();
    }
};

pub const Window = struct {
    surface: *wl.Surface,
    xdg_surface: *xdg.Surface,
    xdg_toplevel: *xdg.Toplevel,

    configured: bool,
    running: bool,

    buffer: Buffer,
};

pub const Buffer = struct {
    data: []align(std.heap.page_size_min) u8,
    pool: *wl.ShmPool,
    buffer: *wl.Buffer,
    memfd: c_int,
    width: i32,
    height: i32,
    format: wl.Shm.Format,

    pub fn init(shm: *wl.Shm, width: i32, height: i32) !Buffer {
        const stride = width * 4;
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

        const format: wl.Shm.Format = .argb8888;
        return .{
            .buffer = try pool.createBuffer(0, width, height, stride, format),
            .pool = pool,
            .memfd = fd,
            .width = width,
            .height = height,
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
        std.debug.assert(width * height < buffer.width * buffer.height);

        const new_buffer = try buffer.pool.createBuffer(
            0,
            width,
            height,
            width * 4,
            buffer.format,
        );

        buffer.buffer.destroy();
        buffer.buffer = new_buffer;
        buffer.width = width;
        buffer.height = height;
    }
};

const std = @import("std");
const wl = @import("wayland").client.wl;
const xdg = @import("wayland").client.xdg;
