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
cursor_manager: *wp.CursorShapeManagerV1,

display: *cwl.Display,
registry: *cwl.Registry,

wl_buffers: std.array_hash_map.Auto(WlBufferID, BufferKey),
frame_callbacks: std.array_hash_map.Auto(CallbackID, ViewportKey),

register_gpu_buffer_pool: std.heap.MemoryPool(RegisterGpuBuffer),

xkb_context: *c_linux.struct_xkb_context,
xkb_keymap: ?*c_linux.struct_xkb_keymap,
xkb_state: ?*c_linux.struct_xkb_state,

input_delay_ms: ?i32,
input_rate_ms: ?i32,
input_repeat_future: ?InputRepeatFuture,

pub fn create(io: Io, gpa: std.mem.Allocator) !*Wayland {
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
        .cursor_manager = cursor_manager,

        .registry = registry,
        .display = display,

        .wl_buffers = .empty,
        .frame_callbacks = .empty,
        .register_gpu_buffer_pool = .empty,

        .xkb_context = xkb_context,
        .xkb_keymap = null,
        .xkb_state = null,

        .input_delay_ms = null,
        .input_rate_ms = null,
        .input_repeat_future = null,
    };

    return state;
}

pub fn destroy(wl: *Wayland) void {
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

    wl.register_gpu_buffer_pool.deinit(wl.gpa);

    wl.gpa.destroy(wl);
}

pub fn buffer_set_listener_prepare(wl: *Wayland, ws: *WindowSystem) !void {
    var total: usize = 0;

    for (ws.resources.values()) |rs| {
        total +=
            rs.wl_buffers_pending.count() +
            rs.buffers.count() +
            1;
    }

    try wl.wl_buffers.ensureTotalCapacity(ws.gpa, total);
}

pub fn buffer_set_listener(wl: *Wayland, ws: *WindowSystem, rs: *ClientResources, wl_buffer: *cwl.Buffer, buffer_id: BufferID) void {
    wl_buffer.setListener(*WindowSystem, BufferListener.callback, ws);
    wl.wl_buffers.putAssumeCapacityNoClobber(
        .from_wl_buffer(wl_buffer),
        .{ .client_id = rs.client_id, .buffer_id = buffer_id },
    );

    log.debug("Set a listener for wl_buffer {} {}", .{ wl_buffer.getId(), buffer_id });
}

pub fn display_dispatch(wl: *Wayland, ws: *WindowSystem) void {
    if (wl.display.dispatch() != .SUCCESS) {
        std.process.fatal("Dispatch failed {}", .{wl.display.getError()});
    }

    for (ws.windows.values()) |win| {
        if (!win.linux.wayland.configured) {
            win.linux.wayland.surface.commit();
        } else if (win.linux.wayland.configured and !win.linux.wayland.commited_once) {
            win.linux.wayland.commit();
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

pub fn process_char(maybe_char: ?u32) ?u32 {
    const char = maybe_char orelse return null;

    // filter
    return switch (char) {
        0...' ' - 1,
        127, // DEL
        => null,

        else => char,
    };
}

pub fn keyboard_repeat_info(wl: *Wayland, rate: i32, delay: i32) void {
    wl.input_rate_ms = @divFloor(1000, rate);
    wl.input_delay_ms = delay;
    log.debug("Repeat info: delay {}ms rate {}ms", .{
        wl.input_rate_ms.?,
        wl.input_delay_ms.?,
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

pub fn xdg_surface_listener(xdg_surface: *xdg.Surface, event: xdg.Surface.Event, ws: *WindowSystem) void {
    switch (event) {
        .configure => |configure| {
            xdg_surface.ackConfigure(configure.serial);
            const id = window_id_from_xdg_surface(ws, xdg_surface);
            const win = ws.windows.get(id).?;
            win.linux.wayland.surface.commit();
            win.linux.wayland.configured = true;
        },
    }
}

pub fn xdg_toplevel_listener(tl: *xdg.Toplevel, event: xdg.Toplevel.Event, ws: *WindowSystem) void {
    const window_id = window_id_from_toplevel(ws, tl);
    const win = ws.windows.get(window_id).?;

    switch (event) {
        .configure => |configure| {
            if (configure.width == 0 or configure.height == 0) return;

            ws.event_handle(.{
                .window_resize_by_display_server = .{
                    .id = window_id,
                    .size = .{
                        .width = @intCast(configure.width),
                        .height = @intCast(configure.height),
                    },
                },
            }) catch return;
        },

        .close => {
            ws.server_events.appendAssumeCapacity(.{
                .viewport_close = .{
                    .client_id = win.input_focus_keyboard.client_id,
                    .payload = .{
                        .viewport_id = win.input_focus_keyboard.viewport_id,
                    },
                },
            });
        },
    }
}

fn listener_keyboard(_: *cwl.Keyboard, event: cwl.Keyboard.Event, ws: *WindowSystem) void {
    const wl = ws.linux.wayland;
    switch (event) {
        .keymap => |e| {
            wl.keyboard_keymap(e.fd, e.size, e.format) catch |err| {
                log.err("keyboard_keymap failed with {}", .{err});
            };

            return;
        },
        .modifiers => |e| {
            const state = wl.xkb_state orelse return;

            _ = c_linux.xkb_state_update_mask(
                state,
                e.mods_depressed,
                e.mods_latched,
                e.mods_locked,
                0,
                0,
                0,
            );
        },
        .repeat_info => |e| {
            wl.keyboard_repeat_info(e.rate, e.delay);
            return;
        },

        inline .leave, .enter => |e, tag| {
            const surface = e.surface orelse {
                log.warn("Dropping keyboard event .{t}: No surface", .{tag});
                return;
            };

            const window_id = window_id_from_window_surface(ws, surface) orelse {
                log.err("Dropping keyboard event .{t}: Surface without a window", .{tag});
                return;
            };

            const ws_event = @unionInit(Event, "keyboard_" ++ @tagName(tag), .{
                .window_id = window_id,
            });
            ws.deferred_events.appendAssumeCapacity(ws_event);
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

            var char: ?u32 = null;
            if (state != .released and wl.xkb_state != null) {
                // Adding 8 because https://wayland.freedesktop.org/docs/html/apa.html#protocol-spec-wl_keyboard-enum-keymap_format
                const code = e.key + 8;
                char = c_linux.xkb_state_key_get_utf32(wl.xkb_state.?, code);
            }

            const mods = c_linux.xkb_state_serialize_mods(wl.xkb_state, c_linux.XKB_STATE_MODS_EFFECTIVE);
            const alt =
                mods & c_linux.xkb_keymap_mod_get_mask(wl.xkb_keymap, c_linux.XKB_MOD_NAME_ALT) != 0;
            const shift =
                mods & c_linux.xkb_keymap_mod_get_mask(wl.xkb_keymap, c_linux.XKB_MOD_NAME_SHIFT) != 0;
            const control =
                mods & c_linux.xkb_keymap_mod_get_mask(wl.xkb_keymap, c_linux.XKB_MOD_NAME_CTRL) != 0;

            ws.deferred_events.appendAssumeCapacity(.{
                .keyboard_key = .{
                    .key = key,
                    .state = state,
                    .modifiers = .{ .alt = alt, .shift = shift, .control = control },
                    .char = char,
                },
            });
        },
    }
}

fn listener_pointer(pointer: *cwl.Pointer, event: cwl.Pointer.Event, ws: *WindowSystem) void {
    const wl = ws.linux.wayland;
    const ws_event: Event = blk: switch (event) {
        inline .leave, .enter => |e, tag| {
            const surface = e.surface orelse {
                log.warn("Dropping pointer event without a surface {t}", .{tag});
                return;
            };

            const key, const vp = viewport_from_surface(ws, surface) orelse {
                log.warn("Dropping pointer event without a viewport {t}", .{tag});
                return;
            };

            if (tag == .enter) {
                const rs = ws.resources.getPtr(key.client_id).?;
                const viewport = rs.viewports.get(key.viewport_id).?;
                const wl_vp = &viewport.linux.wayland;

                wl_vp.pointer.on_surface_enter(wl.cursor_manager, pointer, e.serial);
                wl_vp.pointer.set_shape(.default);
            }

            break :blk @unionInit(Event, "mouse_" ++ @tagName(tag), .{
                .client_id = key.client_id,
                .viewport_id = key.viewport_id,
                .window_id = vp.base.window_id,
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

    ws.deferred_events.appendAssumeCapacity(ws_event);
}

pub fn window_id_from_toplevel(ws: *const WindowSystem, tl: *xdg.Toplevel) WindowID {
    const id = tl.getId();
    for (ws.windows.values()) |win| {
        if (win.linux.wayland.xdg_toplevel.getId() == id) return win.id;
    }

    unreachable;
}

pub fn window_id_from_xdg_surface(ws: *const WindowSystem, xdg_surface: *xdg.Surface) WindowID {
    const id = xdg_surface.getId();
    for (ws.windows.values()) |win| {
        if (win.linux.wayland.xdg_surface.getId() == id) return win.id;
    }

    unreachable;
}

pub fn window_from_viewport_key(wl: *Wayland, key: ViewportKey) ?*Window {
    var root = key;

    while (true) {
        const rs = wl.resources_get(root.client_id) catch unreachable;
        const vp = rs.viewports.get(root.viewport_id).?;
        root = vp.parent_key orelse break;
    }

    for (wl.windows.values()) |win| {
        if (std.meta.eql(win.viewport_key, root)) {
            return win;
        }
    }

    return null;
}

pub fn window_id_from_window_surface(ws: *const WindowSystem, surface: *cwl.Surface) ?WindowID {
    for (ws.windows.values()) |win| {
        if (win.linux.wayland.surface == surface) {
            return win.id;
        }
    }

    return null;
}

pub fn viewport_key_from_surface(wl: *const Wayland, surface: *cwl.Surface) ?ViewportKey {
    const key, _ = wl.viewport_from_surface(surface) orelse return null;

    return key;
}

pub fn viewport_from_surface(ws: *const WindowSystem, surface: *cwl.Surface) ?struct { ViewportKey, *const Viewport } {
    for (ws.resources.values()) |rs| {
        for (rs.viewports.values()) |vp| {
            if (vp.linux.wayland.surface == surface) {
                return .{
                    .{ .client_id = rs.client_id, .viewport_id = vp.id },
                    &vp.linux.wayland,
                };
            }
        }
    }

    return null;
}

pub fn frame_listener_set(ws: *WindowSystem, surface: *cwl.Surface, key: ViewportKey) !void {
    const wl = ws.linux.wayland;
    try wl.frame_callbacks.ensureUnusedCapacity(ws.gpa, 1);
    const cb = try surface.frame();

    cb.setListener(*WindowSystem, frame_listener, ws);
    wl.frame_callbacks.putAssumeCapacityNoClobber(.from_callback(cb), key);
}

fn find_real_clip_rect(wl: *Wayland, vp: *const Viewport) ptypes.Rect {
    const parent_key = vp.parent_key orelse return vp.clipping_rect;
    const rs = wl.resources_get(parent_key.client_id) catch unreachable;
    const p = rs.viewports.getPtr(parent_key.viewport_id).?;

    const parent_rect = wl.find_real_clip_rect(p);
    return .{
        .x = vp.clipping_rect.x + parent_rect.x,
        .y = vp.clipping_rect.y + parent_rect.y,
        .width = @min(vp.clipping_rect.width, parent_rect.width),
        .height = @min(vp.clipping_rect.height, parent_rect.height),
    };
}

fn frame_listener(cb: *cwl.Callback, _: cwl.Callback.Event, ws: *WindowSystem) void {
    const wl = ws.linux.wayland;
    const key = wl.frame_callbacks.fetchOrderedRemove(.from_callback(cb)).?.value;
    cb.destroy();

    const rs = ws.resources.get(key.client_id) orelse return;
    const vp = rs.viewports.get(key.viewport_id) orelse return;
    const nvp = &vp.linux.wayland;
    nvp.refresh_cycle += 1;

    ws.server_events.appendAssumeCapacity(.{
        .frame_render = .{
            .client_id = key.client_id,
            .payload = .{
                .viewport_id = vp.id,
                .refresh_cycle = nvp.refresh_cycle,
            },
        },
    });

    // TODO: Handle in case of error
    frame_listener_set(ws, vp.linux.wayland.surface, key) catch {};
}

pub fn buffer_create_and_register_cpu(
    wl: *Wayland,
    ws: *WindowSystem,
    rs: *ClientResources,
    id: BufferID,
    fd: CpuBufferHandle,
    size: ptypes.Size,
    format: BufferFormat,
) !void {
    try rs.buffers.ensureUnusedCapacity(wl.gpa, 1);
    try wl.buffer_set_listener_prepare(ws);

    const cpu = try buffer_create_cpu(wl.shm, fd, size, format);
    wl.buffer_set_listener(ws, rs, cpu.wl_buffer, id);

    rs.buffers.putAssumeCapacityNoClobber(id, .{ .wayland = .{ .cpu = cpu } });
}

pub fn buffer_create_cpu(
    shm: *cwl.Shm,
    fd: CpuBufferHandle,
    size: ptypes.Size,
    format: BufferFormat,
) !Buffer.Cpu {
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

const TimelinePair = struct {
    acquire: Viewport.AcquireTimeline,
    acquire_fd: ptypes.AcquireTimelineFd,
    release: Viewport.ReleaseTimeline,
    release_fd: ptypes.ReleaseTimelineFd,
};

pub fn buffer_create_and_register_gpu_async(
    wl: *Wayland,
    rs: *ClientResources,
    ws: *WindowSystem,
    viewport_id: ptypes.ViewportID,
    buffer: *const ClientResources.GbmBo,
    size: ptypes.Size,
    b_format: BufferFormat,
) !BufferID {
    const modifier = c_linux.gbm_bo_get_modifier(buffer.bo);

    std.debug.assert(
        size.width == c_linux.gbm_bo_get_width(buffer.bo),
    );
    std.debug.assert(
        size.height == c_linux.gbm_bo_get_height(buffer.bo),
    );

    const mod_lo: u32 = @intCast(modifier & 0xFF_FF_FF_FF);
    const mod_hi: u32 = @intCast(modifier >> 32);
    const stride: u32 = c_linux.gbm_bo_get_stride(buffer.bo);
    const format = switch (b_format) {
        .argb8888 => c_linux.DRM_FORMAT_ARGB8888,
    };

    if (wl.register_gpu_buffer_pool.free_list.len() == 0)
        try wl.register_gpu_buffer_pool.addCapacity(wl.gpa, 1);

    try rs.wl_buffers_pending.ensureUnusedCapacity(wl.gpa, 1);
    try rs.buffers.ensureUnusedCapacity(wl.gpa, rs.wl_buffers_pending.capacity());
    try wl.buffer_set_listener_prepare(ws);

    const acquire_fd: ptypes.DrmSyncobjAcquireTimelineFd = buffer.acquire_fd(ws.gbm);
    const release_fd: ptypes.DrmSyncobjReleaseTimelineFd = buffer.release_fd(ws.gbm);
    const acquire: Viewport.AcquireTimeline = try .init(wl.sync_object_manager, acquire_fd);
    errdefer {
        acquire.acquire.destroy();
        std.debug.assert(std.os.linux.close(@intFromEnum(acquire_fd)) == 0);
        std.debug.assert(std.os.linux.close(@intFromEnum(release_fd)) == 0);
    }
    const release: Viewport.ReleaseTimeline = try .init(wl.sync_object_manager, release_fd);
    errdefer release.release.destroy();

    const params = try wl.dmabuf.createParams();

    errdefer comptime unreachable;

    const buffer_id = rs.next_buffer_id.increment();
    rs.wl_buffers_pending.putAssumeCapacityNoClobber(buffer_id, {});
    const gpu: Buffer.Gpu = .{
        .wl_buffer = undefined,
        .timeline_acquire = acquire,
        .timeline_release = release,
        .size = size,
        .format = b_format,
    };

    const buffer_fd = c_linux.gbm_bo_get_fd(buffer.bo);
    std.debug.assert(buffer_fd >= 0);
    const data = wl.register_gpu_buffer_pool.create(wl.gpa) catch unreachable;
    data.* = .{
        .buffer_id = buffer_id,
        .client_id = rs.client_id,
        .viewport_id = viewport_id,
        .wl = wl,
        .ws = ws,
        .gpu = gpu,
        .buffer_fd = @enumFromInt(buffer_fd),
        .acquire_timeline = acquire_fd,
        .release_timeline = release_fd,
        .size = size,
        .stride = stride,
        .format = b_format,
    };

    params.setListener(*RegisterGpuBuffer, RegisterGpuBuffer.callback, data);
    params.add(buffer_fd, 0, 0, stride, mod_hi, mod_lo);
    params.create(size.width, size.height, format, .{});

    log.debug("GPU Buffer Requsted {f} for {f}", .{ data.buffer_id, data.client_id });

    _ = wl.display.flush();

    return buffer_id;
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
pub fn input_repeat(ws: *WindowSystem, ms: i32, key: pinput.Key, modifiers: pinput.Modifiers, char: ?u32) void {
    ws.io.sleep(.fromMilliseconds(ms), .awake) catch return;

    // FIXME: This is not thread safe
    // FIXME: This might end up sending stale data.
    // Add some checks to make sure that doesn't happen
    ws.deferred_events.appendAssumeCapacity(.{
        .keyboard_key = .{
            .key = key,
            .state = .repeat,
            .modifiers = modifiers,
            .char = char,
        },
    });
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

pub const Buffer = union(enum) {
    gpu: Gpu,
    cpu: Cpu,

    pub fn destroy(b: *Buffer) void {
        switch (b.*) {
            inline else => |v| v.destroy(),
        }
    }

    pub fn wl_buffer(b: Buffer) *cwl.Buffer {
        return switch (b) {
            inline else => |v| v.wl_buffer,
        };
    }

    pub fn width(b: Buffer) i32 {
        return switch (b) {
            inline else => |v| v.size.width,
        };
    }

    pub fn height(b: Buffer) i32 {
        return switch (b) {
            inline else => |v| v.size.height,
        };
    }

    pub fn format(b: Buffer) ptypes.BufferFormat {
        return switch (b) {
            inline else => |v| v.format,
        };
    }

    pub const Gpu = struct {
        wl_buffer: *cwl.Buffer,
        timeline_acquire: ?Wayland.Viewport.AcquireTimeline,
        timeline_release: ?Wayland.Viewport.ReleaseTimeline,
        size: ptypes.Size,
        format: BufferFormat,

        pub fn destroy(gpu: Gpu) void {
            gpu.wl_buffer.destroy();
            if (gpu.timeline_acquire) |tl| tl.acquire.destroy();
            if (gpu.timeline_release) |tl| tl.release.destroy();
        }
    };

    pub const Cpu = struct {
        wl_buffer: *cwl.Buffer,
        size: ptypes.Size,
        format: BufferFormat,

        pub fn destroy(cpu: Cpu) void {
            cpu.wl_buffer.destroy();
        }
    };
};

pub const RegisterGpuBuffer = struct {
    wl: *Wayland,
    ws: *WindowSystem,
    client_id: ClientID,
    buffer_id: BufferID,
    viewport_id: ptypes.ViewportID,
    size: ptypes.Size,
    gpu: Buffer.Gpu,
    buffer_fd: ptypes.GbmBoFd,
    acquire_timeline: ptypes.DrmSyncobjAcquireTimelineFd,
    release_timeline: ptypes.DrmSyncobjReleaseTimelineFd,
    stride: u32,
    format: ptypes.BufferFormat,

    pub fn callback(
        p: *zwp.LinuxBufferParamsV1,
        event: zwp.LinuxBufferParamsV1.Event,
        data: *RegisterGpuBuffer,
    ) void {
        defer {
            p.destroy();
            data.wl.register_gpu_buffer_pool.destroy(data);
        }

        switch (event) {
            .created => |result| {
                const rs = data.ws.resources.getPtr(data.client_id) orelse return;

                data.wl.buffer_set_listener(
                    data.ws,
                    rs,
                    result.buffer,
                    data.buffer_id,
                );
                rs.buffers.putAssumeCapacityNoClobber(
                    data.buffer_id,
                    .{
                        .wayland = .{
                            .gpu = .{
                                .wl_buffer = result.buffer,
                                .size = data.gpu.size,
                                .timeline_acquire = data.gpu.timeline_acquire,
                                .timeline_release = data.gpu.timeline_release,
                                .format = data.format,
                            },
                        },
                    },
                );

                log.debug("GPU buffer created {f} for {f}", .{ data.buffer_id, data.client_id });

                data.ws.server_events.appendAssumeCapacity(.{
                    .buffer_created_gbm_bo = .{
                        .client_id = data.client_id,
                        .payload = .{
                            .viewport_id = data.viewport_id,
                            .buffer_id = data.buffer_id,
                            .size = data.size,
                            .fds = .{
                                .buffer = data.buffer_fd,
                                .acquire_timeline = data.acquire_timeline,
                                .release_timeline = data.release_timeline,
                            },
                            .stride = data.stride,
                            .format = data.format,
                        },
                    },
                });
            },
            .failed => {
                std.debug.assert(std.os.linux.close(@intFromEnum(data.buffer_fd)) == 0);
                std.debug.assert(std.os.linux.close(@intFromEnum(data.acquire_timeline)) == 0);
                std.debug.assert(std.os.linux.close(@intFromEnum(data.release_timeline)) == 0);
                @panic("TODO: Send failure message");
            },
        }
    }
};

pub const BufferListener = struct {
    pub fn callback(wl_buffer: *cwl.Buffer, event: cwl.Buffer.Event, ws: *WindowSystem) void {
        switch (event) {
            .release => {
                const key = ws.linux.wayland.wl_buffers.get(.from_wl_buffer(wl_buffer)) orelse
                    return;

                const rs = ws.resources.getPtr(key.client_id) orelse return;

                const entry = rs.buffers_commited.fetchSwapRemove(key.buffer_id) orelse return;

                ws.server_events.appendAssumeCapacity(.{
                    .buffer_released = .{
                        .client_id = key.client_id,
                        .payload = .{
                            .buffer_id = key.buffer_id,
                            .viewport_id = entry.value,
                        },
                    },
                });
            },
        }
    }
};

pub const Window = @import("Window.zig");
pub const Viewport = @import("Viewport.zig");

const std = @import("std");
const Io = std.Io;
const cwl = @import("wayland").client.wl;
const xdg = @import("wayland").client.xdg;
const zwp = @import("wayland").client.zwp;
const wp = @import("wayland").client.wp;
const ClientID = ptypes.ClientID;
const WindowSystem = @import("../WindowSystem.zig");
const WindowID = WindowSystem.WindowID;
const log = std.log.scoped(.Wayland);
const utils = @import("utils");
const ClientResources = @import("../window_system/ClientResources.zig");
const c_linux = @import("c_linux");
const BufferKey = WindowSystem.BufferKey;
const ViewportKey = WindowSystem.ViewportKey;
const SubViewportKey = WindowSystem.SubViewportKey;
const ptypes = @import("protocol").types;
const pinput = @import("protocol").input;
const server_to_client = @import("protocol").server_to_client;
const BufferID = ptypes.BufferID;
const Event = WindowSystem.Event;
const input = @import("input.zig");
const BufferFormat = ptypes.BufferFormat;
const CpuBufferHandle = ptypes.CpuBufferHandle;
const BufferAndTimelineFds = ptypes.BufferAndTimelineFds;
