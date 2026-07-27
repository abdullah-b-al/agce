const Wayland = @This();

io: std.Io,
gpa: std.mem.Allocator,

shm: *cwl.Shm,
compositor: *cwl.Compositor,
subcompositor: *cwl.Subcompositor,
wm_base: *xdg.WmBase,
seat: *cwl.Seat,
dmabuf: *zwp.LinuxDmabufV1,
viewporter: *wp.Viewporter,
sync_object_manager: *wp.LinuxDrmSyncobjManagerV1,

display: *cwl.Display,
registry: *cwl.Registry,

windows: std.array_hash_map.Auto(WindowID, *Window),
resources: std.array_hash_map.Auto(ClientID, ClientResources),

buffer_listeners: std.array_hash_map.Auto(BufferKey, *ClientResources.BufferListener),
buffer_listeners_pool: std.heap.MemoryPool(ClientResources.BufferListener),

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
        .viewporter = null,
        .sync_object_manager = null,
    };

    registry.setListener(*MaybeGlobals, registry_listener, &globals);
    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

    const shm = globals.shm orelse return error.NoWlShm;
    const compositor = globals.compositor orelse return error.NoWlCompositor;
    const wm_base = globals.wm_base orelse return error.NoXdgWmBase;
    const seat = globals.seat orelse return error.NoWlSeat;
    const subcompositor = globals.subcompositor orelse return error.NoWlSubcompositor;
    const dmabuf = globals.dmabuf orelse return error.NoZwpDmaBuf;
    const viewporter = globals.viewporter orelse return error.NoWpViewporter;
    const sync_object_manager = globals.sync_object_manager orelse return error.NoWpSyncobjManager;

    state.* = .{
        .io = io,
        .gpa = gpa,

        .shm = shm,
        .compositor = compositor,
        .subcompositor = subcompositor,
        .wm_base = wm_base,
        .seat = seat,
        .dmabuf = dmabuf,
        .viewporter = viewporter,
        .sync_object_manager = sync_object_manager,

        .registry = registry,
        .display = display,

        .windows = .empty,
        .resources = .empty,
        .buffer_listeners = .empty,
        .buffer_listeners_pool = .empty,
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

pub fn client_connected(wl: *Wayland, id: ClientID) !void {
    try wl.resources.putNoClobber(wl.gpa, id, .init(id));
}

pub fn client_disconnected(wl: *Wayland, id: ClientID) void {
    const rs = wl.resources_get(id) catch {
        log.warn("Tried to disconnected an nonexistent client {}", .{id});
        return;
    };

    rs.deinit(wl.gpa);

    _ = wl.resources.orderedRemove(id);
}

pub fn resources_get(wl: *Wayland, id: ClientID) !*ClientResources {
    return wl.resources.getPtr(id) orelse return error.ClientDoesNotExist;
}

pub fn buffer_create_gpu_with_fds(wl: *Wayland, dispatch: *Dispatch, args: Dispatch.WindowSystemEvent.BufferCreateGpuWithFds) !void {
    const rs = try wl.resources_get(args.client_id);

    try rs.buffer_create_and_register_gpu_async(
        dispatch,
        wl,
        args.buffer_id,
        args.fds,
        @intCast(args.width),
        @intCast(args.height),
        args.format,
        args.gbm_bo_modifier,
    );
}

pub fn buffer_create_cpu_with_fd(wl: *Wayland, dispatch: *Dispatch, args: Dispatch.WindowSystemEvent.BufferCreateCpuWithFd) !void {
    const rs = try wl.resources_get(args.client_id);

    try rs.buffer_create_and_register_cpu(
        wl,
        dispatch,
        args.buffer_id,
        args.fd,
        @intCast(args.width),
        @intCast(args.height),
        args.format,
    );
}

pub fn buffer_present(wl: *Wayland, args: Dispatch.WindowSystemEvent.BufferPresent) !void {
    const viewport_key: ViewportKey = .{ .client_id = args.client_id, .viewport_id = args.viewport_id };

    const window = wl.window_from_viewport_key(viewport_key) orelse {
        log.err("Viewport does not exist {}", .{viewport_key});
        return;
    };

    const rs = try wl.resources_get(args.client_id);

    const subsurface = rs.subsurfaces.getPtr(args.viewport_id) orelse {
        log.err("Viewport does not exist {}", .{viewport_key});
        return;
    };

    const buffer = rs.buffer_get(args.buffer_id) orelse {
        if (rs.wl_buffers_pending.contains(args.buffer_id)) {
            log.warn("Buffer is pending {} for {}", .{ args.buffer_id, args.client_id });
        } else {
            log.err("Buffer does not exist {} for {}", .{ args.buffer_id, args.client_id });
        }
        return;
    };

    try rs.viewport_mark_commit(wl.gpa, args.buffer_id, args.viewport_id);
    subsurface.surface.damage(0, 0, buffer.width(), buffer.height());
    subsurface.surface.attach(buffer.wl_buffer(), 0, 0);
    subsurface.surface.commit();
    log.debug("buffer_present: commited subsurface for {} {} {}", .{ args.client_id, args.viewport_id, args.buffer_id });

    window.commit();
    _ = wl.display.flush();
}

pub fn buffer_present_with_sync(wl: *Wayland, args: Dispatch.WindowSystemEvent.BufferPresentWithSync) !void {
    const viewport_key: ViewportKey = .{ .client_id = args.client_id, .viewport_id = args.viewport_id };

    const window = wl.window_from_viewport_key(viewport_key) orelse {
        log.err("Viewport does not exist {}", .{viewport_key});
        return;
    };

    const rs = try wl.resources_get(args.client_id);

    const subsurface = rs.subsurfaces.getPtr(args.viewport_id) orelse {
        log.err("Viewport does not exist {}", .{viewport_key});
        return;
    };

    const buffer = rs.buffer_get(args.buffer_id) orelse {
        if (rs.wl_buffers_pending.contains(args.buffer_id)) {
            log.warn("Buffer is pending {} for {}", .{ args.buffer_id, args.client_id });
        } else {
            log.err("Buffer does not exist {} for {}", .{ args.buffer_id, args.client_id });
        }
        return;
    };

    try rs.viewport_mark_commit(wl.gpa, args.buffer_id, args.viewport_id);

    errdefer comptime unreachable;

    log.debug("Set acquire point {} and release point {} for ClientID({}) ViewportID({}) BufferID({})", .{
        args.acquire_point,
        args.release_point,
        @intFromEnum(args.client_id),
        @intFromEnum(args.viewport_id),
        @intFromEnum(args.buffer_id),
    });

    subsurface.surface.damage(0, 0, buffer.width(), buffer.height());
    subsurface.surface.attach(buffer.wl_buffer(), 0, 0);

    if (subsurface.sync_surface) |sync_surface| {
        switch (buffer) {
            .gpu => |gpu| {
                gpu.timeline_acquire.?.set(sync_surface, args.acquire_point);
                gpu.timeline_release.?.set(sync_surface, args.release_point);
            },
            .cpu => {},
        }
    }

    subsurface.surface.commit();
    // log.debug("buffer_present_with_sync: commited subsurface for {} {}", .{ buffer_key, viewport_key });

    window.commit();
    _ = wl.display.flush();
}

pub fn buffer_destroy(wl: *Wayland, dispatch: *Dispatch, args: Dispatch.WindowSystemEvent.BufferDestroy) !void {
    const rs = try wl.resources_get(args.client_id);
    rs.buffer_destroy(args.buffer_id);

    try dispatch.server_put(
        .{
            .buffer_destroyed = .{
                .client_id = args.client_id,
                .buffer_id = args.buffer_id,
            },
        },
    );
}

pub fn viewport_resize(wl: *Wayland, args: Dispatch.WindowSystemEvent.ViewportResize) !void {
    const rs = try wl.resources_get(args.client_id);
    const subsurface = rs.subsurfaces.get(args.viewport_id) orelse return error.ViewportDoesNotExist;

    // FIXME: Setting any value provided by the client may cause the window to suddenly close
    // if the dimensions are larger than the buffer's.
    subsurface.viewport.setSource(
        .fromInt(0),
        .fromInt(0),
        .fromInt(@intCast(args.width)),
        .fromInt(@intCast(args.height)),
    );
}

pub fn window_create(wl: *Wayland, ws: *WindowSystem, args: Dispatch.WindowSystemEvent.WindowCreate) !void {
    try wl.windows.ensureUnusedCapacity(wl.gpa, 1);

    const rs = try wl.resources_get(args.client_id);
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

    try rs.subsurface_create(
        wl,
        window.surface,
        args.viewport_id,
        @intCast(args.width),
        @intCast(args.height),
        args.create_sync_timeline,
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
        .client_id = win.viewport_key.client_id,
        .resize = .{
            .viewport_id = win.viewport_key.viewport_id,
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
            } else if (std.mem.orderZ(u8, global.interface, wp.Viewporter.interface.name) == .eq) {
                globals.viewporter = registry.bind(global.name, wp.Viewporter, 1) catch return;
            } else if (std.mem.orderZ(u8, global.interface, wp.LinuxDrmSyncobjManagerV1.interface.name) == .eq) {
                globals.sync_object_manager = registry.bind(global.name, wp.LinuxDrmSyncobjManagerV1, 1) catch return;
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

pub fn window_from_viewport_key(wl: *const Wayland, key: ViewportKey) ?*Window {
    for (wl.windows.values()) |win| {
        if (std.meta.eql(win.viewport_key, key)) {
            return win;
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
    viewporter: ?*wp.Viewporter,
    sync_object_manager: ?*wp.LinuxDrmSyncobjManagerV1,
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
const wp = @import("wayland").client.wp;
const ClientID = @import("../server/Clients.zig").ClientID;
const WindowSystem = @import("../WindowSystem.zig");
const WindowID = WindowSystem.WindowID;
const log = std.log.scoped(.Wayland);
const utils = @import("../server/utils.zig");
const ClientResources = @import("ClientResources.zig");
const Window = @import("Window.zig");
const Subsurface = @import("Subsurface.zig");
const c_linux = @import("c_linux");
const Dispatch = @import("../Dispatch.zig");
const BufferKey = WindowSystem.BufferKey;
const ViewportKey = WindowSystem.ViewportKey;
