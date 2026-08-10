const Wayland = @This();

io: std.Io,
gpa: std.mem.Allocator,
dispatch: *Dispatch,

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

wl_buffers: std.array_hash_map.Auto(WlBufferID, BufferKey),
frame_callbacks: std.array_hash_map.Auto(CallbackID, ViewportKey),

viewport_of_mouse: ?ViewportKey,

pub fn create(dispatch: *Dispatch) !*Wayland {
    const state = try dispatch.gpa.create(Wayland);
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
        .io = dispatch.io,
        .gpa = dispatch.gpa,
        .dispatch = dispatch,

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
        .wl_buffers = .empty,
        .frame_callbacks = .empty,

        .viewport_of_mouse = null,
    };

    return state;
}

pub fn destroy(wl: *Wayland) void {
    for (wl.windows.values()) |window| window.destroy(wl.gpa);
    wl.windows.deinit(wl.gpa);

    for (wl.resources.values()) |*rs| rs.deinit(wl);
    wl.resources.deinit(wl.gpa);

    wl.wl_buffers.deinit(wl.gpa);
    wl.frame_callbacks.deinit(wl.gpa);

    wl.shm.destroy();
    wl.compositor.destroy();
    wl.subcompositor.destroy();
    wl.wm_base.destroy();
    wl.seat.destroy();
    wl.dmabuf.destroy();
    wl.viewporter.destroy();
    wl.sync_object_manager.destroy();

    wl.registry.destroy();
    wl.display.disconnect();

    wl.gpa.destroy(wl);
}

pub fn client_connected(wl: *Wayland, id: ClientID) !void {
    try wl.resources.putNoClobber(wl.gpa, id, .init(id));
}

pub fn client_disconnected(wl: *Wayland, id: ClientID) void {
    const rs = wl.resources_get(id) catch {
        log.warn("Tried to disconnected an nonexistent client {}", .{id});
        return;
    };

    for (wl.windows.values()) |win| {
        if (win.viewport_key.client_id == id) {
            win.running = false;
        }
    }

    rs.deinit(wl);
    _ = wl.resources.orderedRemove(id);
}

pub fn resources_get(wl: *Wayland, id: ClientID) !*ClientResources {
    return wl.resources.getPtr(id) orelse return error.ClientDoesNotExist;
}

pub fn buffer_set_listener_prepare(wl: *Wayland) !void {
    var total: usize = 0;

    for (wl.resources.values()) |rs| {
        total +=
            rs.wl_buffers_pending.count() +
            rs.buffers.count() +
            1;
    }

    try wl.wl_buffers.ensureTotalCapacity(wl.gpa, total);
}

pub fn buffer_set_listener(wl: *Wayland, rs: *ClientResources, wl_buffer: *cwl.Buffer, buffer_id: BufferID) void {
    wl_buffer.setListener(*Wayland, ClientResources.BufferListener.callback, wl);
    wl.wl_buffers.putAssumeCapacityNoClobber(
        .from_wl_buffer(wl_buffer),
        .{ .client_id = rs.client_id, .buffer_id = buffer_id },
    );

    log.debug("Set a listener for wl_buffer {} {}", .{ wl_buffer.getId(), buffer_id });
}

pub fn buffer_create_gpu_with_fds(wl: *Wayland, dispatch: *Dispatch, args: Event.BufferCreateGpuWithFds) !void {
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

    _ = wl.display.flush();
}

pub fn buffer_create_cpu_with_fd(wl: *Wayland, args: Event.BufferCreateCpuWithFd) !void {
    const rs = try wl.resources_get(args.client_id);

    try rs.buffer_create_and_register_cpu(
        wl,
        args.buffer_id,
        args.fd,
        @intCast(args.width),
        @intCast(args.height),
        args.format,
    );

    // TODO: Send failure in that case
    try wl.dispatch.server_put(
        @src(),
        .{
            .buffer_created = .{
                .client_id = args.client_id,
                .payload = .{
                    .buffer_id = args.buffer_id,
                    .status = .success,
                },
            },
        },
    );
}

pub fn buffer_present(wl: *Wayland, args: Event.BufferPresent) !void {
    const viewport_key: ViewportKey = .{ .client_id = args.client_id, .viewport_id = args.viewport_id };

    const window = wl.window_from_viewport_key(viewport_key) orelse {
        log.err("Viewport does not exist {}", .{viewport_key});
        return;
    };

    const rs = try wl.resources_get(args.client_id);

    const vp = rs.viewports.getPtr(args.viewport_id) orelse {
        log.err("Viewport does not exist {}", .{viewport_key});
        return;
    };

    const buffer = rs.buffers.getPtr(args.buffer_id) orelse {
        if (rs.wl_buffers_pending.contains(args.buffer_id)) {
            log.warn("Buffer is pending {} for {}", .{ args.buffer_id, args.client_id });
        } else {
            log.err("Buffer does not exist {} for {}", .{ args.buffer_id, args.client_id });
        }
        return;
    };

    try rs.viewport_mark_commit(wl.gpa, args.buffer_id, args.viewport_id);
    vp.surface.damage(0, 0, buffer.width(), buffer.height());
    vp.surface.attach(buffer.wl_buffer(), 0, 0);
    vp.surface.commit();
    log.debug("buffer_present: commited viewport for {} {} {}", .{ args.client_id, args.viewport_id, args.buffer_id });

    window.commit();
    _ = wl.display.flush();
}

pub fn buffer_present_with_sync(wl: *Wayland, args: Event.BufferPresentWithSync) !void {
    const viewport_key: ViewportKey = .{ .client_id = args.client_id, .viewport_id = args.viewport_id };

    const window = wl.window_from_viewport_key(viewport_key) orelse {
        log.err("Viewport does not exist {}", .{viewport_key});
        return;
    };

    const rs = try wl.resources_get(args.client_id);

    const vp = rs.viewports.getPtr(args.viewport_id) orelse {
        log.err("Viewport does not exist {}", .{viewport_key});
        return;
    };

    const buffer = rs.buffers.getPtr(args.buffer_id) orelse {
        if (rs.wl_buffers_pending.contains(args.buffer_id)) {
            log.warn("Buffer is pending {} for {}", .{ args.buffer_id, args.client_id });
        } else {
            log.err("Buffer does not exist {} for {}", .{ args.buffer_id, args.client_id });
        }
        return;
    };

    try rs.viewport_mark_commit(wl.gpa, args.buffer_id, args.viewport_id);

    if (vp.vsync) {
        try wl.frame_listener_set(vp.surface, viewport_key);
    }
    errdefer comptime unreachable;

    log.debug("Set acquire point {} and release point {} for ClientID({}) ViewportID({}) BufferID({})", .{
        args.acquire_point,
        args.release_point,
        @intFromEnum(args.client_id),
        @intFromEnum(args.viewport_id),
        @intFromEnum(args.buffer_id),
    });

    vp.surface.damage(0, 0, buffer.width(), buffer.height());
    vp.surface.attach(buffer.wl_buffer(), 0, 0);

    if (vp.sync_surface) |sync_surface| {
        switch (buffer.*) {
            .gpu => |gpu| {
                gpu.timeline_acquire.?.set(sync_surface, args.acquire_point);
                gpu.timeline_release.?.set(sync_surface, args.release_point);
            },
            .cpu => {},
        }
    }

    vp.surface.commit();
    // log.debug("buffer_present_with_sync: commited viewport for {} {}", .{ buffer_key, viewport_key });

    window.commit();
    _ = wl.display.flush();
}

pub fn buffer_destroy(wl: *Wayland, args: Event.BufferDestroy) !void {
    const rs = try wl.resources_get(args.client_id);
    rs.buffer_destroy(wl, args.buffer_id);

    try wl.dispatch.server_put(
        @src(),
        .{
            .buffer_destroyed = .{
                .client_id = args.client_id,
                .payload = .{
                    .buffer_id = args.buffer_id,
                },
            },
        },
    );
}

pub fn viewport_resize(wl: *Wayland, args: Event.ViewportResize) !void {
    const rs = try wl.resources_get(args.client_id);
    const vp = rs.viewports.get(args.viewport_id) orelse return error.ViewportDoesNotExist;

    // FIXME: Setting any value provided by the client may cause the window to suddenly close
    // if the dimensions are larger than the buffer's.
    vp.viewport.setSource(
        .fromInt(0),
        .fromInt(0),
        .fromInt(@intCast(args.width)),
        .fromInt(@intCast(args.height)),
    );
}

pub fn window_create(wl: *Wayland, ws: *WindowSystem, args: Event.WindowCreate) !void {
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

    try rs.viewport_create(
        wl,
        window.surface,
        args.viewport_id,
        @intCast(args.width),
        @intCast(args.height),
        args.create_sync_timeline,
        args.vsync,
    );

    wl.windows.putAssumeCapacityNoClobber(id, window);
    window.ensure_configured(wl);
}

pub fn window_resize_by_display_server(wl: *Wayland, args: Event.WindowResize) !void {
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

    try wl.dispatch.server_put(@src(), .{
        .viewport_resize = .{
            .client_id = win.viewport_key.client_id,
            .payload = .{
                .viewport_id = win.viewport_key.viewport_id,
                .width = @intCast(args.width),
                .height = @intCast(args.height),
            },
        },
    });
}

pub fn mouse_enter(wl: *Wayland, args: Event.MouseEnter) !void {
    wl.viewport_of_mouse = .{
        .client_id = args.client_id,
        .viewport_id = args.viewport_id,
    };

    try wl.dispatch.server_put(
        @src(),
        .{
            .mouse_enter = .{
                .client_id = args.client_id,
                .payload = .{
                    .viewport_id = args.viewport_id,
                },
            },
        },
    );
}
pub fn mouse_leave(wl: *Wayland, args: Event.MouseLeave) !void {
    wl.viewport_of_mouse = null;

    try wl.dispatch.server_put(
        @src(),
        .{
            .mouse_leave = .{
                .client_id = args.client_id,
                .payload = .{
                    .viewport_id = args.viewport_id,
                },
            },
        },
    );
}
pub fn mouse_motion(wl: *Wayland, args: Event.MouseMotion) !void {
    const key = wl.viewport_of_mouse orelse {
        @panic("Expected a viewport with the mouse event");
    };

    try wl.dispatch.server_put(@src(), .{
        .mouse_motion = .{
            .client_id = key.client_id,
            .payload = .{
                .viewport_id = key.viewport_id,
                .x = args.x,
                .y = args.y,
            },
        },
    });
}
pub fn mouse_button(wl: *Wayland, args: Event.MouseButton) !void {
    const key = wl.viewport_of_mouse orelse {
        @panic("Expected a viewport with the mouse event");
    };
    try wl.dispatch.server_put(@src(), .{
        .mouse_button = .{
            .client_id = key.client_id,
            .payload = .{
                .viewport_id = key.viewport_id,
                .button = args.button,
                .state = args.state,
            },
        },
    });
}
pub fn mouse_scroll(wl: *Wayland, args: Event.MouseScroll) !void {
    const key = wl.viewport_of_mouse orelse {
        @panic("Expected a viewport with the mouse event");
    };
    try wl.dispatch.server_put(@src(), .{
        .mouse_scroll = .{
            .client_id = key.client_id,
            .payload = .{
                .viewport_id = key.viewport_id,
                .axis = args.axis,
                .value = args.value,
            },
        },
    });
}

pub fn set_listeners(wl: *Wayland, ws: *WindowSystem) !void {
    const keyboard = try wl.seat.getKeyboard();
    keyboard.setListener(*WindowSystem, listener_keyboard, ws);

    const pointer = try wl.seat.getPointer();
    pointer.setListener(*WindowSystem, listener_pointer, ws);
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

fn listener_keyboard(keyboard: *cwl.Keyboard, event: cwl.Keyboard.Event, ws: *WindowSystem) void {
    _ = event;
    _ = ws;
    _ = keyboard;
}

fn listener_pointer(pointer: *cwl.Pointer, event: cwl.Pointer.Event, ws: *WindowSystem) void {
    _ = pointer;

    const ws_event: Event = blk: switch (event) {
        inline .leave, .enter => |e, tag| {
            const surface = e.surface orelse {
                log.warn("Dropping pointer event without a surface {t}", .{tag});
                return;
            };

            const key = ws.native.wayland.viewport_key_from_surface(surface) orelse {
                log.warn("Dropping pointer event without a viewport {t}", .{tag});
                return;
            };

            break :blk @unionInit(Event, "mouse_" ++ @tagName(tag), .{
                .client_id = key.client_id,
                .viewport_id = key.viewport_id,
            });
        },
        .motion => |e| .{
            .mouse_motion = .{
                .x = @floatCast(e.surface_x.toDouble()),
                .y = @floatCast(e.surface_y.toDouble()),
            },
        },
        .button => |e| {
            const button: ptypes.MouseButton =
                if (e.button == c_linux.BTN_LEFT)
                    .left
                else if (e.button == c_linux.BTN_RIGHT)
                    .right
                else {
                    log.warn("Unknown button {}... Dropping event", .{e.button});
                    return;
                };

            const state: ptypes.MouseButtonState = switch (e.state) {
                .released => .released,
                .pressed => .pressed,
                else => {
                    log.warn("Unknown button state {}... Dropping event", .{e.state});
                    return;
                },
            };
            break :blk .{
                .mouse_button = .{
                    .button = button,
                    .state = state,
                },
            };
        },
        .axis => |e| {
            const axis: ptypes.ScrollAxis = switch (e.axis) {
                .vertical_scroll => .vertical,
                .horizontal_scroll => .horizontal,
                else => {
                    log.warn("Unknown Axis {}... Dropping event", .{e.axis});
                    return;
                },
            };
            break :blk .{
                .mouse_scroll = .{
                    .axis = axis,
                    .value = @floatCast(e.value.toDouble()),
                },
            };
        },
    };

    ws.dispatch.window_system_put(@src(), ws_event) catch {};
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

pub fn viewport_key_from_surface(wl: *const Wayland, surface: *cwl.Surface) ?ViewportKey {
    for (wl.resources.values()) |rs| {
        for (rs.viewports.values()) |vp| {
            if (vp.surface == surface) {
                return .{ .client_id = rs.client_id, .viewport_id = vp.id };
            }
        }
    }

    return null;
}

pub fn frame_listener_set(wl: *Wayland, surface: *cwl.Surface, key: ViewportKey) !void {
    try wl.frame_callbacks.ensureUnusedCapacity(wl.gpa, 1);
    const cb = try surface.frame();

    cb.setListener(*Wayland, frame_listener, wl);
    wl.frame_callbacks.putAssumeCapacityNoClobber(.from_callback(cb), key);
}

fn frame_listener(cb: *cwl.Callback, e: cwl.Callback.Event, wl: *Wayland) void {
    std.debug.print("Frame callback {}\n", .{e.done.callback_data / std.time.ms_per_s});
    const vp_key = wl.frame_callbacks.fetchOrderedRemove(.from_callback(cb)).?.value;

    const rs = wl.resources.get(vp_key.client_id) orelse return;
    const vp = rs.viewports.get(vp_key.viewport_id) orelse return;

    wl.dispatch.server_put(
        @src(),
        .{
            .frame_render = .{
                .client_id = vp_key.client_id,
                .payload = .{
                    .viewport_id = vp.id,
                },
            },
        },
    ) catch {};

    // wl.frame_listener_set(vp.surface, vp_key) catch |err| switch (err) {
    //     error.OutOfMemory => {},
    // };

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

pub const WlBufferID = enum(u32) {
    _,

    pub fn from_wl_buffer(wl_buffer: *cwl.Buffer) WlBufferID {
        return @enumFromInt(wl_buffer.getId());
    }
};

pub const CallbackID = enum(u32) {
    _,

    pub fn from_callback(cb: *cwl.Callback) CallbackID {
        return @enumFromInt(cb.getId());
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
const zwp = @import("wayland").client.zwp;
const wp = @import("wayland").client.wp;
const ClientID = @import("../server/Clients.zig").ClientID;
const WindowSystem = @import("../WindowSystem.zig");
const WindowID = WindowSystem.WindowID;
const log = std.log.scoped(.Wayland);
const utils = @import("utils");
const ClientResources = @import("ClientResources.zig");
const Window = @import("Window.zig");
const c_linux = @import("c_linux");
const Dispatch = @import("../Dispatch.zig");
const BufferKey = WindowSystem.BufferKey;
const ViewportKey = WindowSystem.ViewportKey;
const ptypes = @import("protocol").types;
const BufferID = ptypes.BufferID;
const Event = Dispatch.WindowSystemEvent;
