const WindowSystem = @This();

io: Io,
gpa: std.mem.Allocator,
class_of_window: [:0]const u8,
/// Used in windows
class_of_viewport: [:0]const u8,

/// Used in windows to prevent accesing freed data in callbacks
destroy_started: bool,

resources: std.array_hash_map.Auto(ClientID, ClientResources),
windows: std.array_hash_map.Auto(WindowID, *Window),

window_next_id: WindowID,

server_events: std.ArrayList(ServerEvent),
deferred_events: std.ArrayList(Event),
present_queue: std.ArrayList(BufferPresent),

/// A list of os handles to close at the end of tick()
handles_to_close: std.ArrayList(HandleToClose),

gbm: Gbm,

win32: if (os == .windows) *Win32 else void,
linux: if (os == .linux) Linux else void,

input_focus_mouse: ?ViewportKey,
input_focus_keyboard: ?ViewportKey,

pub fn create(
    io: Io,
    gpa: std.mem.Allocator,
    class: []const u8,
) !*WindowSystem {
    return blk: switch (os) {
        .linux => try .create_wayland(io, gpa, class),
        .windows => {
            const hinstance = @import("win32").system.library_loader.GetModuleHandleW(null).?;
            break :blk try .create_win32(
                io,
                gpa,
                hinstance,
                class,
            );
        },
        else => @compileError("Unsupported OS"),
    };
}

pub fn create_wayland(
    io: Io,
    gpa: std.mem.Allocator,
    class: []const u8,
) !*WindowSystem {
    const ws: *WindowSystem = try .create_undefined_native(
        io,
        gpa,
        class,
    );

    const wl: *Wayland = try .create(io, gpa);
    ws.linux = .{ .wayland = wl };

    try wl.set_listeners(ws);

    return ws;
}

pub fn create_win32(
    io: Io,
    gpa: std.mem.Allocator,
    instance: Win32.HINSTANCE,
    class: []const u8,
) !*WindowSystem {
    const ws: *WindowSystem = try .create_undefined_native(
        io,
        gpa,
        class,
    );

    ws.win32 = try .create(ws, instance);

    return ws;
}

fn create_undefined_native(
    io: Io,
    gpa: std.mem.Allocator,
    class: []const u8,
) !*WindowSystem {
    const class_window_dupe = try gpa.dupeZ(u8, class);
    errdefer gpa.free(class_window_dupe);
    const class_viewport = try std.fmt.allocPrintSentinel(gpa, "{s}-viewport", .{class_window_dupe}, 0);
    errdefer gpa.free(class_viewport);

    const ws = try gpa.create(WindowSystem);
    errdefer gpa.destroy(ws);

    const gbm: Gbm = if (!constants.os_has_gbm) {} else blk: {
        std.debug.assert(os == .linux);

        const dri = try Io.Dir.openFileAbsolute(
            io,
            "/dev/dri/renderD128",
            .{ .mode = .read_write },
        );

        const device = c_linux.gbm_create_device(dri.handle) orelse
            return error.CouldNotCreateGbmDevice;

        break :blk .{ .dri = dri, .device = device };
    };

    ws.* = .{
        .io = io,
        .gpa = gpa,
        .class_of_window = class_window_dupe,
        .class_of_viewport = class_viewport,
        .resources = .empty,
        .windows = .empty,
        .gbm = gbm,

        .window_next_id = .first,
        .destroy_started = false,

        .server_events = .empty,
        .deferred_events = .empty,
        .present_queue = .empty,
        .handles_to_close = .empty,

        .input_focus_mouse = null,
        .input_focus_keyboard = null,

        .win32 = undefined,
        .linux = undefined,
    };

    return ws;
}

pub fn destroy(ws: *WindowSystem) void {
    ws.destroy_started = true;

    for (ws.resources.values()) |*rs| {
        rs.deinit(ws);
    }

    for (ws.windows.values()) |win| {
        win.destroy(ws.gpa);
    }

    switch (ws.native_tag()) {
        .wayland => |tag| {
            const wl = tag.window_system(ws);
            wl.destroy();
        },
        .win32 => |tag| {
            const w = tag.window_system(ws);
            w.destroy();
        },
    }

    while (ws.handles_to_close.pop()) |handle| {
        handle.close();
    }

    inline for (.{
        &ws.resources,
        &ws.windows,
        &ws.deferred_events,
        &ws.server_events,
        &ws.handles_to_close,
        &ws.present_queue,
    }) |entry| {
        entry.deinit(ws.gpa);
    }

    ws.gpa.free(ws.class_of_window);
    ws.gpa.free(ws.class_of_viewport);
    ws.gpa.destroy(ws);
}

pub fn native_tag(ws: *WindowSystem) NativeTag {
    return switch (os) {
        .linux => switch (ws.linux) {
            .wayland => .wayland,
        },
        .windows => .win32,
        else => comptime unreachable,
    };
}

pub fn events_handle(ws: *WindowSystem, events: []const Event) void {
    for (events) |e| {
        ws.event_handle(e) catch |err| {
            log.err("event_handle {}", .{err});
        };
    }
}

pub fn event_handle(ws: *WindowSystem, event: Event) !void {
    switch (event) {
        .buffer_create_cpu => |args| try ws.buffer_create_cpu(args),
        .buffer_create_gbm_bo => |args| try ws.buffer_create_gbm_bo(args),

        .buffer_present => |args| try ws.present_queue_push(.{ .no_sync = args }),
        .buffer_present_with_sync => |args| try ws.present_queue_push(.{ .sync = args }),

        .buffer_destroy => |args| try ws.buffer_destroy(args),

        .texture_create_d3d => |args| try ws.texture_create_d3d(args),

        .viewport_create => |args| try ws.viewport_create(args),
        .viewport_destroy => |args| ws.viewport_destroy(.{ .client_id = args.client_id, .viewport_id = args.payload.viewport_id }),
        .viewport_should_close => |args| try ws.viewport_should_close(args),

        .sub_viewport_embed => |args| try ws.sub_viewport_embed(args),
        .sub_viewport_pos_set => |args| try ws.sub_viewport_pos_set(args),
        .sub_viewport_size_set => |args| try ws.sub_viewport_size_set(args),
        .sub_viewport_display_state_set => |args| try ws.sub_viewport_display_state_set(args),
        .sub_viewport_close => |args| try ws.sub_viewport_close(args),

        .window_resize_by_display_server => |args| try ws.window_resize_by_display_server(args),
        .cursor_shape_set => |args| try ws.cursor_shape_set(args),

        .keyboard_key => |args| try ws.keyboard_key(args),
        .keyboard_enter => |args| try ws.keyboard_enter(args),
        .keyboard_leave => |args| try ws.keyboard_leave(args),
        .mouse_enter => |args| try ws.mouse_enter(args),
        .mouse_leave => |args| try ws.mouse_leave(args),
        .mouse_motion => |args| try ws.mouse_motion(args),
        .mouse_button => |args| try ws.mouse_button(args),
        .mouse_scroll => |args| try ws.mouse_scroll(args),
    }
}

pub fn client_registered(ws: *WindowSystem, client_id: ClientID) !void {
    try ws.resources.putNoClobber(ws.gpa, client_id, .init(client_id));
}

pub fn client_disconnected(ws: *WindowSystem, id: ClientID) void {
    const rs = ws.resources.getPtr(id) orelse {
        log.warn("Tried to disconnected an nonexistent client {}", .{id});
        return;
    };

    var i = rs.viewports.count();
    while (i > 0) {
        i -= 1;
        const vp_id = rs.viewports.keys()[i];
        ws.viewport_destroy(.{ .client_id = rs.client_id, .viewport_id = vp_id });
    }

    rs.deinit(ws);
    _ = ws.resources.orderedRemove(id);

    ws.windows_destroy_if_closed();
}

fn viewport_destroy(ws: *WindowSystem, key: ViewportKey) void {
    const rs = ws.resources.getPtr(key.client_id) orelse return;
    const vp = rs.viewports.get(key.viewport_id) orelse return;

    if (vp.parent_key) |parent| {
        const p = ws.viewport_from_key(parent).?;

        const svp_id = p.sub_viewport_id_from_key(key).?;

        _ = p.sub_viewports.orderedRemove(svp_id);
        ws.server_events.appendAssumeCapacity(.{
            .sub_viewport_closed = .{
                .client_id = parent.client_id,
                .payload = .{ .sub_viewport_id = svp_id },
            },
        });

        if (std.meta.eql(ws.input_focus_keyboard, key)) {
            ws.keyboard_focus_set(parent);
        }

        if (std.meta.eql(ws.input_focus_mouse, key)) {
            ws.mouse_focus_set(parent);
        }

        vp.parent_key = null;
    }

    for (vp.sub_viewports.values()) |svp_key| {
        const svp = ws.viewport_from_key(svp_key).?;
        svp.parent_key = null;
    }
    vp.sub_viewports.clearRetainingCapacity();

    _ = rs.viewports.orderedRemove(vp.id);
    vp.destroy(ws.gpa);

    log.debug("{f} of {f} destroyed", .{ key.viewport_id, key.client_id });

    ws.windows_destroy_if_closed();
}

fn viewport_should_close(ws: *WindowSystem, args: Event.TypeOf(.viewport_should_close)) !void {
    ws.server_events.appendAssumeCapacity(.{
        .viewport_close = .{
            .client_id = args.viewport_key.client_id,
            .payload = .{ .viewport_id = args.viewport_key.viewport_id },
        },
    });
}

fn buffer_create_cpu(ws: *WindowSystem, args: Event.TypeOf(.buffer_create_cpu)) !void {
    try ws.server_events.ensureUnusedCapacity(ws.gpa, 1);
    const rs = ws.resources.getPtr(args.client_id).?;

    const buffer = try ws.buffer_create_cpu_inner(
        rs,
        args.payload.size,
        args.payload.format,
    );

    ws.server_events.appendAssumeCapacity(.{
        .buffer_created_cpu = .{
            .client_id = args.client_id,
            .payload = .{
                .handle = buffer.handle,
                .viewport_id = args.payload.viewport_id,
                .buffer_id = buffer.buffer_id,
                .size = args.payload.size,
                .format = args.payload.format,
            },
        },
    });
}

const BufferCreateCpu = struct {
    handle: ptypes.CpuBufferHandle,
    buffer_id: BufferID,
};

fn buffer_create_cpu_inner(ws: *WindowSystem, rs: *ClientResources, size: ptypes.Size, format: ptypes.BufferFormat) !BufferCreateCpu {
    try rs.buffers.ensureUnusedCapacity(ws.gpa, 1);

    const size_bytes = size.width * size.height * format.bytes_per_pixel();

    switch (ws.native_tag()) {
        .wayland => |tag| {
            const wl = tag.window_system(ws);
            const fd: ptypes.CpuBufferHandle = @enumFromInt(try std.posix.memfd_create("agce-buffer", 0));
            if (std.posix.errno(std.posix.system.ftruncate(@intFromEnum(fd), @intCast(size_bytes))) != .SUCCESS)
                return error.FtruncateFailed;

            const buffer_id = rs.next_buffer_id.increment();
            try wl.buffer_create_and_register_cpu(
                ws,
                rs,
                buffer_id,
                fd,
                size,
                format,
            );

            return .{
                .handle = fd,
                .buffer_id = buffer_id,
            };
        },
        .win32 => |tag| {
            tag.guard();
            const handle_ptr = win32_memory.CreateFileMappingA(
                win32_foundation.INVALID_HANDLE_VALUE,
                null,
                win32_memory.PAGE_READWRITE,
                0,
                @intCast(size_bytes),
                null,
            ) orelse return error.FailedToCreateFileMapping;
            errdefer _ = win32_foundation.CloseHandle(handle_ptr);

            const pixels = win32_memory.MapViewOfFile(
                handle_ptr,
                win32_memory.FILE_MAP_READ,
                0,
                0,
                @intCast(size_bytes),
            ) orelse return error.FailedToMapViewOfFile;

            const handle: ptypes.CpuBufferHandle = .from_HANDLE(handle_ptr);

            const buffer_id = rs.next_buffer_id.increment();
            rs.buffers.putAssumeCapacity(buffer_id, .{ .cpu = .{
                .handle = handle,
                .pixels = pixels,
                .format = format,
                .size = size,
            } });

            return .{
                .handle = handle,
                .buffer_id = buffer_id,
            };
        },
    }
}

fn buffer_create_gbm_bo(ws: *WindowSystem, args: Event.TypeOf(.buffer_create_gbm_bo)) !void {
    if (!constants.os_has_gbm) {
        return error.MessageUnsupportedByOS;
    }

    if (args.payload.size.width <= 0 or args.payload.size.height <= 0) return error.InvalidSize;

    const size = args.payload.size;

    var bo: ClientResources.GbmBo = try .init(
        ws.gbm,
        args.payload.size,
        args.payload.format,
    );
    errdefer bo.deinit(ws.gbm);

    const rs = ws.resources.getPtr(args.client_id).?;
    try rs.gbm_bos.ensureUnusedCapacity(ws.gpa, 1);

    switch (ws.linux) {
        .wayland => |wl| {
            const id = try wl.buffer_create_and_register_gpu_async(
                rs,
                ws,
                args.payload.viewport_id,
                &bo,
                size,
                args.payload.format,
            );

            rs.gbm_bos.putAssumeCapacityNoClobber(id, bo);
        },
    }
}

fn texture_create_d3d(ws: *WindowSystem, args: Event.TypeOf(.texture_create_d3d)) !void {
    std.debug.assert(args.payload.version == .d3d11);
    try ws.handles_to_close.ensureUnusedCapacity(ws.gpa, 3);

    const win32 = switch (ws.native_tag()) {
        .win32 => |tag| tag.window_system(ws),
        else => return error.MessageUnsupportedByOS,
    };

    if (args.payload.size.width <= 0 or args.payload.size.height <= 0) return error.InvalidSize;

    const rs = ws.resources.getPtr(args.client_id).?;
    try rs.buffers.ensureUnusedCapacity(ws.gpa, 1);

    var desc: d11.D3D11_TEXTURE2D_DESC = .{
        .Width = @intCast(args.payload.size.width),
        .Height = @intCast(args.payload.size.height),
        .MipLevels = 1,
        .ArraySize = 1,
        .Format = Win32.buffer_format_to_dxgi_format(args.payload.format),
        .SampleDesc = .{ .Count = 1, .Quality = 0 },
        .Usage = .DEFAULT,
        .BindFlags = .{ .SHADER_RESOURCE = 1, .RENDER_TARGET = 1 },
        .CPUAccessFlags = .{},
        .MiscFlags = .{
            .SHARED = 1,
            .SHARED_NTHANDLE = 1,
        },
    };

    const texture = try win32.d11_context.create_texture_2d(&desc);
    errdefer _ = texture.IUnknown.Release();

    const acquire = try win32.d11_context.create_shared_fence_acquire();
    errdefer _ = acquire.acquire.IUnknown.Release();

    const release = try win32.d11_context.create_shared_fence_release();
    errdefer _ = release.release.IUnknown.Release();

    const acquire_shared_handle = try acquire.create_shared_handle();
    ws.handles_to_close.appendAssumeCapacity(.{ .windows_handle = acquire_shared_handle.to_HANDLE() });

    const release_shared_handle = try release.create_shared_handle();
    ws.handles_to_close.appendAssumeCapacity(.{ .windows_handle = release_shared_handle.to_HANDLE() });

    const texture_shared_handle = win32.d11_context.shared_handle_from_texture_2d(texture);
    ws.handles_to_close.appendAssumeCapacity(.{ .windows_handle = texture_shared_handle.to_HANDLE() });

    const buffer_id = rs.next_buffer_id.increment();

    rs.buffers.putAssumeCapacityNoClobber(buffer_id, .{
        .d11 = .{
            .texture = texture,
            .acquire = acquire,
            .release = release,
            .format = args.payload.format,
        },
    });

    ws.server_events.appendAssumeCapacity(.{
        .texture_created_d3d = .{
            .client_id = args.client_id,
            .payload = .{
                .viewport_id = args.payload.viewport_id,
                .buffer_id = buffer_id,
                .texture_handle = texture_shared_handle,
                .acquire_fence_handle = acquire_shared_handle,
                .release_fence_handle = release_shared_handle,
                .size = args.payload.size,
                .format = args.payload.format,
                .version = .d3d11,
            },
        },
    });
}

const BufferQueuePresent = union(enum) {
    no_sync: Event.TypeOf(.buffer_present),
    sync: Event.TypeOf(.buffer_present_with_sync),
};

fn present_queue_push(ws: *WindowSystem, args: BufferQueuePresent) !void {
    try ws.present_queue.ensureUnusedCapacity(ws.gpa, 1);

    const client_id, const viewport_id, const render_size, const buffer_id = switch (args) {
        inline else => |v| .{
            v.client_id,             v.payload.viewport_id,
            v.payload.viewport_size, v.payload.buffer_id,
        },
    };

    const viewport_key: ViewportKey = .{ .client_id = client_id, .viewport_id = viewport_id };
    const vp = ws.viewport_from_key(viewport_key) orelse {
        log.err("Viewport does not exist {f} {f}", .{ viewport_key.client_id, viewport_key.viewport_id });
        return;
    };

    const win = ws.window_from_viewport_key(viewport_key) orelse return error.ViewportHasNoWindow;

    const rs = ws.resources.getPtr(client_id) orelse return;

    vp.render_size = render_size;
    if (vp.parent_key == null) {
        vp.clipping_rect = .{
            .x = 0,
            .y = 0,
            .width = render_size.width,
            .height = render_size.height,
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

    if (buffer.format() != vp.format) {
        return error.BufferAndViewportFormatMismatch;
    }

    ws.present_queue.appendAssumeCapacity(.init(
        client_id,
        viewport_id,
        buffer_id,
        win.id,
        render_size,

        switch (args) {
            .no_sync => null,
            .sync => |sync| .{
                .acquire_point = sync.payload.acquire_point,
                .release_point = sync.payload.release_point,
            },
        },
    ));
}

pub fn present(ws: *WindowSystem) void {
    // FIXME: This could block forever on windows if we wait on a
    // timeline point that never gets signaled
    while (ws.present_queue.items.len > 0) {
        switch (ws.native_tag()) {
            inline else => |tag| {
                tag.window_system(ws).present(ws, tag);
            },
        }

        var i = ws.present_queue.items.len;
        while (i > 0) {
            i -= 1;
            if (ws.present_queue.items[i].state == .presented) {
                _ = ws.present_queue.orderedRemove(i);
            }
        }
    }
}

fn buffer_destroy(ws: *WindowSystem, args: Event.TypeOf(.buffer_destroy)) !void {
    const rs = ws.resources.getPtr(args.client_id) orelse return;
    rs.buffer_destroy(ws, args.payload.buffer_id);
}

pub fn viewport_create(ws: *WindowSystem, args: Event.TypeOf(.viewport_create)) !void {
    if (args.payload.size.width <= 0 or args.payload.size.height <= 0) {
        return error.InvalidSize;
    }

    const result: ViewportCreateResult = blk: {
        if (args.payload.viewport_id.is_server_id()) {
            break :blk try ws.viewport_create_with_sub_viewport(args);
        } else {
            const key = try ws.viewport_create_with_window(args);
            break :blk .{ .create_with_window = key };
        }
    };

    switch (result) {
        .create_with_window => |key| {
            ws.server_events.appendAssumeCapacity(.{
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
            ws.server_events.appendAssumeCapacity(.{
                .viewport_created = .{
                    .client_id = v.embeded.client_id,
                    .payload = .{
                        .viewport_id = v.embeded.viewport_id,
                        .status = .success,
                    },
                },
            });

            ws.server_events.appendAssumeCapacity(.{
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
        args.payload.format,
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
        args.payload.format,
    );

    ws.windows.putAssumeCapacityNoClobber(id, win);

    switch (ws.native_tag()) {
        .wayland => |tag| {
            const wl = tag.window_system(ws);
            win.linux.wayland.surface.commit();
            _ = wl.display.flush();
        },
        .win32 => |tag| {
            tag.guard();
        },
    }

    log.debug("{f} of {f} created", .{ args.payload.viewport_id, rs.client_id });

    return .{ .client_id = rs.client_id, .viewport_id = args.payload.viewport_id };
}

pub fn viewport_from_key(ws: *WindowSystem, key: ViewportKey) ?*Viewport {
    const rs = ws.resources.getPtr(key.client_id) orelse return null;
    const vp = rs.viewports.get(key.viewport_id) orelse return null;

    return vp;
}

pub fn window_from_viewport_key(ws: *WindowSystem, key: ViewportKey) ?*Window {
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

    switch (ws.native_tag()) {
        .wayland => |tag| {
            const wl = tag.window_system(ws);
            if (removed) {
                _ = wl.display.flush();
            }
        },
        .win32 => {},
    }
}

pub fn sub_viewport_pos_set(ws: *WindowSystem, args: Event.TypeOf(.sub_viewport_pos_set)) !void {
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

    switch (ws.native_tag()) {
        .wayland => |tag| {
            const wl = tag.window_system(ws);
            const nvp = tag.viewport(vp);
            if (set_position) {
                nvp.subsurface.set_position(
                    vp.clipping_rect.x,
                    vp.clipping_rect.y,
                );
            }

            _ = wl.display.flush();
        },
        .win32 => |tag| {
            const nvp = tag.viewport(vp);
            if (set_position) {
                _ = win32_win.SetWindowPos(
                    nvp.child_window_handle,
                    null,
                    vp.clipping_rect.x,
                    vp.clipping_rect.y,
                    0,
                    0,
                    .{ .NOZORDER = 1, .NOSIZE = 1, .NOACTIVATE = 1 },
                );
            }
        },
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

    switch (ws.native_tag()) {
        .wayland => |tag| {
            const wl = tag.window_system(ws);
            const nvp = tag.viewport(vp);
            const min_size = nvp.min_source_size(&win.linux.wayland);
            nvp.viewport.setSource(
                .fromInt(0),
                .fromInt(0),
                .fromInt(@intCast(min_size.width)),
                .fromInt(@intCast(min_size.height)),
            );
            nvp.surface.commit();
            _ = wl.display.flush();
        },
        .win32 => |tag| {
            const nvp = tag.viewport(vp);
            _ = win32_win.SetWindowPos(
                nvp.child_window_handle,
                null,
                0,
                0,
                vp.clipping_rect.width,
                vp.clipping_rect.height,
                .{ .NOZORDER = 1, .NOMOVE = 1, .NOACTIVATE = 1 },
            );
        },
    }

    ws.server_events.appendAssumeCapacity(.{
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

    const old = svp.state;
    svp.state = args.payload.state;

    if (svp.state == old) return;

    switch (ws.native_tag()) {
        .wayland => |tag| {
            const nvp = tag.viewport(svp);

            switch (svp.state) {
                .hidden => {
                    // TODO: If needed, attach a null buffer recursivly for all children
                    nvp.surface.attach(null, 0, 0);
                    nvp.surface.commit();
                },
                .shown => {
                    // TODO: Maybe, attach the last buffer to re-present the surface ?
                    // Or send an event asking for a redraw
                },
            }
        },
        .win32 => |tag| {
            const nsvp = tag.viewport(svp);
            const cmd = switch (svp.state) {
                .hidden => win32_win.SW_HIDE,
                .shown => win32_win.SW_SHOW,
            };

            _ = win32_win.ShowWindow(nsvp.child_window_handle, cmd);
        },
    }

    const parent_key = svp.parent_key.?;
    ws.server_events.appendAssumeCapacity(.{
        .sub_viewport_display_state = .{
            .client_id = parent_key.client_id,
            .payload = .{
                .sub_viewport_id = args.payload.sub_viewport_id,
                .state = args.payload.state,
            },
        },
    });

    ws.server_events.appendAssumeCapacity(.{
        .viewport_display_state = .{
            .client_id = svp_viewport_key.client_id,
            .payload = .{
                .viewport_id = svp_viewport_key.viewport_id,
                .state = args.payload.state,
            },
        },
    });
}

pub fn sub_viewport_close(ws: *WindowSystem, args: Event.TypeOf(.sub_viewport_close)) !void {
    const key = blk: {
        const rs = ws.resources.getPtr(args.client_id) orelse return;
        break :blk rs.viewport_key_from_sub_viewport_id(args.payload.sub_viewport_id) orelse
            return error.SubViewportDoesNotExist;
    };

    try ws.viewport_should_close(.{ .viewport_key = key });
}

pub fn window_resize_by_display_server(ws: *WindowSystem, args: Event.TypeOf(.window_resize_by_display_server)) !void {
    const win = ws.windows.get(args.id) orelse {
        return error.WindowDoesNotExist;
    };
    switch (ws.native_tag()) {
        .wayland => |tag| {
            const wl = tag.window_system(ws);
            try win.linux.wayland.resize(wl, args.size);
            win.linux.wayland.viewport_bound(ws);
            win.linux.wayland.commit();
            _ = wl.display.flush();
        },
        .win32 => {
            // It seems windows changes the window's buffer however it likes, unlike wayland.
        },
    }

    const rs = ws.resources.getPtr(win.viewport_key.client_id) orelse return;
    const vp = rs.viewports.get(win.viewport_key.viewport_id) orelse return;
    if (!std.meta.eql(vp.render_size, args.size)) {
        ws.server_events.appendAssumeCapacity(.{
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
    const viewport_key: ViewportKey = .{
        .client_id = args.client_id,
        .viewport_id = args.payload.viewport_id,
    };
    const vp = ws.viewport_from_key(viewport_key) orelse return;
    vp.cursor_shape = args.payload.shape;

    ws.cursor_shape_set_from_viewport(vp, viewport_key);
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

    ws.server_events.appendAssumeCapacity(.{
        .viewport_create = .{
            .client_id = args.payload.client_id_to_embed,
            .payload = .{
                .viewport_id = viewport_id,
                .size = args.payload.rect.size(),
            },
        },
    });
}

pub fn cursor_shape_set_from_viewport(ws: *WindowSystem, vp: *Viewport, viewport_key: ViewportKey) void {
    if (!std.meta.eql(ws.input_focus_mouse, viewport_key)) return;

    switch (ws.native_tag()) {
        .wayland => |tag| {
            const nvp = tag.viewport(vp);
            const shape = Wayland.from_protocol_cursor_shape(vp.cursor_shape);
            nvp.pointer.set_shape(shape orelse return);
        },
        .win32 => |tag| {
            tag.guard();
            if (vp.cursor_shape == .none) {
                _ = win32_win.SetCursor(null);
            } else {
                const name = Win32.from_protocol_cursor_shape(vp.cursor_shape);
                const hcursor = win32_win.LoadCursorW(null, name);

                _ = win32_win.SetCursor(hcursor orelse return);
            }
        },
    }
}

pub fn mouse_focus_set(ws: *WindowSystem, key: ViewportKey) void {
    if (std.meta.eql(ws.input_focus_mouse, key)) return;

    const vp = ws.viewport_from_key(key) orelse return;

    ws.input_focus_mouse = key;

    // TODO: Notify all viewports of this window that the mouse left
    ws.server_events.appendAssumeCapacity(.{
        .mouse_enter = .{
            .client_id = key.client_id,
            .payload = .{ .viewport_id = key.viewport_id },
        },
    });

    ws.cursor_shape_set_from_viewport(vp, key);
}

pub fn keyboard_focus_set(ws: *WindowSystem, key: ViewportKey) void {
    if (std.meta.eql(ws.input_focus_keyboard, key)) return;

    ws.input_focus_keyboard = key;

    // TODO: Notify all viewports of this window that the keyboard left
    switch (ws.native_tag()) {
        .wayland => {},
        .win32 => |tag| {
            // windows requires explict focusing to receive
            // keyboard events for child windows
            tag.guard();
            const vp = ws.viewport_from_key(key) orelse return;
            const nvp = tag.viewport(vp);
            _ = win32_kbm.SetFocus(nvp.child_window_handle);
        },
    }
}

pub fn keyboard_key(ws: *WindowSystem, args: Event.TypeOf(.keyboard_key)) !void {
    const key = ws.input_focus_keyboard orelse return;

    ws.server_events.appendAssumeCapacity(.{
        .keyboard_key = .{
            .client_id = key.client_id,
            .payload = .{
                .viewport_id = key.viewport_id,
                .key = args.key,
                .state = args.state,
                .modifiers = args.modifiers,
            },
        },
    });

    switch (ws.native_tag()) {
        .wayland => |tag| {
            const wl = tag.window_system(ws);
            if (wl.input_repeat_future) |*future| {
                future.cancel(wl.io);
            }

            wl.input_repeat_future = null;

            if (Wayland.process_char(args.char)) |char| {
                ws.server_events.appendAssumeCapacity(.{
                    .keyboard_char = .{
                        .client_id = key.client_id,
                        .payload = .{ .viewport_id = key.viewport_id, .char = char },
                    },
                });
            }
            const maybe_ms = switch (args.state) {
                .pressed => wl.input_delay_ms,
                .repeat => wl.input_rate_ms,
                .released => null,
            };

            if (maybe_ms) |ms| {
                wl.input_repeat_future = wl.io.concurrent(Wayland.input_repeat, .{
                    ws,
                    ms,
                    args.key,
                    args.modifiers,
                    args.char,
                }) catch |err| blk: {
                    log.err("Failed to start task input_repeat {}", .{err});
                    break :blk null;
                };
            }
        },
        .win32 => {},
    }
}

pub fn keyboard_enter(ws: *WindowSystem, args: Event.TypeOf(.keyboard_enter)) !void {
    ws.keyboard_focus_set(args.viewport_key);
}

pub fn keyboard_leave(ws: *WindowSystem, _: Event.TypeOf(.keyboard_leave)) !void {
    ws.input_focus_keyboard = null;
}

pub fn mouse_enter(ws: *WindowSystem, args: Event.TypeOf(.mouse_enter)) !void {
    ws.mouse_focus_set(args.viewport_key);
}

pub fn mouse_leave(ws: *WindowSystem, args: Event.TypeOf(.mouse_leave)) !void {
    ws.server_events.appendAssumeCapacity(.{
        .mouse_leave = .{
            .client_id = args.viewport_key.client_id,
            .payload = .{
                .viewport_id = args.viewport_key.viewport_id,
            },
        },
    });
}

pub fn mouse_motion(ws: *WindowSystem, args: Event.TypeOf(.mouse_motion)) !void {
    const key = ws.input_focus_mouse orelse return;

    ws.server_events.appendAssumeCapacity(.{
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

pub fn mouse_button(ws: *WindowSystem, args: Event.TypeOf(.mouse_button)) !void {
    const key = ws.input_focus_mouse orelse return;
    if (args.state == .pressed) {
        ws.keyboard_focus_set(key);
    }

    ws.server_events.appendAssumeCapacity(.{
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

pub fn mouse_scroll(ws: *WindowSystem, args: Event.TypeOf(.mouse_scroll)) !void {
    const key = ws.input_focus_mouse orelse return;

    ws.server_events.appendAssumeCapacity(.{
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

pub const Gbm = if (!constants.os_has_gbm) void else struct {
    dri: Io.File,
    device: *c_linux.struct_gbm_device,

    pub fn syncobj_fd_from_handle(gbm: Gbm, syncobj: u32) c_int {
        var fd: c_int = undefined;
        const create_result = c_linux.drmSyncobjHandleToFD(gbm.dri.handle, syncobj, &fd);
        std.debug.assert(create_result == 0);
        std.debug.assert(fd >= 0);
        return fd;
    }
};

pub const Event = union(enum) {
    buffer_create_cpu: client_to_server.WithClientID(client_to_server.BufferCreateCpu),
    buffer_create_gbm_bo: client_to_server.WithClientID(client_to_server.BufferCreateGbmBo),
    buffer_present: client_to_server.WithClientID(client_to_server.BufferPresent),
    buffer_present_with_sync: client_to_server.WithClientID(client_to_server.BufferPresentWithSync),
    buffer_destroy: client_to_server.WithClientID(client_to_server.BufferDestroy),

    texture_create_d3d: client_to_server.WithClientID(client_to_server.TextureCreateD3D),

    viewport_create: client_to_server.WithClientID(client_to_server.ViewportCreate),
    viewport_destroy: client_to_server.WithClientID(client_to_server.ViewportDestroy),
    viewport_should_close: ViewportShouldClose,

    sub_viewport_embed: client_to_server.WithClientID(client_to_server.SubViewportEmbed),
    sub_viewport_pos_set: client_to_server.WithClientID(client_to_server.SubViewportPosSet),
    sub_viewport_size_set: client_to_server.WithClientID(client_to_server.SubViewportSizeSet),
    sub_viewport_display_state_set: client_to_server.WithClientID(client_to_server.SubViewportDisplayStateSet),
    sub_viewport_close: client_to_server.WithClientID(client_to_server.SubViewportClose),

    window_resize_by_display_server: WindowResize,

    cursor_shape_set: client_to_server.WithClientID(client_to_server.CursorShape),

    keyboard_key: KeyboardKey,
    keyboard_enter: KeyboardEnter,
    keyboard_leave: KeyboardLeave,

    mouse_enter: MouseEnter,
    mouse_leave: MouseLeave,
    mouse_motion: MouseMotion,
    mouse_button: MouseButton,
    mouse_scroll: MouseScroll,

    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .wayland_dispatch => |_, tag| {
                try writer.print("{s}", .{@tagName(tag)});
            },
            inline else => |v, tag| {
                try utils.format_active_union_field(v, @tagName(tag), writer);
            },
        }
    }

    pub const ClientRegistered = struct {
        client_id: ClientID,
    };

    pub const WindowResize = struct {
        id: WindowID,
        size: ptypes.Size,
    };

    pub fn TypeOf(comptime tag: std.meta.Tag(Event)) type {
        return utils.TypeOfField(Event, @tagName(tag));
    }

    pub const KeyboardChar = struct {
        char: u32,
    };

    pub const KeyboardKey = struct {
        key: pinput.Key,
        state: pinput.KeyState,
        modifiers: pinput.Modifiers,
        char: ?u32,
    };

    pub const ViewportShouldClose = struct {
        viewport_key: ViewportKey,
    };

    pub const KeyboardEnter = struct {
        viewport_key: ViewportKey,
    };

    pub const KeyboardLeave = struct {
        viewport_key: ViewportKey,
    };

    pub const MouseEnter = struct {
        viewport_key: ViewportKey,
    };

    pub const MouseLeave = struct {
        viewport_key: ViewportKey,
    };

    pub const MouseMotion = struct {
        x: f32,
        y: f32,
    };

    pub const MouseButton = struct {
        button: pinput.MouseButton,
        state: pinput.MouseState,
    };

    pub const MouseScroll = struct {
        axis: ptypes.ScrollAxis,
        value: f32,
    };
};

pub const NativeTag = enum {
    wayland,
    win32,

    /// Prevents compile errors of other platforms
    pub fn guard(
        comptime tag: NativeTag,
    ) if (tag.os_matches_tag()) void else noreturn {
        switch (tag) {
            .wayland => if (os != .linux) unreachable,
            .win32 => if (os != .windows) unreachable,
        }
    }

    pub fn window_system(
        comptime tag: NativeTag,
        ws: *WindowSystem,
    ) if (tag.os_matches_tag()) *window_system_type(tag) else noreturn {
        tag.guard();
        return switch (tag) {
            .wayland => ws.linux.wayland,
            .win32 => ws.win32,
        };
    }

    pub fn window(
        comptime tag: NativeTag,
        win: *Window,
    ) if (tag.os_matches_tag()) *window_type(tag) else noreturn {
        tag.guard();
        return switch (tag) {
            .wayland => &win.linux.wayland,
            .win32 => &win.win32,
        };
    }

    pub fn viewport(
        comptime tag: NativeTag,
        vp: *Viewport,
    ) if (tag.os_matches_tag()) *viewport_type(tag) else noreturn {
        tag.guard();
        return switch (tag) {
            .wayland => &vp.linux.wayland,
            .win32 => &vp.win32,
        };
    }

    fn window_system_type(comptime tag: NativeTag) type {
        return switch (tag) {
            .wayland => Wayland,
            .win32 => Win32,
        };
    }

    fn window_type(comptime tag: NativeTag) type {
        return switch (tag) {
            .wayland => Wayland.Window,
            .win32 => Win32.Window,
        };
    }

    fn viewport_type(comptime tag: NativeTag) type {
        return switch (tag) {
            .wayland => Wayland.Viewport,
            .win32 => Win32.Viewport,
        };
    }

    fn os_matches_tag(comptime tag: NativeTag) bool {
        return switch (tag) {
            .wayland => os == .linux,
            .win32 => os == .windows,
        };
    }
};

pub const HandleToClose = union(enum) {
    windows_handle: *anyopaque,
    fd: std.posix.fd_t,

    pub fn close(handle: HandleToClose) void {
        switch (handle) {
            .windows_handle => |h| {
                if (os == .windows) {
                    _ = win32_foundation.CloseHandle(h);
                }
            },
            .fd => |fd| {
                if (os == .linux) {
                    _ = std.os.linux.close(fd);
                }
            },
        }
    }
};

pub const BufferPresent = struct {
    client_id: ClientID,
    viewport_id: ViewportID,
    buffer_id: BufferID,
    window_id: WindowID,
    render_size: ptypes.Size,
    sync: ?Sync,
    state: State,

    pub fn init(
        client_id: ClientID,
        viewport_id: ViewportID,
        buffer_id: BufferID,
        window_id: WindowID,
        render_size: ptypes.Size,
        sync: ?Sync,
    ) BufferPresent {
        return .{
            .client_id = client_id,
            .viewport_id = viewport_id,
            .buffer_id = buffer_id,
            .window_id = window_id,
            .render_size = render_size,
            .sync = sync,

            .state = .new,
        };
    }

    const Sync = struct {
        acquire_point: ptypes.AcquireTimelinePoint,
        release_point: ptypes.ReleaseTimelinePoint,
    };

    const State = enum {
        new,
        ready_to_copy,
        ready_to_present,
        presented,

        pub fn advance(s: *State) void {
            s.* = switch (s.*) {
                .new => .ready_to_copy,
                .ready_to_copy => .ready_to_present,
                .ready_to_present => .presented,
                .presented => unreachable,
            };
        }
    };
};

pub const Linux = union(enum) { wayland: *Wayland };

pub const Wayland = @import("wayland/Wayland.zig");
pub const Win32 = @import("win32/Win32.zig");
pub const Viewport = @import("window_system/Viewport.zig");
pub const Window = @import("window_system/Window.zig");

const std = @import("std");
const Io = std.Io;
const ClientID = ptypes.ClientID;
const ptypes = @import("protocol").types;
const ViewportID = ptypes.ViewportID;
const os = @import("builtin").os.tag;
const log = std.log.scoped(.WindowSystem);
const BufferID = ptypes.BufferID;
const ClientResources = @import("window_system/ClientResources.zig");
const win32_win = @import("win32").ui.windows_and_messaging;
const c_linux = @import("c_linux");
const constants = @import("constants");
const client_to_server = @import("protocol").client_to_server;
const utils = @import("utils");
const pinput = @import("protocol").input;
const ServerEvent = @import("server/Server.zig").Event;
const win32_memory = @import("win32").system.memory;
const win32_foundation = @import("win32").foundation;
const win32_gdi = @import("win32").graphics.gdi;
const win32_kbm = @import("win32").ui.input.keyboard_and_mouse;
const d11 = @import("win32").graphics.direct3d11;
const d3d = @import("win32").graphics.direct3d;
const dxgi = @import("win32").graphics.dxgi;
