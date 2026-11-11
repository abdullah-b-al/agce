const Wayland = @This();

io: std.Io,
gpa: std.mem.Allocator,

event_queue: *cwl.EventQueue,

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

frame_callbacks: std.array_hash_map.Auto(CallbackID, ViewportKey),

buffer_listener_pool: std.heap.memory_pool.Extra(BufferListener, .{ .growable = false }),
register_gpu_buffer_pool: std.heap.memory_pool.Extra(RegisterGpuBuffer, .{ .growable = false }),

xkb_context: *c_linux.struct_xkb_context,
xkb_keymap: ?*c_linux.struct_xkb_keymap,
xkb_state: ?*c_linux.struct_xkb_state,

input_delay_ms: ?i32,
input_rate_ms: ?i32,
input_repeat_future: ?InputRepeatFuture,

pub fn create(io: Io, gpa: std.mem.Allocator, display: *cwl.Display) !*Wayland {
    const state = try gpa.create(Wayland);
    const queue = try display.createQueue();

    const globals = try get_globals(display, queue);

    const shm = globals.shm orelse return error.NoWlShm;
    const compositor = globals.compositor orelse return error.NoWlCompositor;
    const wm_base = globals.wm_base orelse return error.NoXdgWmBase;
    const seat = globals.seat orelse return error.NoWlSeat;
    const subcompositor = globals.subcompositor orelse return error.NoWlSubcompositor;
    const dmabuf = globals.dmabuf orelse return error.NoZwpDmaBuf;
    const viewporter = globals.viewporter orelse return error.NoWpViewporter;
    const sync_object_manager = globals.sync_object_manager orelse return error.NoWpSyncobjManager;
    const cursor_manager = globals.cursor_manager orelse return error.NoWpCursorManager;

    shm.setQueue(queue);
    compositor.setQueue(queue);
    wm_base.setQueue(queue);
    seat.setQueue(queue);
    subcompositor.setQueue(queue);
    dmabuf.setQueue(queue);
    viewporter.setQueue(queue);
    sync_object_manager.setQueue(queue);
    cursor_manager.setQueue(queue);

    const xkb_context = c_linux.xkb_context_new(c_linux.XKB_CONTEXT_NO_FLAGS) orelse
        return error.XkbContextNewFailed;

    state.* = .{
        .io = io,
        .gpa = gpa,
        .event_queue = queue,

        .shm = shm,
        .compositor = compositor,
        .subcompositor = subcompositor,
        .wm_base = wm_base,
        .seat = seat,
        .dmabuf = dmabuf,
        .viewporter = viewporter,
        .sync_object_manager = sync_object_manager,
        .cursor_manager = cursor_manager,

        .display = display,

        .frame_callbacks = .empty,

        .buffer_listener_pool = .empty,
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
    wl.frame_callbacks.deinit(wl.gpa);

    wl.buffer_listener_pool.deinit(wl.gpa);
    wl.register_gpu_buffer_pool.deinit(wl.gpa);

    wl.gpa.destroy(wl);
}

pub fn present(_: *Wayland, com: *Compositor, comptime native_tag: Compositor.NativeTag) void {
    std.debug.assert(com.server_events.capacity >= com.present_queue.items.len);

    for (com.present_queue.items) |*item| {
        std.debug.assert(item.state == .new);

        const rs = com.resources.getPtr(item.client_uuid).?;
        const vp = rs.viewports.get(item.viewport_id).?;
        const buffer = rs.buffers.getPtr(item.buffer_id).?;

        const nvp = native_tag.viewport(vp);
        const b = &buffer.native.wayland;

        const should_be_hidden = vp.should_be_hidden(com);

        if (should_be_hidden) {
            nvp.surface.attach(null, 0, 0);
        } else {
            nvp.surface.damage(0, 0, b.width(), b.height());
            nvp.surface.attach(b.wl_buffer(), 0, 0);

            const size = nvp.min_source_size_with_buffer(item.window_size, b);
            nvp.viewport.setSource(
                .fromInt(0),
                .fromInt(0),
                .fromInt(@intCast(size.width)),
                .fromInt(@intCast(size.height)),
            );
        }

        // buffer synchronization and release
        switch (b.*) {
            .gpu => |gpu| {
                std.debug.assert(item.sync != null);
                const gbm_bo = rs.gbm_bos.get(item.buffer_id).?;

                if (should_be_hidden) {
                    // Maybe this should wait on the acquisition before releasing ?
                    gbm_bo.signal_release_timeline(com.gbm, item.sync.?.release_point);
                } else {
                    gpu.timeline_acquire.set(nvp.sync_surface.?, item.sync.?.acquire_point);
                    gpu.timeline_release.set(nvp.sync_surface.?, item.sync.?.release_point);
                }
            },
            .cpu => {
                std.debug.assert(item.sync == null);
                const node = com.server_events.create_assume_capacity();

                const case: enum { release, commit } =
                    if (should_be_hidden) .release else .commit;

                branch: switch (case) {
                    .release => {
                        com.server_events.push(node, .{
                            .buffer_released = .{
                                .client_uuid = item.client_uuid,
                                .payload = .{
                                    .buffer_id = item.buffer_id,
                                    .viewport_id = item.viewport_id,
                                },
                            },
                        });
                    },
                    .commit => {
                        rs.buffers_commited.putNoClobber(
                            com.gpa,
                            item.buffer_id,
                            .{ .viewport_id = item.viewport_id, .ptr = node },
                        ) catch continue :branch .release;
                    },
                }
            },
        }

        nvp.surface.commit();
        item.state = .presented;
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

pub fn set_listeners(wl: *Wayland, com: *Compositor) !void {
    const keyboard = try wl.seat.getKeyboard();
    keyboard.setListener(*Compositor, listener_keyboard, com);

    const pointer = try wl.seat.getPointer();
    pointer.setListener(*Compositor, listener_pointer, com);
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

pub fn get_globals(display: *cwl.Display, queue: *cwl.EventQueue) !MaybeGlobals {
    const registry = try display.getRegistry();
    defer registry.destroy();

    registry.setQueue(queue);

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
    const result = display.roundtripQueue(queue);
    if (result != .SUCCESS) return error.RoundtripFailed;

    return globals;
}

fn listener_keyboard(_: *cwl.Keyboard, event: cwl.Keyboard.Event, com: *Compositor) void {
    const wl = com.linux.wayland;
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

            com.deferred_events.append(com.gpa, .{
                .keyboard_key = .{
                    .key = key,
                    .state = state,
                    .modifiers = .{ .alt = alt, .shift = shift, .control = control },
                    .char = char,
                },
            }) catch return;
        },

        .leave, .enter => {}, // Handled by owner of winow
    }
}

fn listener_pointer(pointer: *cwl.Pointer, event: cwl.Pointer.Event, com: *Compositor) void {
    const wl = com.linux.wayland;
    const ws_event: Event = blk: switch (event) {
        inline .leave, .enter => |e, tag| {
            const surface = e.surface orelse return;

            if (viewport_key_from_surface(com, surface)) |key| {
                if (tag == .enter) {
                    const rs = com.resources.getPtr(key.client_uuid).?;
                    const viewport = rs.viewports.get(key.viewport_id).?;
                    const wl_vp = &viewport.linux.wayland;

                    wl_vp.pointer.on_surface_enter(wl.cursor_manager, pointer, e.serial);
                }

                break :blk @unionInit(Event, "mouse_" ++ @tagName(tag), .{
                    .viewport_key = key,
                });
            } else {
                // Assume this is a surface that does not belong to us
                if (tag == .enter) {
                    const key = com.input_focus_mouse orelse return;
                    break :blk .{ .mouse_leave = .{ .viewport_key = key } };
                }

                return;
            }
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

    com.deferred_events.append(com.gpa, ws_event) catch return;
}

pub fn window_id_from_toplevel(com: *const Compositor, tl: *xdg.Toplevel) WindowID {
    const id = tl.getId();
    for (com.windows.values()) |win| {
        if (win.linux.wayland.xdg_toplevel.getId() == id) return win.id;
    }

    unreachable;
}

pub fn viewport_key_from_surface(com: *const Compositor, surface: *cwl.Surface) ?ViewportKey {
    const key, _ = viewport_from_surface(com, surface) orelse return null;

    return key;
}

pub fn viewport_from_surface(com: *const Compositor, surface: *cwl.Surface) ?struct { ViewportKey, *const Viewport } {
    for (com.resources.values()) |rs| {
        for (rs.viewports.values()) |vp| {
            if (vp.linux.wayland.surface == surface) {
                return .{
                    .{ .client_uuid = rs.client_uuid, .viewport_id = vp.id },
                    &vp.linux.wayland,
                };
            }
        }
    }

    return null;
}

pub fn frame_listener_set(com: *Compositor, surface: *cwl.Surface, key: ViewportKey) !void {
    const wl = com.linux.wayland;
    try wl.frame_callbacks.ensureUnusedCapacity(com.gpa, 1);
    const cb = try surface.frame();

    cb.setListener(*Compositor, frame_listener, com);
    wl.frame_callbacks.putAssumeCapacityNoClobber(.from_callback(cb), key);
}

fn find_real_clip_rect(wl: *Wayland, vp: *const Viewport) ptypes.Rect {
    const parent_key = vp.parent_key orelse return vp.clipping_rect;
    const rs = wl.resources_get(parent_key.client_uuid) catch unreachable;
    const p = rs.viewports.getPtr(parent_key.viewport_id).?;

    const parent_rect = wl.find_real_clip_rect(p);
    return .{
        .x = vp.clipping_rect.x + parent_rect.x,
        .y = vp.clipping_rect.y + parent_rect.y,
        .width = @min(vp.clipping_rect.width, parent_rect.width),
        .height = @min(vp.clipping_rect.height, parent_rect.height),
    };
}

fn frame_listener(cb: *cwl.Callback, _: cwl.Callback.Event, com: *Compositor) void {
    const wl = com.linux.wayland;
    const key = wl.frame_callbacks.fetchOrderedRemove(.from_callback(cb)).?.value;
    cb.destroy();

    const rs = com.resources.get(key.client_uuid) orelse return;
    const vp = rs.viewports.get(key.viewport_id) orelse return;
    const nvp = &vp.linux.wayland;
    nvp.refresh_cycle += 1;

    // TODO: Figure out a way to detect that a callback has not been attached
    com.server_events.ensure_unused_capacity(1) catch return;
    com.server_events.push_assume_capacity(.{
        .frame_render = .{
            .client_uuid = key.client_uuid,
            .payload = .{
                .viewport_id = vp.id,
                .refresh_cycle = nvp.refresh_cycle,
            },
        },
    });

    // TODO: Handle in case of error
    frame_listener_set(com, vp.linux.wayland.surface, key) catch {};
}

pub fn buffer_create_and_register_cpu(
    wl: *Wayland,
    com: *Compositor,
    rs: *ClientResources,
    id: BufferID,
    fd: CpuBufferHandle,
    size: ptypes.Size,
    format: BufferFormat,
) !void {
    try rs.buffers.ensureUnusedCapacity(wl.gpa, 1);
    if (wl.buffer_listener_pool.free_list.len() == 0)
        try wl.buffer_listener_pool.addCapacity(com.gpa, 1);

    const cpu = try buffer_create_cpu(wl.shm, fd, size, format);
    Wayland.BufferListener.set_listener(
        wl,
        com,
        rs,
        cpu.wl_buffer,
        id,
        wl.buffer_listener_pool.create(com.gpa) catch unreachable,
    );

    rs.buffers.putAssumeCapacityNoClobber(id, .init_wayland(.{ .cpu = cpu }));
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
    com: *Compositor,
    request_id: ptypes.RequestID,
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

    if (wl.buffer_listener_pool.free_list.len() == 0)
        try wl.buffer_listener_pool.addCapacity(com.gpa, 1);

    try com.server_events.ensure_unused_capacity(1);
    try rs.wl_buffers_pending.ensureUnusedCapacity(wl.gpa, 1);
    try rs.buffers.ensureUnusedCapacity(wl.gpa, 1);

    const acquire_fd: ptypes.DrmSyncobjAcquireTimelineFd = buffer.acquire_fd(com.gbm);
    errdefer acquire_fd.close();

    const release_fd: ptypes.DrmSyncobjReleaseTimelineFd = buffer.release_fd(com.gbm);
    errdefer release_fd.close();

    const acquire: Viewport.AcquireTimeline = try .init(wl.sync_object_manager, acquire_fd);
    errdefer acquire.acquire.destroy();

    const release: Viewport.ReleaseTimeline = try .init(wl.sync_object_manager, release_fd);
    errdefer release.release.destroy();

    const params = try wl.dmabuf.createParams();

    errdefer comptime unreachable;

    const buffer_id = rs.next_buffer_id.increment();
    rs.wl_buffers_pending.putAssumeCapacityNoClobber(buffer_id, {});
    rs.buffers.putAssumeCapacityNoClobber(buffer_id, .init_wayland(
        .{
            .gpu = .{
                .wl_buffer = .pending,
                .size = size,
                .timeline_acquire = acquire,
                .timeline_release = release,
                .format = b_format,
            },
        },
    ));

    const buffer_fd = c_linux.gbm_bo_get_fd(buffer.bo);
    std.debug.assert(buffer_fd >= 0);
    const data = wl.register_gpu_buffer_pool.create(wl.gpa) catch unreachable;
    const buffer_listener = wl.buffer_listener_pool.create(com.gpa) catch unreachable;
    data.* = .{
        .buffer_id = buffer_id,
        .client_uuid = rs.client_uuid,
        .request_id = request_id,
        .wl = wl,
        .com = com,
        .buffer_fd = @enumFromInt(buffer_fd),
        .acquire_timeline = acquire_fd,
        .release_timeline = release_fd,
        .size = size,
        .stride = stride,
        .format = b_format,
        .node = com.server_events.create_assume_capacity(),
        .buffer_listener = buffer_listener,
    };

    params.setListener(*RegisterGpuBuffer, RegisterGpuBuffer.callback, data);
    params.add(buffer_fd, 0, 0, stride, mod_hi, mod_lo);
    params.create(size.width, size.height, format, .{});

    log.debug("GPU Buffer Requsted {f} for {f}", .{ data.buffer_id, data.client_uuid });

    return buffer_id;
}

pub fn should_flush(_: *Wayland, event: Compositor.Event) bool {
    return switch (event) {
        .cursor_shape_set,
        .buffer_present,
        .buffer_present_with_sync,
        .viewport_pos_set,
        .remote_viewport_embed,
        .remote_viewport_embed_with_window,
        .viewport_size_set,
        .viewport_display_state_set,
        .viewport_close,
        .viewport_destroy,
        .viewport_create,
        .buffer_create_gbm_bo,
        => true,

        .viewport_should_close,
        .keyboard_key,
        .keyboard_enter,
        .mouse_enter,
        .mouse_leave,
        .mouse_motion,
        .mouse_button,
        .mouse_scroll,
        .buffer_create_cpu,
        .texture_create_d3d,
        .buffer_destroy,
        => false,
    };
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
pub fn input_repeat(com: *Compositor, ms: i32, key: pinput.Key, modifiers: pinput.Modifiers, char: ?u32) void {
    com.io.sleep(.fromMilliseconds(ms), .awake) catch return;

    // FIXME: This is not thread safe
    // FIXME: This might end up sending stale data.
    // Add some checks to make sure that doesn't happen
    com.deferred_events.append(com.gpa, .{
        .keyboard_key = .{
            .key = key,
            .state = .repeat,
            .modifiers = modifiers,
            .char = char,
        },
    }) catch return;
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

    pub fn wl_buffer(b: Buffer) ?*cwl.Buffer {
        return switch (b) {
            .cpu => |v| v.wl_buffer,
            .gpu => |v| switch (v.wl_buffer) {
                .pending => null,
                .ptr => |ptr| ptr,
            },
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
        wl_buffer: union(enum) {
            pending,
            ptr: *cwl.Buffer,
        },

        timeline_acquire: Wayland.Viewport.AcquireTimeline,
        timeline_release: Wayland.Viewport.ReleaseTimeline,
        size: ptypes.Size,
        format: BufferFormat,

        pub fn destroy(gpu: Gpu) void {
            switch (gpu.wl_buffer) {
                .pending => {},
                .ptr => |ptr| ptr.destroy(),
            }

            gpu.timeline_acquire.acquire.destroy();
            gpu.timeline_release.release.destroy();
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
    com: *Compositor,

    client_uuid: ClientUUID,
    buffer_id: BufferID,
    request_id: ptypes.RequestID,

    buffer_fd: ptypes.GbmBoFd,
    acquire_timeline: ptypes.DrmSyncobjAcquireTimelineFd,
    release_timeline: ptypes.DrmSyncobjReleaseTimelineFd,

    size: ptypes.Size,
    stride: u32,
    format: ptypes.BufferFormat,

    node: *ServerQueue.Node,
    buffer_listener: *BufferListener,

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
                const rs = data.com.resources.getPtr(data.client_uuid) orelse return;

                const buffer = rs.buffers.getPtr(data.buffer_id) orelse {
                    // assume it's been destoryed by client
                    data.buffer_fd.close();
                    data.acquire_timeline.close();
                    data.release_timeline.close();
                    data.com.server_events.destroy(data.node);
                    data.com.linux.wayland.buffer_listener_pool.destroy(data.buffer_listener);
                    return;
                };

                Wayland.BufferListener.set_listener(
                    data.wl,
                    data.com,
                    rs,
                    result.buffer,
                    data.buffer_id,
                    data.buffer_listener,
                );

                const native: *Buffer = &buffer.native.wayland;
                std.debug.assert(native.* == .gpu);
                std.debug.assert(native.gpu.wl_buffer == .pending);

                buffer.native.wayland.gpu.wl_buffer = .{ .ptr = result.buffer };

                log.debug("GPU buffer created {f} for {f}", .{ data.buffer_id, data.client_uuid });

                data.com.server_events.push(data.node, .{
                    .buffer_created_gbm_bo = .{
                        .client_uuid = data.client_uuid,
                        .payload = .ok(.{
                            .request_id = data.request_id,
                            .buffer_id = data.buffer_id,
                            .size = data.size,
                            .fds = .{
                                .buffer = data.buffer_fd,
                                .acquire_timeline = data.acquire_timeline,
                                .release_timeline = data.release_timeline,
                            },
                            .stride = data.stride,
                            .format = data.format,
                        }),
                    },
                });
            },
            .failed => {
                data.buffer_fd.close();
                data.acquire_timeline.close();
                data.release_timeline.close();
                data.com.server_events.destroy(data.node);
                data.com.linux.wayland.buffer_listener_pool.destroy(data.buffer_listener);
                @panic("TODO: Send failure message");
            },
        }
    }
};

pub const BufferListener = struct {
    wl: *Wayland,
    com: *Compositor,
    buffer_key: BufferKey,

    pub fn callback(_: *cwl.Buffer, event: cwl.Buffer.Event, data: *BufferListener) void {
        switch (event) {
            .release => {
                const key = data.buffer_key;
                const rs = data.com.resources.getPtr(key.client_uuid) orelse return;

                const entry = rs.buffers_commited.fetchSwapRemove(key.buffer_id) orelse return;

                data.com.server_events.push(entry.value.ptr, .{
                    .buffer_released = .{
                        .client_uuid = key.client_uuid,
                        .payload = .{
                            .buffer_id = key.buffer_id,
                            .viewport_id = entry.value.viewport_id,
                        },
                    },
                });
            },
        }
    }

    pub fn set_listener(
        wl: *Wayland,
        com: *Compositor,
        rs: *ClientResources,
        wl_buffer: *cwl.Buffer,
        buffer_id: BufferID,
        data: *BufferListener,
    ) void {
        data.* = .{
            .wl = wl,
            .com = com,
            .buffer_key = .{ .client_uuid = rs.client_uuid, .buffer_id = buffer_id },
        };
        wl_buffer.setListener(*BufferListener, BufferListener.callback, data);

        log.debug("Set a listener for wl_buffer {} {}", .{ wl_buffer.getId(), buffer_id });
    }
};

pub const Viewport = @import("Viewport.zig");

const std = @import("std");
const Io = std.Io;
const cwl = @import("wayland").client.wl;
const xdg = @import("wayland").client.xdg;
const zwp = @import("wayland").client.zwp;
const wp = @import("wayland").client.wp;
const ClientUUID = ptypes.ClientUUID;
const Compositor = @import("../Compositor.zig");
const WindowID = Compositor.WindowID;
const log = std.log.scoped(.Wayland);
const utils = @import("utils");
const ClientResources = @import("../ClientResources.zig");
const c_linux = @import("c_linux");
const BufferKey = Compositor.BufferKey;
const ViewportKey = ptypes.ViewportKey;
const RemoteViewportKey = Compositor.RemoteViewportKey;
const ptypes = @import("protocol").types;
const pinput = @import("protocol").input;
const server_to_client = @import("protocol").server_to_client;
const BufferID = ptypes.BufferID;
const Event = Compositor.Event;
const input = @import("input.zig");
const BufferFormat = ptypes.BufferFormat;
const CpuBufferHandle = ptypes.CpuBufferHandle;
const BufferAndTimelineFds = ptypes.BufferAndTimelineFds;
const ServerQueue = @import("../server/EventQueue.zig");
