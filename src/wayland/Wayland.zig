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
cursor_manager: *wp.CursorShapeManagerV1,

display: *cwl.Display,
registry: *cwl.Registry,

windows: std.array_hash_map.Auto(WindowID, *Window),
resources: std.array_hash_map.Auto(ClientID, ClientResources),

wl_buffers: std.array_hash_map.Auto(WlBufferID, BufferKey),
frame_callbacks: std.array_hash_map.Auto(CallbackID, ViewportKey),

xkb_context: *c_linux.struct_xkb_context,
xkb_keymap: ?*c_linux.struct_xkb_keymap,
xkb_state: ?*c_linux.struct_xkb_state,

input_focus_mouse: ?ViewportKey,
input_focus_keyboard: ?WindowID,
input_delay_ms: ?i32,
input_rate_ms: ?i32,
input_repeat_future: ?InputRepeatFuture,

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
        .cursor_manager = null,
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
    const cursor_manager = globals.cursor_manager orelse return error.NoWpCursorManager;

    const xkb_context = c_linux.xkb_context_new(c_linux.XKB_CONTEXT_NO_FLAGS) orelse
        return error.XkbContextNewFailed;

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
        .cursor_manager = cursor_manager,

        .registry = registry,
        .display = display,

        .windows = .empty,
        .resources = .empty,
        .wl_buffers = .empty,
        .frame_callbacks = .empty,

        .xkb_context = xkb_context,
        .xkb_keymap = null,
        .xkb_state = null,

        .input_focus_mouse = null,
        .input_focus_keyboard = null,
        .input_delay_ms = null,
        .input_rate_ms = null,
        .input_repeat_future = null,
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

pub fn client_disconnected(wl: *Wayland, id: ClientID) error{Canceled}!void {
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

    try wl.windows_destroy();
}

pub fn resources_get(wl: *Wayland, id: ClientID) error{ClientDoesNotExist}!*ClientResources {
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

pub fn buffer_create_gpu_with_fds(wl: *Wayland, dispatch: *Dispatch, args: Event.TypeOf(.buffer_create_gpu_with_fds)) !void {
    const rs = try wl.resources_get(args.client_id);

    try rs.buffer_create_and_register_gpu_async(
        dispatch,
        wl,
        args.payload.buffer_id,
        args.payload.fds,
        @intCast(args.payload.width),
        @intCast(args.payload.height),
        args.payload.format,
        args.payload.gbm_bo_modifier,
    );

    _ = wl.display.flush();
}

pub fn buffer_create_cpu_with_fd(wl: *Wayland, args: Event.TypeOf(.buffer_create_cpu_with_fd)) !void {
    const rs = try wl.resources_get(args.client_id);

    try rs.buffer_create_and_register_cpu(
        wl,
        args.payload.buffer_id,
        args.payload.fd,
        @intCast(args.payload.width),
        @intCast(args.payload.height),
        args.payload.format,
    );

    // TODO: Send failure in that case
    try wl.dispatch.server_put(
        @src(),
        .{
            .buffer_created = .{
                .client_id = args.client_id,
                .payload = .{
                    .buffer_id = args.payload.buffer_id,
                    .status = .success,
                },
            },
        },
    );
}

pub fn buffer_present(wl: *Wayland, args: Event.TypeOf(.buffer_present)) !void {
    const viewport_key: ViewportKey = .{
        .client_id = args.client_id,
        .viewport_id = args.payload.viewport_id,
    };

    const window = wl.window_from_viewport_key(viewport_key) orelse {
        log.err("Viewport does not exist {}", .{viewport_key});
        return;
    };

    const rs = try wl.resources_get(args.client_id);

    const vp = rs.viewports.getPtr(args.payload.viewport_id) orelse {
        log.err("Viewport does not exist {}", .{viewport_key});
        return;
    };

    const buffer = rs.buffers.getPtr(args.payload.buffer_id) orelse {
        if (rs.wl_buffers_pending.contains(args.payload.buffer_id)) {
            log.warn("Buffer is pending {} for {}", .{ args.payload.buffer_id, args.client_id });
        } else {
            log.err("Buffer does not exist {} for {}", .{ args.payload.buffer_id, args.client_id });
        }
        return;
    };

    try rs.viewport_mark_commit(wl.gpa, args.payload.buffer_id, args.payload.viewport_id);
    vp.set_source_min(window, buffer);
    vp.surface.damage(0, 0, buffer.width(), buffer.height());
    vp.surface.attach(buffer.wl_buffer(), 0, 0);
    vp.surface.commit();
    // log.debug("buffer_present: commited viewport for {} {} {}", .{ args.client_id, args.viewport_id, args.buffer_id });

    _ = wl.display.flush();
}

pub fn buffer_present_with_sync(wl: *Wayland, args: Event.TypeOf(.buffer_present_with_sync)) !void {
    const viewport_key: ViewportKey = .{ .client_id = args.client_id, .viewport_id = args.payload.viewport_id };

    const window = wl.window_from_viewport_key(viewport_key) orelse {
        log.err("Viewport does not exist {}", .{viewport_key});
        return;
    };
    const rs = try wl.resources_get(args.client_id);

    const vp = rs.viewports.getPtr(args.payload.viewport_id) orelse {
        log.err("Viewport does not exist {}", .{viewport_key});
        return;
    };

    const buffer = rs.buffers.getPtr(args.payload.buffer_id) orelse {
        if (rs.wl_buffers_pending.contains(args.payload.buffer_id)) {
            log.warn("Buffer is pending {} for {}", .{ args.payload.buffer_id, args.client_id });
        } else {
            log.err("Buffer does not exist {} for {}", .{ args.payload.buffer_id, args.client_id });
        }
        return;
    };

    try rs.viewport_mark_commit(wl.gpa, args.payload.buffer_id, args.payload.viewport_id);

    if (vp.vsync) {
        try wl.frame_listener_set(vp.surface, viewport_key);
    }
    errdefer comptime unreachable;

    // log.debug("Set acquire point {} and release point {} for ClientID({}) ViewportID({}) BufferID({})", .{
    //     args.acquire_point,
    //     args.release_point,
    //     @intFromEnum(args.client_id),
    //     @intFromEnum(args.viewport_id),
    //     @intFromEnum(args.buffer_id),
    // });

    vp.set_source_min(window, buffer);
    vp.surface.damage(0, 0, buffer.width(), buffer.height());
    vp.surface.attach(buffer.wl_buffer(), 0, 0);

    if (vp.sync_surface) |sync_surface| {
        switch (buffer.*) {
            .gpu => |gpu| {
                gpu.timeline_acquire.?.set(sync_surface, args.payload.acquire_point);
                gpu.timeline_release.?.set(sync_surface, args.payload.release_point);
            },
            .cpu => {},
        }
    }

    vp.surface.commit();
    // log.debug("buffer_present_with_sync: commited viewport for {} {}", .{ buffer_key, viewport_key });

    _ = wl.display.flush();
}

pub fn buffer_destroy(wl: *Wayland, args: Event.TypeOf(.buffer_destroy)) !void {
    const rs = try wl.resources_get(args.client_id);
    rs.buffer_destroy(wl, args.payload.buffer_id);

    try wl.dispatch.server_put(
        @src(),
        .{
            .buffer_destroyed = .{
                .client_id = args.client_id,
                .payload = .{
                    .buffer_id = args.payload.buffer_id,
                },
            },
        },
    );
}

pub fn viewport_resize(wl: *Wayland, args: Event.TypeOf(.viewport_resize)) !void {
    const rs = try wl.resources_get(args.client_id);
    const vp = rs.viewports.getPtr(args.payload.viewport_id) orelse return error.ViewportDoesNotExist;

    vp.set_source(@intCast(args.payload.width), @intCast(args.payload.height));
}

pub fn windows_destroy(wl: *Wayland) !void {
    var removed = false;
    var i: usize = wl.windows.count();
    while (i > 0) {
        i -= 1;
        const win = wl.windows.values()[i];
        if (win.configured and !win.running) {
            try wl.dispatch.server_put(@src(), .{
                .viewport_closed = .{
                    .client_id = win.viewport_key.client_id,
                    .payload = .{
                        .viewport_id = win.viewport_key.viewport_id,
                    },
                },
            });

            const id = win.id;
            _ = wl.windows.orderedRemove(id);
            win.destroy(wl.gpa);
            removed = true;
        }
    }

    if (removed) {
        _ = wl.display.flush();
    }
}
pub fn window_create(wl: *Wayland, ws: *WindowSystem, args: Event.TypeOf(.window_create)) !void {
    try wl.windows.ensureUnusedCapacity(wl.gpa, 1);

    const rs = try wl.resources_get(args.client_id);
    const id = ws.window_next_id.increment();

    const key: ViewportKey = .{
        .client_id = args.client_id,
        .viewport_id = args.payload.viewport_id,
    };

    const window = try Window.create(
        wl,
        ws,
        id,
        key,
        @intCast(args.payload.width),
        @intCast(args.payload.height),
    );

    try rs.viewport_create(
        wl,
        window.surface,
        args.payload.viewport_id,
        @intCast(args.payload.width),
        @intCast(args.payload.height),
        args.payload.create_sync_timeline,
        args.payload.vsync,
    );

    wl.windows.putAssumeCapacityNoClobber(id, window);
    window.surface.commit();
    _ = wl.display.flush();
}

pub fn window_resize_by_display_server(wl: *Wayland, args: Event.TypeOf(.window_resize_by_display_server)) !void {
    const win = wl.windows.get(args.id) orelse {
        return error.WindowDoesNotExist;
    };

    try win.buffer_resize(wl, args.width, args.height);
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

pub fn display_dispatch(wl: *Wayland) void {
    if (wl.display.dispatch() != .SUCCESS) {
        log.err("Dispatch failed {}", .{wl.display.getError()});
        return;
    }

    for (wl.windows.values()) |win| {
        if (!win.configured) {
            win.surface.commit();
        } else if (win.configured and !win.commited_once) {
            win.commit();
        }
    }
}

pub fn keyboard_keymap(wl: *Wayland, fd: c_int, size: usize, format: cwl.Keyboard.KeymapFormat) !void {
    std.debug.assert(format == .xkb_v1);
    const buffer = try std.posix.mmap(
        null,
        size,
        .{ .READ = true, .WRITE = false },
        .{ .TYPE = .PRIVATE },
        fd,
        0,
    );
    defer {
        std.posix.munmap(buffer);
        std.debug.assert(std.os.linux.close(fd) == 0);
    }

    const new_keymap = c_linux.xkb_keymap_new_from_buffer(
        wl.xkb_context,
        buffer.ptr,
        buffer.len,
        c_linux.XKB_KEYMAP_FORMAT_TEXT_V1,
        c_linux.XKB_KEYMAP_COMPILE_NO_FLAGS,
    ) orelse return error.XkbKeymapNewFailed;
    errdefer c_linux.xkb_keymap_unref(new_keymap);

    const new_state = c_linux.xkb_state_new(new_keymap) orelse return error.XkbStateNewFailed;

    errdefer comptime unreachable;

    c_linux.xkb_keymap_unref(wl.xkb_keymap);
    c_linux.xkb_state_unref(wl.xkb_state);

    wl.xkb_keymap = new_keymap;
    wl.xkb_state = new_state;

    log.debug("New xkb keymap and state", .{});
}

pub fn keyboard_modifiers(
    wl: *Wayland,
    depressed: u32,
    latched: u32,
    locked: u32,
) void {
    const state = wl.xkb_state orelse return;

    _ = c_linux.xkb_state_update_mask(
        state,
        depressed,
        latched,
        locked,
        0,
        0,
        0,
    );
}

pub fn cursor_shape_set(wl: *Wayland, args: Event.TypeOf(.cursor_shape_set)) !void {
    const rs = try wl.resources_get(args.client_id);
    const vp = rs.viewports.getPtr(args.payload.viewport_id) orelse return error.ViewportDoesNotExist;
    const shape = from_protocol_cursor_shape(args.payload.shape);
    vp.pointer.set_shape(shape orelse return);
}

pub fn keyboard_key(wl: *Wayland, args: Event.TypeOf(.keyboard_key)) !void {
    if (wl.input_repeat_future) |*future| {
        future.cancel(wl.io);
    }

    const window_id = wl.input_focus_keyboard orelse return;
    const win = wl.windows.get(window_id) orelse return;
    const key = win.viewport_key;

    const mods = c_linux.xkb_state_serialize_mods(wl.xkb_state, c_linux.XKB_STATE_MODS_EFFECTIVE);
    const alt =
        mods & c_linux.xkb_keymap_mod_get_mask(wl.xkb_keymap, c_linux.XKB_MOD_NAME_ALT) != 0;
    const shift =
        mods & c_linux.xkb_keymap_mod_get_mask(wl.xkb_keymap, c_linux.XKB_MOD_NAME_SHIFT) != 0;
    const control =
        mods & c_linux.xkb_keymap_mod_get_mask(wl.xkb_keymap, c_linux.XKB_MOD_NAME_CTRL) != 0;

    try wl.dispatch.server_put(@src(), .{
        .keyboard_key = .{
            .client_id = key.client_id,
            .payload = .{
                .viewport_id = key.viewport_id,
                .key = args.key,
                .state = args.state,
                .modifiers = .{
                    .alt = alt,
                    .shift = shift,
                    .control = control,
                },
            },
        },
    });

    const maybe_ms = switch (args.state) {
        .pressed => wl.input_delay_ms,
        .repeat => wl.input_rate_ms,
        .released => null,
    };

    if (maybe_ms) |ms| {
        wl.input_repeat_future = wl.io.concurrent(input_repeat, .{
            wl.dispatch,
            ms,
            args.key,
        }) catch |err| blk: {
            log.err("Failed to start task input_repeat {}", .{err});
            break :blk null;
        };
    }
}

pub fn keyboard_repeat_info(wl: *Wayland, rate: i32, delay: i32) void {
    wl.input_rate_ms = @divFloor(1000, rate);
    wl.input_delay_ms = delay;
    log.debug("Repeat info: delay {}ms rate {}ms", .{
        wl.input_rate_ms.?,
        wl.input_delay_ms.?,
    });
}

pub fn keyboard_enter(wl: *Wayland, args: Event.TypeOf(.keyboard_enter)) !void {
    wl.input_focus_keyboard = args.window_id;
}

pub fn keyboard_leave(wl: *Wayland, _: Event.KeyboardLeave) !void {
    wl.input_focus_keyboard = null;
}

pub fn mouse_enter(wl: *Wayland, args: Event.TypeOf(.mouse_enter)) !void {
    wl.input_focus_mouse = .{
        .client_id = args.client_id,
        .viewport_id = args.viewport_id,
    };

    try wl.dispatch.server_put(@src(), .{
        .mouse_enter = .{
            .client_id = args.client_id,
            .payload = .{
                .viewport_id = args.viewport_id,
            },
        },
    });
}

pub fn mouse_leave(wl: *Wayland, args: Event.TypeOf(.mouse_leave)) !void {
    wl.input_focus_mouse = null;

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
pub fn mouse_motion(wl: *Wayland, args: Event.TypeOf(.mouse_motion)) !void {
    const key = wl.input_focus_mouse orelse return;

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
pub fn mouse_button(wl: *Wayland, args: Event.TypeOf(.mouse_button)) !void {
    const key = wl.input_focus_mouse orelse return;
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
pub fn mouse_scroll(wl: *Wayland, args: Event.TypeOf(.mouse_scroll)) !void {
    const key = wl.input_focus_mouse orelse return;
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
            // log.info("Compositor has {s}", .{global.interface});
            const table = .{
                // zig fmt: off
                .{ .field = "compositor",          .T = cwl.Compositor,              .v = 1 },
                .{ .field = "shm",                 .T = cwl.Shm,                     .v = 1 },
                .{ .field = "wm_base",             .T = xdg.WmBase,                  .v = 1 },
                .{ .field = "seat",                .T = cwl.Seat,                    .v = 4 },
                .{ .field = "subcompositor",       .T = cwl.Subcompositor,           .v = 1 },
                .{ .field = "dmabuf",              .T = zwp.LinuxDmabufV1,           .v = 1 },
                .{ .field = "viewporter",          .T = wp.Viewporter,               .v = 1 },
                .{ .field = "sync_object_manager", .T = wp.LinuxDrmSyncobjManagerV1, .v = 1 },
                .{ .field = "cursor_manager",      .T = wp.CursorShapeManagerV1,     .v = 1 },
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
            ws.dispatch.window_system_put(@src(), .windows_destroy) catch {};
        },
    }
}

fn listener_keyboard(_: *cwl.Keyboard, event: cwl.Keyboard.Event, ws: *WindowSystem) void {
    const ws_event: Event = blk: switch (event) {
        .keymap => |e| {
            ws.native.wayland.keyboard_keymap(e.fd, e.size, e.format) catch |err| {
                log.err("keyboard_keymap failed with{}", .{err});
            };

            return;
        },
        .modifiers => |e| {
            ws.native.wayland.keyboard_modifiers(
                e.mods_depressed,
                e.mods_latched,
                e.mods_locked,
            );

            return;
        },
        .repeat_info => |e| {
            ws.native.wayland.keyboard_repeat_info(e.rate, e.delay);
            return;
        },

        inline .leave, .enter => |e, tag| {
            const surface = e.surface orelse {
                log.warn("Dropping keyboard event .{t}: No surface", .{tag});
                return;
            };

            const window_id = ws.native.wayland.window_id_from_surface(surface) orelse {
                log.err("Dropping keyboard event .{t}: Surface without a window", .{tag});
                return;
            };

            break :blk @unionInit(Event, "keyboard_" ++ @tagName(tag), .{
                .window_id = window_id,
            });
        },
        .key => |e| {
            const key = input.linux_key_to_protocol_key(e.key) orelse {
                log.warn("Dropping keyboard event: Unknown key {}", .{e.key});
                return;
            };

            const state: pinput.KeyState = switch (e.state) {
                .released => .released,
                .pressed => .pressed,
                else => {
                    log.warn("Dropping keyboard event: Unknown state {}", .{e.state});
                    return;
                },
            };

            break :blk .{ .keyboard_key = .{ .key = key, .state = state } };
        },
    };

    ws.dispatch.window_system_put(@src(), ws_event) catch {};
}

fn listener_pointer(pointer: *cwl.Pointer, event: cwl.Pointer.Event, ws: *WindowSystem) void {
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

            if (tag == .enter) {
                const rs = ws.native.wayland.resources_get(key.client_id) catch unreachable;
                const viewport = rs.viewports.getPtr(key.viewport_id).?;

                viewport.pointer.on_surface_enter(ws.native.wayland.cursor_manager, pointer, e.serial);
                viewport.pointer.set_shape(.default);
            }

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
            const button: pinput.MouseButton =
                if (e.button == c_linux.BTN_LEFT)
                    .left
                else if (e.button == c_linux.BTN_RIGHT)
                    .right
                else {
                    log.warn("Unknown button {}... Dropping event", .{e.button});
                    return;
                };

            const state: pinput.MouseState = switch (e.state) {
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

pub fn window_id_from_surface(wl: *const Wayland, surface: *cwl.Surface) ?WindowID {
    for (wl.windows.values()) |win| {
        if (win.surface == surface) {
            return win.id;
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

fn frame_listener(cb: *cwl.Callback, _: cwl.Callback.Event, wl: *Wayland) void {
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
}

pub fn from_protocol_cursor_shape(shape: ptypes.CursorShape) ?wp.CursorShapeDeviceV1.Shape {
    return switch (shape) {
        .default => .default,
        .none => null,
        .context_menu => .context_menu,
        .help => .help,
        .pointer => .pointer,
        .progress => .progress,
        .wait => .wait,
        .cell => .cell,
        .crosshair => .crosshair,
        .text => .text,
        .vertical_text => .vertical_text,
        .alias => .alias,
        .copy => .copy,
        .move => .move,
        .no_drop => .no_drop,
        .not_allowed => .not_allowed,
        .grab => .grab,
        .grabbing => .grabbing,
        .e_resize => .e_resize,
        .n_resize => .n_resize,
        .ne_resize => .ne_resize,
        .nw_resize => .nw_resize,
        .s_resize => .s_resize,
        .se_resize => .se_resize,
        .sw_resize => .sw_resize,
        .w_resize => .w_resize,
        .ew_resize => .ew_resize,
        .ns_resize => .ns_resize,
        .nesw_resize => .nesw_resize,
        .nwse_resize => .nwse_resize,
        .col_resize => .col_resize,
        .row_resize => .row_resize,
        .all_scroll => .all_scroll,
        .zoom_in => .zoom_in,
        .zoom_out => .zoom_out,
    };
}

const InputRepeatFuture = Io.Future(@typeInfo(@TypeOf(input_repeat)).@"fn".return_type.?);
fn input_repeat(dispatch: *Dispatch, ms: i32, key: pinput.Key) void {
    dispatch.io.sleep(.fromMilliseconds(ms), .awake) catch return;

    // FIXME: This might end up sending stale data.
    // Add some checks to make sure that doesn't happen
    dispatch.window_system_put(@src(), .{ .keyboard_key = .{
        .key = key,
        .state = .repeat,
    } }) catch return;
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
    cursor_manager: ?*wp.CursorShapeManagerV1,
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

const std = @import("std");
const Io = std.Io;
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
const pinput = @import("protocol").input;
const BufferID = ptypes.BufferID;
const Event = Dispatch.WindowSystemEvent;
const input = @import("input.zig");
