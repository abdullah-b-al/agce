const WindowSystem = @This();

io: Io,
gpa: std.mem.Allocator,
dispatch: *Dispatch,

resources: std.array_hash_map.Auto(ClientID, ClientResources),
windows: std.array_hash_map.Auto(WindowID, *Window),

window_next_id: WindowID,

native: Native,

pub fn create_wayland(
    io: Io,
    gpa: std.mem.Allocator,
    dispatch: *Dispatch,
) !*WindowSystem {
    const ws: *WindowSystem = try .create_undefined_native(
        io,
        gpa,
        dispatch,
    );

    const wl: *Wayland = try .create(dispatch);
    ws.native = .{ .wayland = wl };

    try wl.set_listeners(ws);

    return ws;
}

pub fn create_win32(
    io: Io,
    gpa: std.mem.Allocator,
    instance: Win32.HINSTANCE,
    dispatch: *Dispatch,
) !*WindowSystem {
    const ws: *WindowSystem = try .create_undefined_native(
        io,
        gpa,
        dispatch,
    );

    ws.native = try .create(gpa, instance);

    return ws;
}

fn create_undefined_native(
    io: Io,
    gpa: std.mem.Allocator,
    dispatch: *Dispatch,
) !*WindowSystem {
    const ws = try gpa.create(WindowSystem);
    errdefer gpa.destroy(ws);
    ws.* = .{
        .io = io,
        .gpa = gpa,
        .dispatch = dispatch,
        .resources = .empty,
        .windows = .empty,

        .window_next_id = .first,

        .native = undefined,
    };

    return ws;
}

pub fn destroy(ws: *WindowSystem) void {
    for (ws.resources.values()) |*rs| {
        rs.deinit(ws);
    }

    for (ws.windows.values()) |win| {
        win.destroy(ws.gpa);
    }

    switch (Native) {
        Linux => {
            switch (ws.native) {
                .wayland => |wl| wl.destroy(),
            }
        },
        W32 => ws.native.destroy(),
        else => unreachable,
    }

    inline for (.{
        &ws.resources,
        &ws.windows,
    }) |entry| {
        entry.deinit(ws.gpa);
    }

    ws.gpa.destroy(ws);
}

pub fn event_handle(ws: *WindowSystem, event: Dispatch.WindowSystemEvent) !void {
    switch (event) {
        .exit => return error.Exit,
        .client_registered => |e| try ws.client_registered(e),
        .client_disconnected => |id| try ws.client_disconnected(id),
        .buffer_create_gpu_with_fds => |args| try ws.buffer_create_gpu_with_fds(args),
        .buffer_create_cpu_with_fd => |args| try ws.buffer_create_cpu_with_fd(args),

        .buffer_present => |args| try ws.buffer_present(.{ .no_sync = args }),
        .buffer_present_with_sync => |args| try ws.buffer_present(.{ .sync = args }),

        .buffer_destroy => |args| try ws.buffer_destroy(args),
        .viewport_create => |args| {
            const result = try ws.viewport_create(args);

            switch (result) {
                .create_with_window => |key| {
                    try ws.dispatch.server_put(@src(), .{
                        .viewport_created = .{
                            .client_id = key.client_id,
                            .payload = .{
                                .viewport_id = key.viewport_id,
                                .status = .success,
                            },
                        },
                    });
                },
                .create_with_sub_viewport => |v| {
                    try ws.dispatch.server_put(@src(), .{
                        .viewport_created = .{
                            .client_id = v.embeded.client_id,
                            .payload = .{
                                .viewport_id = v.embeded.viewport_id,
                                .status = .success,
                            },
                        },
                    });

                    try ws.dispatch.server_put(@src(), .{
                        .sub_viewport_embeded = .{
                            .client_id = v.embeder.key.client_id,
                            .payload = .{
                                .sub_viewport_id = v.embeder.key.sub_viewport_id,
                                .status = .success,
                                .render_size = v.embeder.render_size,
                            },
                        },
                    });
                },
            }
        },
        .viewport_destroy => |args| try ws.viewport_destroy(.{
            .client_id = args.client_id,
            .viewport_id = args.payload.viewport_id,
        }),
        .sub_viewport_embed => |args| try ws.sub_viewport_embed(args),
        .sub_viewport_pos_set => |args| try ws.sub_viewport_pos_set(args),
        .sub_viewport_size_set => |args| try ws.sub_viewport_size_set(args),
        .sub_viewport_display_state_set => |args| try ws.sub_viewport_display_state_set(args),
        .window_resize_by_display_server => |args| try ws.window_resize_by_display_server(args),
        .cursor_shape_set => |args| try ws.cursor_shape_set(args),

        .keyboard_key => |args| {
            switch (Native) {
                Linux => switch (ws.native) {
                    .wayland => |wl| try wl.keyboard_key(ws, args),
                },
                W32 => @panic("TODO"),
                else => unreachable,
            }
        },
        .keyboard_enter => |args| {
            switch (Native) {
                Linux => switch (ws.native) {
                    .wayland => |wl| try wl.keyboard_enter(args),
                },
                W32 => @panic("TODO"),
                else => unreachable,
            }
        },
        .keyboard_leave => |args| {
            switch (Native) {
                Linux => switch (ws.native) {
                    .wayland => |wl| try wl.keyboard_leave(args),
                },
                W32 => @panic("TODO"),
                else => unreachable,
            }
        },
        .mouse_enter => |args| {
            switch (Native) {
                Linux => switch (ws.native) {
                    .wayland => |wl| try wl.mouse_enter(ws, args),
                },
                W32 => @panic("TODO"),
                else => unreachable,
            }
        },
        .mouse_leave => |args| {
            switch (Native) {
                Linux => switch (ws.native) {
                    .wayland => |wl| try wl.mouse_leave(args),
                },
                W32 => @panic("TODO"),
                else => unreachable,
            }
        },
        .mouse_motion => |args| {
            switch (Native) {
                Linux => switch (ws.native) {
                    .wayland => |wl| try wl.mouse_motion(ws, args),
                },
                W32 => @panic("TODO"),
                else => unreachable,
            }
        },
        .mouse_button => |args| {
            switch (Native) {
                Linux => switch (ws.native) {
                    .wayland => |wl| try wl.mouse_button(ws, args),
                },
                W32 => @panic("TODO"),
                else => unreachable,
            }
        },
        .mouse_scroll => |args| {
            switch (Native) {
                Linux => switch (ws.native) {
                    .wayland => |wl| try wl.mouse_scroll(ws, args),
                },
                W32 => @panic("TODO"),
                else => unreachable,
            }
        },
        .wayland_dispatch => |dis| {
            switch (Native) {
                Linux => switch (ws.native) {
                    .wayland => |wl| {
                        wl.display_dispatch(ws);
                        dis.signal.set(wl.io);
                    },
                },
                else => @compileError("OS does not support this event"),
            }
        },
    }
}

fn client_registered(ws: *WindowSystem, args: Event.TypeOf(.client_registered)) !void {
    try ws.resources.putNoClobber(ws.gpa, args.client_id, .init(args.client_id));
}

fn client_disconnected(ws: *WindowSystem, id: ClientID) !void {
    const rs = ws.resources.getPtr(id) orelse {
        log.warn("Tried to disconnected an nonexistent client {}", .{id});
        return;
    };

    for (rs.viewports.values()) |vp| {
        ws.viewport_destroy(.{ .client_id = rs.client_id, .viewport_id = vp.id }) catch |err|
            switch (err) {
                error.ClientDoesNotExist => unreachable,
            };
    }

    rs.deinit(ws);
    _ = ws.resources.orderedRemove(id);

    ws.windows_destroy_if_closed();
}

fn viewport_destroy(ws: *WindowSystem, key: ViewportKey) !void {
    const rs = ws.resources.getPtr(key.client_id) orelse return;
    const vp = rs.viewports.get(key.viewport_id) orelse return;

    if (vp.parent_key) |parent| {
        const p = ws.viewport_from_key(parent).?;

        const svp_id = p.sub_viewport_id_from_key(key).?;

        _ = p.sub_viewports.orderedRemove(svp_id);
        ws.dispatch.server_put(@src(), .{
            .sub_viewport_closed = .{
                .client_id = parent.client_id,
                .payload = .{ .sub_viewport_id = svp_id },
            },
        }) catch {};

        vp.parent_key = null;
    }

    for (vp.sub_viewports.values()) |svp_key| {
        const svp = ws.viewport_from_key(svp_key).?;
        svp.parent_key = null;
    }
    vp.sub_viewports.clearRetainingCapacity();

    vp.destroy(ws.gpa);
    _ = rs.viewports.orderedRemove(vp.id);

    log.debug("{f} of {f} destroyed", .{ key.viewport_id, key.client_id });

    ws.windows_destroy_if_closed();
}

fn buffer_create_cpu_with_fd(ws: *WindowSystem, args: Event.TypeOf(.buffer_create_cpu_with_fd)) !void {
    const rs = ws.resources.getPtr(args.client_id) orelse return;
    switch (Native) {
        Linux => {
            switch (ws.native) {
                .wayland => |wl| {
                    try wl.buffer_create_and_register_cpu(
                        ws,
                        rs,
                        args.payload.buffer_id,
                        args.payload.fd,
                        args.payload.size,
                        args.payload.format,
                    );
                },
            }
        },
        else => @compileError("Not supported on OS"),
    }

    try ws.dispatch.server_put(
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

pub fn buffer_create_gpu_with_fds(ws: *WindowSystem, args: Event.TypeOf(.buffer_create_gpu_with_fds)) !void {
    const rs = ws.resources.getPtr(args.client_id) orelse return;

    switch (Native) {
        Linux => {
            switch (ws.native) {
                .wayland => |wl| {
                    try wl.buffer_create_and_register_gpu_async(
                        rs,
                        ws,
                        args.payload.buffer_id,
                        args.payload.fds,
                        args.payload.size,
                        args.payload.format,
                        args.payload.gbm_bo_modifier,
                    );

                    _ = wl.display.flush();
                },
            }
        },
        else => @compileError("Not supported on OS"),
    }
}

const BufferPresent = union(enum) {
    no_sync: Event.TypeOf(.buffer_present),
    sync: Event.TypeOf(.buffer_present_with_sync),
};

fn buffer_present(ws: *WindowSystem, args: BufferPresent) !void {
    const client_id, const viewport_id, const viewport_size, const buffer_id = switch (args) {
        inline else => |v| .{
            v.client_id,             v.payload.viewport_id,
            v.payload.viewport_size, v.payload.buffer_id,
        },
    };

    const viewport_key: ViewportKey = .{
        .client_id = client_id,
        .viewport_id = viewport_id,
    };

    const vp = ws.viewport_from_key(viewport_key) orelse {
        log.err("Viewport does not exist {f} {f}", .{ viewport_key.client_id, viewport_key.viewport_id });
        return;
    };

    const win = ws.window_from_viewport_key(viewport_key) orelse return error.ViewportHasNoWindow;

    const rs = ws.resources.getPtr(client_id) orelse return;

    vp.render_size = viewport_size;

    if (vp.parent_key == null) {
        vp.clipping_rect = .{
            .x = 0,
            .y = 0,
            .width = viewport_size.width,
            .height = viewport_size.height,
        };
    }

    try rs.buffers_commited.ensureUnusedCapacity(ws.gpa, 1);
    const buffer = rs.buffers.getPtr(buffer_id) orelse {
        if (rs.wl_buffers_pending.contains(buffer_id)) {
            log.warn("Buffer is pending {} for {}", .{ buffer_id, client_id });
        } else {
            log.err("Buffer does not exist {} for {}", .{ buffer_id, client_id });
        }
        return;
    };

    switch (Native) {
        Linux => {
            switch (ws.native) {
                .wayland => |wl| {
                    const vp_wl = &vp.native.wayland;
                    const b = &buffer.wayland;
                    const w = &win.native.wayland;

                    rs.buffers_commited.putAssumeCapacityNoClobber(buffer_id, viewport_id);
                    vp_wl.surface.damage(0, 0, b.width(), b.height());
                    vp_wl.surface.attach(b.wl_buffer(), 0, 0);
                    switch (args) {
                        .no_sync => {},
                        .sync => |a| {
                            const sync = a.payload;
                            if (vp_wl.sync_surface) |sync_surface| {
                                switch (b.*) {
                                    .gpu => |gpu| {
                                        gpu.timeline_acquire.?.set(sync_surface, sync.acquire_point);
                                        gpu.timeline_release.?.set(sync_surface, sync.release_point);
                                    },
                                    .cpu => {},
                                }
                            }
                        },
                    }

                    const size = vp_wl.min_source_size_with_buffer(w, b);
                    vp_wl.viewport.setSource(
                        .fromInt(0),
                        .fromInt(0),
                        .fromInt(@intCast(size.width)),
                        .fromInt(@intCast(size.height)),
                    );

                    vp_wl.surface.commit();

                    _ = wl.display.flush();
                },
            }
        },
        W32 => @panic("TODO"),
        else => unreachable,
    }
}

fn buffer_destroy(ws: *WindowSystem, args: Event.TypeOf(.buffer_destroy)) !void {
    const rs = ws.resources.getPtr(args.client_id) orelse return;
    rs.buffer_destroy(ws, args.payload.buffer_id);

    try ws.dispatch.server_put(
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

pub fn viewport_create(ws: *WindowSystem, args: Event.TypeOf(.viewport_create)) !WindowSystem.ViewportCreateResult {
    if (args.payload.size.width <= 0 or args.payload.size.height <= 0) {
        return error.InvalidSize;
    }

    if (args.payload.viewport_id.is_server_id()) {
        return try ws.viewport_create_with_sub_viewport(args);
    } else {
        const key = try ws.viewport_create_with_window(args);
        return .{ .create_with_window = key };
    }
}

fn viewport_create_with_sub_viewport(
    ws: *WindowSystem,
    args: Event.TypeOf(.viewport_create),
) !WindowSystem.ViewportCreateResult {
    const embeded_key: ViewportKey = .{
        .client_id = args.client_id,
        .viewport_id = args.payload.viewport_id,
    };

    std.debug.assert(embeded_key.viewport_id.is_server_id());

    const embeded = ws.resources.getPtr(embeded_key.client_id) orelse return error.ClientDoesNotExist;
    std.debug.assert(
        embeded.viewports_pending.orderedRemove(embeded_key.viewport_id),
    );

    const embeder = try ws.resources_of_embeder_get(embeded_key);
    const sub_viewport_data =
        embeder.sub_viewports_pending_fetch_remove_by_embeded_key(embeded_key) orelse
        return error.SubViewportDoesNotExist;

    const embeder_viewport = embeder.viewports.get(sub_viewport_data.embed_in) orelse
        return error.ViewportDoesNotExist;

    try embeder_viewport.sub_viewports.ensureUnusedCapacity(ws.gpa, 1);

    try embeded.viewport_create(
        ws,
        .{ .viewport = embeder_viewport },
        embeded_key.viewport_id,
        embeder_viewport.window_id,
        sub_viewport_data.clip_rect,
        args.payload.size,
        args.payload.create_sync_timeline,
        .{ .client_id = embeder.client_id, .viewport_id = embeder_viewport.id },
    );

    embeder_viewport.sub_viewports.putAssumeCapacityNoClobber(
        sub_viewport_data.sub_viewport_id,
        embeded_key,
    );

    log.info("{f} of {f} {f} created with {f} {f}", .{
        sub_viewport_data.sub_viewport_id,
        embeder.client_id,
        sub_viewport_data.embed_in,
        embeded_key.client_id,
        embeded_key.viewport_id,
    });
    return .{
        .create_with_sub_viewport = .{
            .embeder = .{
                .key = .{
                    .client_id = embeder.client_id,
                    .sub_viewport_id = sub_viewport_data.sub_viewport_id,
                },
                .render_size = args.payload.size,
            },

            .embeded = embeded_key,
        },
    };
}

fn viewport_create_with_window(ws: *WindowSystem, args: Event.TypeOf(.viewport_create)) !ViewportKey {
    std.debug.assert(!args.payload.viewport_id.is_server_id());

    try ws.windows.ensureUnusedCapacity(ws.gpa, 1);

    const rs = ws.resources.getPtr(args.client_id) orelse return error.ClientDoesNotExist;
    const id = ws.window_next_id.increment();

    const key: ViewportKey = .{
        .client_id = args.client_id,
        .viewport_id = args.payload.viewport_id,
    };

    const win = try Window.create(ws, id, key, args.payload.size);

    try rs.viewport_create(
        ws,
        .{ .window = win },
        args.payload.viewport_id,
        win.id,
        .{ .x = 0, .y = 0, .width = args.payload.size.width, .height = args.payload.size.height },
        args.payload.size,
        args.payload.create_sync_timeline,
        null,
    );

    ws.windows.putAssumeCapacityNoClobber(id, win);

    switch (Native) {
        Linux => {
            switch (ws.native) {
                .wayland => |wl| {
                    win.native.wayland.surface.commit();
                    _ = wl.display.flush();
                },
            }
        },
        W32 => @panic("TODO"),
        else => unreachable,
    }

    log.debug("{f} of {f} created", .{ args.payload.viewport_id, rs.client_id });

    return .{ .client_id = rs.client_id, .viewport_id = args.payload.viewport_id };
}

fn viewport_from_key(ws: *WindowSystem, key: ViewportKey) ?*Viewport {
    const rs = ws.resources.getPtr(key.client_id) orelse return null;
    const vp = rs.viewports.get(key.viewport_id) orelse return null;

    return vp;
}

fn window_from_viewport_key(ws: *WindowSystem, key: ViewportKey) ?*Window {
    var root = key;

    while (true) {
        const rs = ws.resources.getPtr(root.client_id).?;
        const vp = rs.viewports.get(root.viewport_id).?;
        root = vp.parent_key orelse break;
    }

    for (ws.windows.values()) |win| {
        if (std.meta.eql(win.viewport_key, root)) {
            return win;
        }
    }

    return null;
}

pub fn resources_of_embeder_get(ws: *WindowSystem, to_embed: ViewportKey) error{EmbederClientDoesNotExist}!*ClientResources {
    for (ws.resources.values()) |*rs| {
        if (rs.client_id == to_embed.client_id) continue;

        for (rs.sub_viewports_pending.values()) |sub| {
            if (std.meta.eql(to_embed, sub.to_embed)) {
                return rs;
            }
        }
    }

    return error.EmbederClientDoesNotExist;
}

pub fn windows_destroy_if_closed(ws: *WindowSystem) void {
    var removed = false;
    var i: usize = ws.windows.count();
    while (i > 0) {
        i -= 1;
        const win = ws.windows.values()[i];
        const should_close = ws.viewport_from_key(win.viewport_key) == null;
        if (should_close) {
            const id = win.id;
            win.destroy(ws.gpa);
            _ = ws.windows.orderedRemove(id);
            removed = true;
        }
    }

    switch (Native) {
        Linux => {
            switch (ws.native) {
                .wayland => |wl| {
                    if (removed) {
                        _ = wl.display.flush();
                    }
                },
            }
        },
        else => unreachable,
    }
}

pub fn sub_viewport_pos_set(ws: *WindowSystem, args: Event.TypeOf(.sub_viewport_pos_set)) !void {
    std.debug.print("Setting pos {}\n", .{args});
    const key = blk: {
        const rs = ws.resources.getPtr(args.client_id) orelse return;
        break :blk rs.viewport_key_from_sub_viewport_id(args.payload.sub_viewport_id) orelse
            return error.SubViewportDoesNotExist;
    };

    std.debug.assert(key.viewport_id.is_server_id());

    const pos = args.payload.pos;
    const rs = ws.resources.getPtr(key.client_id) orelse return error.ClientDoesNotExist;
    const vp = rs.viewports.get(key.viewport_id) orelse return error.ViewportDoesNotExist;

    if (pos.x < 0 or pos.y < 0) {
        return error.InvalidPosition;
    }

    const set_position = pos.x != vp.clipping_rect.x or pos.y != vp.clipping_rect.y;
    vp.clipping_rect.x = pos.x;
    vp.clipping_rect.y = pos.y;

    switch (Native) {
        Linux => {
            switch (ws.native) {
                .wayland => |wl| {
                    if (set_position) {
                        vp.native.wayland.subsurface.set_position(
                            vp.clipping_rect.x,
                            vp.clipping_rect.y,
                        );
                    }

                    _ = wl.display.flush();
                },
            }
        },
        else => unreachable,
    }
}

pub fn sub_viewport_size_set(ws: *WindowSystem, args: Event.TypeOf(.sub_viewport_size_set)) !void {
    const key = blk: {
        const rs = ws.resources.getPtr(args.client_id) orelse return;
        break :blk rs.viewport_key_from_sub_viewport_id(args.payload.sub_viewport_id) orelse
            return error.SubViewportDoesNotExist;
    };

    std.debug.assert(key.viewport_id.is_server_id());

    const size = args.payload.size;
    const rs = ws.resources.getPtr(key.client_id) orelse return error.ClientDoesNotExist;
    const vp = rs.viewports.get(key.viewport_id) orelse return error.ViewportDoesNotExist;
    const win = ws.window_from_viewport_key(key) orelse return error.ViewportHasNoWindow;

    if (size.width <= 0 or size.height <= 0) {
        return error.InvalidSize;
    }

    vp.clipping_rect.width = size.width;
    vp.clipping_rect.height = size.height;

    switch (Native) {
        Linux => {
            switch (ws.native) {
                .wayland => |wl| {
                    const min_size = vp.native.wayland.min_source_size(&win.native.wayland);
                    vp.native.wayland.viewport.setSource(
                        .fromInt(0),
                        .fromInt(0),
                        .fromInt(@intCast(min_size.width)),
                        .fromInt(@intCast(min_size.height)),
                    );
                    vp.native.wayland.surface.commit();
                    _ = wl.display.flush();
                },
            }
        },
        else => unreachable,
    }

    try ws.dispatch.server_put(@src(), .{
        .viewport_resize = .{
            .client_id = key.client_id,
            .payload = .{
                .viewport_id = key.viewport_id,
                .size = vp.clipping_rect.size(),
            },
        },
    });
}

pub fn sub_viewport_display_state_set(ws: *WindowSystem, args: Event.TypeOf(.sub_viewport_display_state_set)) !void {
    const svp_viewport_key = blk: {
        const rs = ws.resources.getPtr(args.client_id) orelse return;
        break :blk rs.viewport_key_from_sub_viewport_id(args.payload.sub_viewport_id) orelse
            return error.SubViewportDoesNotExist;
    };

    std.debug.assert(svp_viewport_key.viewport_id.is_server_id());

    const svp_rs = ws.resources.getPtr(svp_viewport_key.client_id) orelse return;
    const svp = svp_rs.viewports.get(svp_viewport_key.viewport_id) orelse return error.ViewportDoesNotExist;
    const win = ws.windows.get(svp.window_id) orelse return error.ViewportHasNoWindow;

    const old = svp.state;
    svp.state = args.payload.state;

    if (svp.state == old) return;

    const parent_key = svp.parent_key.?;
    const parent = ws.viewport_from_key(parent_key).?;

    switch (Native) {
        Linux => {
            switch (ws.native) {
                .wayland => |wl| {
                    const size = svp.native.wayland.min_source_size(&win.native.wayland);
                    svp.native.wayland.viewport.setSource(
                        .fromInt(0),
                        .fromInt(0),
                        .fromInt(@intCast(size.width)),
                        .fromInt(@intCast(size.height)),
                    );

                    switch (svp.state) {
                        .hidden => {
                            svp.native.wayland.subsurface.set_position(0, 0);
                            svp.native.wayland.subsurface.place(.below, parent.native.wayland.surface);
                        },
                        .shown => {
                            svp.native.wayland.subsurface.set_position(svp.clipping_rect.x, svp.clipping_rect.y);
                            svp.native.wayland.subsurface.place(.above, parent.native.wayland.surface);
                        },
                    }

                    svp.native.wayland.surface.commit();
                    parent.native.wayland.surface.commit();

                    _ = wl.display.flush();
                },
            }
        },
        W32 => @panic("TODO"),
        else => unreachable,
    }

    try ws.dispatch.server_put(
        @src(),
        .{
            .sub_viewport_display_state = .{
                .client_id = parent_key.client_id,
                .payload = .{
                    .sub_viewport_id = args.payload.sub_viewport_id,
                    .state = args.payload.state,
                },
            },
        },
    );

    try ws.dispatch.server_put(
        @src(),
        .{
            .viewport_display_state = .{
                .client_id = svp_viewport_key.client_id,
                .payload = .{
                    .viewport_id = svp_viewport_key.viewport_id,
                    .state = args.payload.state,
                },
            },
        },
    );
}

pub fn window_resize_by_display_server(ws: *WindowSystem, args: Event.TypeOf(.window_resize_by_display_server)) !void {
    const win = ws.windows.get(args.id) orelse {
        return error.WindowDoesNotExist;
    };

    switch (Native) {
        Linux => {
            switch (ws.native) {
                .wayland => |wl| {
                    try win.native.wayland.resize(wl, args.size);
                    win.native.wayland.viewport_bound(ws);
                    win.native.wayland.commit();
                    _ = wl.display.flush();
                },
            }
        },
        else => unreachable,
    }

    const rs = ws.resources.getPtr(win.viewport_key.client_id) orelse return;
    const vp = rs.viewports.get(win.viewport_key.viewport_id) orelse return;
    if (!std.meta.eql(vp.render_size, args.size)) {
        try ws.dispatch.server_put(@src(), .{
            .viewport_resize = .{
                .client_id = win.viewport_key.client_id,
                .payload = .{
                    .viewport_id = win.viewport_key.viewport_id,
                    .size = args.size,
                },
            },
        });
    }
}

pub fn cursor_shape_set(ws: *WindowSystem, args: Event.TypeOf(.cursor_shape_set)) !void {
    const rs = ws.resources.getPtr(args.client_id) orelse return;
    const vp = rs.viewports.get(args.payload.viewport_id) orelse return error.ViewportDoesNotExist;

    switch (Native) {
        Linux => {
            switch (vp.native) {
                .wayland => |*vp_wl| {
                    const shape = Wayland.from_protocol_cursor_shape(args.payload.shape);
                    vp_wl.pointer.set_shape(shape orelse return);
                },
            }
        },
        else => unreachable,
    }
}

pub fn sub_viewport_embed(ws: *WindowSystem, args: Event.TypeOf(.sub_viewport_embed)) !void {
    const to_embed = ws.resources.getPtr(args.payload.client_id_to_embed) orelse return;
    const embeder = ws.resources.getPtr(args.client_id) orelse return;

    try embeder.sub_viewports_pending.ensureUnusedCapacity(ws.gpa, 1);
    try to_embed.viewports_pending.ensureUnusedCapacity(ws.gpa, 1);

    const viewport_id = to_embed.next_viewport_id.increment_for_server();
    to_embed.viewports_pending.putAssumeCapacityNoClobber(viewport_id, {});

    embeder.sub_viewports_pending.putAssumeCapacityNoClobber(
        args.payload.sub_viewport_id,
        .{
            .to_embed = .{
                .client_id = args.payload.client_id_to_embed,
                .viewport_id = viewport_id,
            },
            .clip_rect = args.payload.rect,
            .embed_in = args.payload.embeder_viewport_id,
            .sub_viewport_id = args.payload.sub_viewport_id,
        },
    );

    try ws.dispatch.server_put(@src(), .{
        .viewport_create = .{
            .client_id = args.payload.client_id_to_embed,
            .payload = .{
                .viewport_id = viewport_id,
                .size = args.payload.rect.size(),
            },
        },
    });
}

pub const ViewportKey = struct {
    client_id: ClientID,
    viewport_id: ViewportID,
};

pub const SubViewportKey = struct {
    client_id: ClientID,
    sub_viewport_id: ptypes.SubViewportID,
};

pub const BufferKey = struct {
    client_id: ClientID,
    buffer_id: BufferID,
};

pub const WindowID = enum(u32) {
    pub const first: @This() = @enumFromInt(1);

    _,

    pub fn increment(this: *@This()) @This() {
        const int = @intFromEnum(this.*);
        this.* = @enumFromInt(int + 1);
        return @enumFromInt(int);
    }

    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("WindowID({})", .{@intFromEnum(self)});
    }
};

pub const ViewportCreateResult = union(enum) {
    create_with_window: ViewportKey,
    create_with_sub_viewport: struct {
        embeder: struct {
            key: SubViewportKey,
            render_size: ptypes.Size,
        },
        embeded: ViewportKey,
    },
};

pub const ParentOfViewport = union(enum) {
    window: *Window,
    viewport: *Viewport,
};

pub const Linux = union(enum) { wayland: *Wayland };
pub const W32 = *Win32;
pub const Native = switch (os_tag) {
    .linux => Linux,
    .windows => W32,
    else => @compileError("Unsupported OS"),
};

pub const Viewport = @import("window_system/Viewport.zig");
pub const Window = @import("window_system/Window.zig");

const std = @import("std");
const Io = std.Io;
const ClientID = ptypes.ClientID;
const ptypes = @import("protocol").types;
const ViewportID = ptypes.ViewportID;
const Wayland = @import("wayland/Wayland.zig");
const Win32 = @import("win32/Win32.zig");
const os_tag = @import("builtin").os.tag;
const log = std.log.scoped(.WindowSystem);
const BufferID = ptypes.BufferID;
const Dispatch = @import("Dispatch.zig");
const ClientResources = @import("window_system/ClientResources.zig");
const Event = Dispatch.WindowSystemEvent;
const win32_win = @import("win32").ui.windows_and_messaging;
