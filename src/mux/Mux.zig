const Mux = @This();

window_system: *WindowSystem,

gpa: std.mem.Allocator,

next_window_id: WindowID,
windows: std.array_hash_map.Auto(WindowID, *Window),

wayland_objects: WaylandObjects,

pub fn create(
    io: std.Io,
    gpa: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
) !*Mux {
    const mux = try gpa.create(Mux);
    errdefer gpa.destroy(mux);

    const muxi: WindowSystem.MuxInterface = .{
        .ptr = mux,
        .vtable = &vtable,
    };

    const class = "agce-mux";

    const ws: *WindowSystem, const wayland_globals: WaylandObjects = blk: switch (os) {
        .linux => {
            const display = try cwl.Display.connect(null);
            const queue = try display.createQueue();

            const maybe_globals = try WindowSystem.Wayland.get_globals(display, queue);

            const globals: WaylandObjects = .{
                .display = display,
                .queue = queue,
                .shm = maybe_globals.shm orelse return error.NoWlShm,
                .compositor = maybe_globals.compositor orelse return error.NoWlCompositor,
                .wm_base = maybe_globals.wm_base orelse return error.NoXdgWmBase,
                .viewporter = maybe_globals.viewporter orelse return error.NoWpViewporter,
            };

            const ws: *WindowSystem = try .create_wayland(
                io,
                gpa,
                environ_map,
                display,
                class,
                muxi,
            );

            break :blk .{ ws, globals };
        },
        .windows => {
            const hinstance = @import("win32").system.library_loader.GetModuleHandleW(null).?;
            const ws: *WindowSystem = try .create_win32(
                io,
                gpa,
                environ_map,
                hinstance,
                class,
                muxi,
            );

            break :blk .{ ws, {} };
        },
        else => @compileError("Unsupported OS"),
    };

    mux.* = .{
        .gpa = gpa,
        .windows = .empty,
        .window_system = ws,
        .next_window_id = .first,
        .wayland_objects = wayland_globals,
    };

    return mux;
}

pub fn destroy(mux: *Mux) void {
    const native_tag = mux.window_system.native_tag();
    mux.window_system.destroy();

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

    mux.gpa.destroy(mux);
}

pub fn dispatch(mux: *Mux) void {
    switch (mux.window_system.native_tag()) {
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

            while (win32_win.PeekMessageA(&msg, null, 0, 0, win32_win.PM_REMOVE) > 0) {
                _ = win32_win.TranslateMessage(&msg);
                _ = win32_win.DispatchMessageA(&msg);
            }
        },
    }
}

pub fn flush(mux: *Mux) void {
    switch (mux.window_system.native_tag()) {
        .wayland => |tag| {
            tag.guard();
            _ = mux.wayland_objects.display.flush();
        },
        .win32 => {},
    }
}

fn window_handle_for_viewport(ptr: *anyopaque) ?*WindowSystem.WindowHandle {
    const mux: *Mux = @ptrCast(@alignCast(ptr));

    mux.windows.ensureUnusedCapacity(mux.gpa, 1) catch return null;

    const id = mux.next_window_id.increment();
    const win = Window.create(mux, id, .{ .width = 512, .height = 512 }) catch |err| {
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

    // TODO: Do not register windows here
    mux.window_system.window_register(.{
        .handle = win.handle,
        .id = win.id,
        .size = win.get_size(),
    }) catch return null;

    return win.handle;
}

const vtable: WindowSystem.MuxInterface.VTable = .{
    .window_handle_for_viewport = window_handle_for_viewport,
};

pub const Window = struct {
    id: WindowID,
    handle: *WindowSystem.WindowHandle,

    linux: if (os == .linux) Linux else void,
    win32: if (os == .windows) Win32Window else void,

    pub fn create(mux: *Mux, id: WindowID, size: ptypes.Size) !*Window {
        const win = try mux.gpa.create(Window);
        errdefer mux.gpa.destroy(win);

        win.* = .{
            .id = id,
            .handle = undefined,
            .win32 = undefined,
            .linux = undefined,
        };

        win.handle = blk: switch (mux.window_system.native_tag()) {
            .wayland => |tag| {
                tag.guard();
                win.linux = .{ .wayland = try .init(mux, size) };
                break :blk @ptrCast(win.linux.wayland.surface);
            },
            .win32 => |tag| {
                tag.guard();
                @compileError("TODO");
                // const win32 = tag.window_system(ws);
                // win.win32 = try .init(win32, ws, win, requested_size);
            },
        };

        return win;
    }

    pub fn destroy(win: *Window, gpa: std.mem.Allocator) void {
        if (os == .linux) win.linux.wayland.deinit();
        if (os == .windows) win.win32.deinit();

        gpa.destroy(win);
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

    pub fn native_tag(win: *const Window) WindowSystem.NativeTag {
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

    pub fn deinit(wo: *WaylandObjects) void {
        wo.shm.destroy();
        wo.compositor.destroy();
        wo.wm_base.destroy();
        wo.viewporter.destroy();
        wo.queue.destroy();
        wo.display.disconnect();
    }
};

fn wayland_registry_listener(registry: *cwl.Registry, event: cwl.Registry.Event, globals: *WaylandMaybeGlobals) void {
    switch (event) {
        .global => |global| {
            // log.info("Compositor has {s}", .{global.interface});
            const table = .{
                // zig fmt: off
                .{ .field = "compositor",          .T = cwl.Compositor,              .v = 1 },
                .{ .field = "shm",                 .T = cwl.Shm,                     .v = 1 },
                .{ .field = "viewporter",          .T = wp.Viewporter,               .v = 1 },
                .{ .field = "wm_base",             .T = xdg.WmBase,                  .v = 1 },
                // zig fmt: on
            };

            inline for (table) |entry| {
                if (std.mem.orderZ(u8, global.interface, entry.T.interface.name) == .eq) {
                    @field(globals, entry.field) = registry.bind(
                        global.name,
                        entry.T,
                        entry.v,
                    ) catch return;
                }
            }
        },
        .global_remove => {},
    }
}
const Linux = union(enum) {
    wayland: WaylandWindow,
};

const Win32Window = struct {
    handle: win32_foundation.HWND,

    pub fn deinit(win: *Win32Window) void {
        _ = win32_win.DestroyWindow(win.handle);
    }
};

const std = @import("std");
const WindowSystem = @import("window_system").WindowSystem;
const WindowID = WindowSystem.WindowID;
const WaylandWindow = @import("WaylandWindow.zig");
const os = @import("builtin").os.tag;
const win32_foundation = @import("win32").foundation;
const cwl = @import("wayland").client.wl;
const wp = @import("wayland").client.wp;
const xdg = @import("wayland").client.xdg;
const win32_win = @import("win32").ui.windows_and_messaging;
const log = std.log.scoped(.Mux);
const ptypes = @import("protocol").types;
