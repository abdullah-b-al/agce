const Mux = @This();

gpa: std.mem.Allocator,
compositor: *CompositorHandle,

/// Used in windows to prevent accesing freed data in callbacks
destroy_started: bool,

next_window_id: WindowID,
windows: std.array_hash_map.Auto(WindowID, *Window),

class_of_window: [:0]const u8,

wayland_objects: WaylandObjects,
win32: Win32,

pub fn create(
    io: std.Io,
    gpa: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
) !*Mux {
    const mux = try gpa.create(Mux);
    errdefer gpa.destroy(mux);

    const class_of_window = try gpa.dupeZ(u8, "agce-mux");
    errdefer gpa.free(class_of_window);

    const create_args: Compositor.CreateArgs = .{
        .io = io,
        .gpa = gpa,
        .environ_map = environ_map,
        .class = class_of_window,
        .muxi = .{ .ptr = mux, .vtable = &vtable },
        .socket_owner = .mux,
    };
    const com: *CompositorHandle, const wayland_globals: WaylandObjects, const win32: Win32 =
        blk: switch (os) {
            .linux => {
                const display = try cwl.Display.connect(null);
                const queue = try display.createQueue();

                const maybe_globals = try Compositor.Wayland.get_globals(display, queue);

                const globals: WaylandObjects = .{
                    .display = display,
                    .queue = queue,
                    .shm = maybe_globals.shm orelse return error.NoWlShm,
                    .compositor = maybe_globals.compositor orelse return error.NoWlCompositor,
                    .wm_base = maybe_globals.wm_base orelse return error.NoXdgWmBase,
                    .viewporter = maybe_globals.viewporter orelse return error.NoWpViewporter,
                    .seat = maybe_globals.seat orelse return error.NoWlSeat,
                };

                const keyboard = try globals.seat.getKeyboard();
                keyboard.setListener(*Mux, WaylandWindow.listener_keyboard, mux);

                const com: *CompositorHandle = try .create_wayland(display, create_args);

                break :blk .{ com, globals, {} };
            },
            .windows => {
                const hinstance = @import("win32").system.library_loader.GetModuleHandleW(null).?;
                const window_class: win32_win.WNDCLASSA = .{
                    .style = .{},
                    .cbClsExtra = 0,
                    .cbWndExtra = 0,
                    .lpszMenuName = null,
                    .hIcon = null,
                    .hCursor = null,
                    .hbrBackground = null,
                    .lpfnWndProc = Win32Window.window_proc,
                    .hInstance = hinstance,
                    .lpszClassName = class_of_window,
                };

                if (win32_win.RegisterClassA(&window_class) == 0) {
                    const err = win32_foundation.GetLastError();
                    log.err("{}", .{err});
                    return error.FailedToRegisterClass;
                }

                const win32: Win32 = .{ .hinstance = hinstance, .window_class = window_class };

                const com: *CompositorHandle = try .create_win32(hinstance, create_args);

                break :blk .{ com, {}, win32 };
            },
            else => @compileError("Unsupported OS"),
        };

    mux.* = .{
        .gpa = gpa,
        .windows = .empty,
        .destroy_started = false,
        .class_of_window = class_of_window,
        .compositor = com,
        .next_window_id = .first,
        .wayland_objects = wayland_globals,
        .win32 = win32,
    };

    return mux;
}

pub fn destroy(mux: *Mux) void {
    mux.destroy_started = true;
    const native_tag = mux.compositor.native_tag();
    mux.compositor.destroy();

    switch (native_tag) {
        .wayland => |tag| {
            tag.guard();
            mux.wayland_objects.deinit();
        },
        else => {},
    }

    for (mux.windows.values()) |win| {
        win.destroy(mux.gpa);
    }

    mux.windows.deinit(mux.gpa);

    mux.gpa.free(mux.class_of_window);
    mux.gpa.destroy(mux);
}

pub fn dispatch(mux: *Mux) void {
    switch (mux.compositor.native_tag()) {
        .wayland => |tag| {
            tag.guard();

            const display = mux.wayland_objects.display;
            const queue = mux.wayland_objects.queue;

            while (!display.prepareReadQueue(queue)) {
                if (display.dispatchQueuePending(queue) != .SUCCESS) {
                    std.process.fatal("Dispatch failed {}", .{display.getError()});
                }
            }

            // TODO: Call cancelRead when needed
            if (display.readEvents() != .SUCCESS) {
                std.process.fatal("readEvents failed {}", .{display.getError()});
            }

            if (display.dispatchQueuePending(queue) != .SUCCESS) {
                std.process.fatal("Dispatch failed {}", .{display.getError()});
            }

            for (mux.windows.values()) |win| {
                if (!win.linux.wayland.configured) {
                    win.linux.wayland.surface.commit();
                } else if (win.linux.wayland.configured and !win.linux.wayland.commited_once) {
                    win.linux.wayland.commit();
                }
            }
        },
        .win32 => |tag| {
            tag.guard();
            var msg: win32_win.MSG = undefined;

            for (mux.windows.values()) |win| {
                const handle = win.handle(mux).cast(tag);
                while (win32_win.PeekMessageA(&msg, handle, 0, 0, win32_win.PM_REMOVE) > 0) {
                    _ = win32_win.TranslateMessage(&msg);
                    _ = win32_win.DispatchMessageA(&msg);
                }
            }
        },
    }
}

pub fn flush(mux: *Mux) void {
    switch (mux.compositor.native_tag()) {
        .wayland => |tag| {
            tag.guard();
            _ = mux.wayland_objects.display.flush();
        },
        .win32 => {},
    }
}

fn window_handle_for_viewport(ptr: *anyopaque, key: ptypes.ViewportKey, size: ptypes.Size) ?*Compositor.WindowHandle {
    std.debug.assert(size.width > 0);
    std.debug.assert(size.height > 0);

    const mux: *Mux = @ptrCast(@alignCast(ptr));

    mux.windows.ensureUnusedCapacity(mux.gpa, 1) catch return null;

    const id = mux.next_window_id.increment();
    const win = Window.create(mux, id, key, size) catch |err| {
        log.err("window_handle_for_viewport() {}", .{err});
        return null;
    };

    mux.windows.putAssumeCapacityNoClobber(id, win);

    switch (win.native_tag()) {
        .wayland => |tag| {
            tag.guard();
            win.linux.wayland.surface.commit();
        },
        .win32 => {},
    }

    return win.handle(mux);
}

fn window_id_from_handle(ptr: *anyopaque, handle: *Compositor.WindowHandle) ?WindowID {
    const mux: *Mux = @ptrCast(@alignCast(ptr));
    for (mux.windows.values()) |win| {
        if (win.handle(mux) == handle) {
            return win.id;
        }
    }

    return null;
}

fn window_handle_from_id(ptr: *anyopaque, id: WindowID) ?*Compositor.WindowHandle {
    const mux: *Mux = @ptrCast(@alignCast(ptr));
    const win = mux.windows.get(id) orelse return null;
    return win.handle(mux);
}

fn window_size(ptr: *anyopaque, id: WindowID) ?ptypes.Size {
    const mux: *Mux = @ptrCast(@alignCast(ptr));
    const win = mux.windows.get(id) orelse return null;
    return win.get_size();
}

pub fn windows_destroy_if_closed(mux: *Mux) void {
    var i: usize = mux.windows.count();
    while (i > 0) {
        i -= 1;
        const win = mux.windows.values()[i];

        const should_close = blk: {
            for (mux.compositor.resources()) |rs| {
                for (rs.viewports.values()) |vp| {
                    if (vp.window_id == win.id) {
                        break :blk false;
                    }
                }
            }

            break :blk true;
        };

        if (should_close) {
            const id = win.id;
            win.destroy(mux.gpa);
            _ = mux.windows.orderedRemove(id);
        }
    }
}

pub const Window = struct {
    id: WindowID,
    viewport_key: ptypes.ViewportKey,

    linux: if (os == .linux) Linux else void,
    win32: if (os == .windows) Win32Window else void,

    pub fn create(mux: *Mux, id: WindowID, key: ptypes.ViewportKey, size: ptypes.Size) !*Window {
        const win = try mux.gpa.create(Window);
        errdefer mux.gpa.destroy(win);

        win.* = .{
            .id = id,
            .viewport_key = key,
            .win32 = undefined,
            .linux = undefined,
        };

        switch (mux.compositor.native_tag()) {
            .wayland => |tag| {
                tag.guard();
                win.linux = .{ .wayland = try .init(mux, size) };
            },
            .win32 => |tag| {
                tag.guard();
                win.win32 = try .init(mux, size);
            },
        }

        log.debug("Window created {f}", .{id});
        return win;
    }

    pub fn destroy(win: *Window, gpa: std.mem.Allocator) void {
        if (os == .linux) win.linux.wayland.deinit();
        if (os == .windows) win.win32.deinit();

        gpa.destroy(win);
    }

    pub fn handle(win: *Window, mux: *Mux) *Compositor.WindowHandle {
        switch (mux.compositor.native_tag()) {
            .wayland => |tag| {
                tag.guard();
                return @ptrCast(win.linux.wayland.surface);
            },
            .win32 => |tag| {
                tag.guard();
                return @ptrCast(win.win32.handle);
            },
        }
    }

    pub fn get_size(win: *Window) ptypes.Size {
        return switch (win.native_tag()) {
            .wayland => |tag| {
                tag.guard();
                return win.linux.wayland.buffer.size;
            },
            .win32 => |tag| {
                tag.guard();
                var rect: win32_foundation.RECT = undefined;
                if (win32_win.GetClientRect(win.win32.handle, &rect) != 0) {
                    return .{
                        .width = rect.right - rect.left,
                        .height = rect.bottom - rect.top,
                    };
                } else {
                    return .{ .width = 0, .height = 0 };
                }
            },
        };
    }

    pub fn native_tag(win: *const Window) Compositor.NativeTag {
        return switch (os) {
            .linux => switch (win.linux) {
                .wayland => .wayland,
            },
            .windows => .win32,
            else => comptime unreachable,
        };
    }
};

pub const WaylandMaybeGlobals = struct {
    shm: ?*cwl.Shm,
    compositor: ?*cwl.Compositor,
    wm_base: ?*xdg.WmBase,
    viewporter: ?*wp.Viewporter,
};

pub const WaylandObjects = if (os != .linux) void else struct {
    display: *cwl.Display,
    queue: *cwl.EventQueue,
    shm: *cwl.Shm,
    compositor: *cwl.Compositor,
    wm_base: *xdg.WmBase,
    viewporter: *wp.Viewporter,
    seat: *cwl.Seat,

    pub fn deinit(wo: *WaylandObjects) void {
        wo.shm.destroy();
        wo.compositor.destroy();
        wo.wm_base.destroy();
        wo.viewporter.destroy();
        wo.seat.destroy();

        wo.queue.destroy();
        wo.display.disconnect();
    }
};

pub const Win32 = if (os != .windows) void else struct {
    hinstance: win32_foundation.HINSTANCE,
    window_class: win32_win.WNDCLASSA,
};

const Linux = union(enum) {
    wayland: WaylandWindow,
};

const vtable: Compositor.MuxInterface.VTable = .{
    .window_handle_for_viewport = window_handle_for_viewport,
    .window_id_from_handle = window_id_from_handle,
    .window_handle_from_id = window_handle_from_id,
    .window_size = window_size,
};

const std = @import("std");
const Compositor = @import("compositor").Compositor;
const CompositorHandle = @import("compositor").CompositorHandle;
const WindowID = Compositor.WindowID;
const WaylandWindow = @import("WaylandWindow.zig");
const Win32Window = @import("Win32Window.zig");
const os = @import("builtin").os.tag;
const win32_foundation = @import("win32").foundation;
const cwl = @import("wayland").client.wl;
const wp = @import("wayland").client.wp;
const xdg = @import("wayland").client.xdg;
const win32_win = @import("win32").ui.windows_and_messaging;
const log = std.log.scoped(.Mux);
const ptypes = @import("protocol").types;
