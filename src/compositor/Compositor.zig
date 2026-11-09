const Compositor = @This();

io: Io,
gpa: std.mem.Allocator,
tick_arena: std.heap.ArenaAllocator,

server: *Server,
muxi: MuxInterface,

class_of_window: [:0]const u8,
/// Used in windows
class_of_viewport: [:0]const u8,

/// Used in windows to prevent accesing freed data in callbacks
destroy_started: bool,

resources: std.array_hash_map.Auto(ClientUUID, ClientResources),

server_events: ServerQueue,
deferred_events: std.ArrayList(Event),

present_queue: std.ArrayList(BufferPresent),

gbm: Gbm,

win32: if (os == .windows) *Win32 else void,
linux: if (os == .linux) Linux else void,

input_focus_mouse: ?ViewportKey,
input_focus_keyboard: ?ViewportKey,

pub fn create_wayland(display: *cwl.Display, args: CreateArgs) !*Compositor {
    const com: *Compositor = try .create_undefined_native(args);

    const wl: *Wayland = try .create(args.io, args.gpa, display);
    com.linux = .{ .wayland = wl };

    try wl.set_listeners(com);

    return com;
}

pub fn create_win32(instance: Win32.HINSTANCE, args: CreateArgs) !*Compositor {
    const com: *Compositor = try .create_undefined_native(args);

    com.win32 = try .create(com, instance);

    return com;
}

pub const CreateArgs = struct {
    io: Io,
    gpa: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    class: []const u8,
    muxi: MuxInterface,
    socket_owner: Server.UnixSocketOwner,
};
fn create_undefined_native(args: CreateArgs) !*Compositor {
    const server = try Server.create(args.io, args.environ_map, args.gpa, args.socket_owner);
    errdefer server.destroy();

    const class_window_dupe = try args.gpa.dupeZ(u8, args.class);
    errdefer args.gpa.free(class_window_dupe);
    const class_viewport = try std.fmt.allocPrintSentinel(args.gpa, "{s}-viewport", .{class_window_dupe}, 0);
    errdefer args.gpa.free(class_viewport);

    const com = try args.gpa.create(Compositor);
    errdefer args.gpa.destroy(com);

    const gbm: Gbm = if (!constants.os_has_gbm) {} else blk: {
        std.debug.assert(os == .linux);

        const dri = try Io.Dir.openFileAbsolute(
            args.io,
            "/dev/dri/renderD128",
            .{ .mode = .read_write },
        );

        const device = c_linux.gbm_create_device(dri.handle) orelse
            return error.CouldNotCreateGbmDevice;

        break :blk .{ .dri = dri, .device = device };
    };

    com.* = .{
        .io = args.io,
        .gpa = args.gpa,
        .tick_arena = .init(args.gpa),
        .server = server,
        .muxi = args.muxi,
        .class_of_window = class_window_dupe,
        .class_of_viewport = class_viewport,
        .resources = .empty,
        .gbm = gbm,

        .destroy_started = false,

        .server_events = .init(args.gpa),
        .deferred_events = .empty,
        .present_queue = .empty,

        .input_focus_mouse = null,
        .input_focus_keyboard = null,

        .win32 = undefined,
        .linux = undefined,
    };

    return com;
}

pub fn destroy(com: *Compositor) void {
    com.destroy_started = true;

    for (com.resources.values()) |*rs| {
        rs.deinit(com);
    }

    switch (com.native_tag()) {
        .wayland => |tag| {
            const wl = tag.compositor(com);
            wl.destroy();
        },
        .win32 => |tag| {
            const w = tag.compositor(com);
            w.destroy();
        },
    }

    com.server_events.deinit();

    inline for (.{
        &com.resources,
        &com.deferred_events,
        &com.present_queue,
    }) |entry| {
        entry.deinit(com.gpa);
    }

    com.gpa.free(com.class_of_window);
    com.gpa.free(com.class_of_viewport);

    com.server.destroy();

    com.tick_arena.deinit();
    com.gpa.destroy(com);
}

pub fn native_tag(com: *const Compositor) NativeTag {
    return switch (os) {
        .linux => switch (com.linux) {
            .wayland => .wayland,
        },
        .windows => .win32,
        else => comptime unreachable,
    };
}

pub fn dispatch(com: *Compositor) void {
    switch (com.native_tag()) {
        .wayland => |tag| {
            const wl: *Wayland = tag.compositor(com);
            const display = wl.display;
            const queue = wl.event_queue;

            if (display.dispatchQueuePending(queue) != .SUCCESS) {
                std.process.fatal("Dispatch failed {}", .{wl.display.getError()});
            }
        },
        .win32 => |tag| {
            tag.guard();

            // We assume that we run on our own thread, owning the thread window event queue
            var msg: win32_win.MSG = undefined;
            while (win32_win.PeekMessageA(&msg, null, 0, 0, win32_win.PM_REMOVE) > 0) {
                _ = win32_win.TranslateMessage(&msg);
                _ = win32_win.DispatchMessageA(&msg);
            }
        },
    }
}

pub fn flush(com: *Compositor, events: []const Compositor.Event) void {
    switch (com.native_tag()) {
        .wayland => |tag| {
            const wl = tag.compositor(com);
            const should_flush = blk: for (events) |event| {
                if (wl.should_flush(event)) break :blk true;
            } else false;

            if (should_flush) {
                _ = wl.display.flush();
            }
        },
        else => {},
    }
}

pub fn events_handle(com: *Compositor, events: []const Event) void {
    for (events) |e| {
        com.event_handle(e) catch |err| {
            log.err("event_handle {}", .{err});
        };
    }
}

pub fn event_handle(com: *Compositor, event: Event) !void {
    switch (event) {
        .buffer_create_cpu => |args| try com.buffer_create_cpu(args),
        .buffer_create_gbm_bo => |args| try com.buffer_create_gbm_bo(args),

        .buffer_present => |args| try com.present_queue_push(.{ .no_sync = args }),
        .buffer_present_with_sync => |args| try com.present_queue_push(.{ .sync = args }),

        .buffer_destroy => |args| try com.buffer_destroy(args),

        .texture_create_d3d => |args| try com.texture_create_d3d(args),

        .viewport_create => |args| try com.viewport_create(args),
        .viewport_destroy => |args| com.viewport_destroy(args.client_uuid.viewport_key(args.payload.viewport_id)),
        .viewport_should_close => |args| try com.viewport_should_close(args),
        .viewport_pos_set => |args| try com.viewport_pos_set(args),
        .viewport_size_set => |args| try com.viewport_size_set(args),
        .viewport_display_state_set => |args| try com.viewport_display_state_set(args),
        .viewport_close => |args| try com.viewport_close(args),

        .remote_viewport_embed => |args| try com.remote_viewport_embed_with_viewport(args),
        .remote_viewport_embed_with_window => |args| try com.remote_viewport_embed_with_window(args),

        .cursor_shape_set => |args| try com.cursor_shape_set(args),

        .keyboard_enter => |args| try com.keyboard_enter(args),
        .keyboard_key => |args| try com.keyboard_key(args),
        .mouse_enter => |args| try com.mouse_enter(args),
        .mouse_leave => |args| try com.mouse_leave(args),
        .mouse_motion => |args| try com.mouse_motion(args),
        .mouse_button => |args| try com.mouse_button(args),
        .mouse_scroll => |args| try com.mouse_scroll(args),
    }
}

pub fn client_registered(com: *Compositor, client_uuid: ClientUUID) !void {
    try com.resources.putNoClobber(com.gpa, client_uuid, .init(client_uuid));
}

pub fn client_disconnected(com: *Compositor, uuid: ClientUUID) void {
    const rs = com.resources.getPtr(uuid) orelse {
        log.warn("Tried to disconnected an nonexistent client {}", .{uuid});
        return;
    };

    var i = rs.viewports.count();
    while (i > 0) {
        i -= 1;
        const id = rs.viewports.keys()[i];
        com.viewport_destroy(rs.client_uuid.viewport_key(id));
    }

    rs.deinit(com);
    _ = com.resources.orderedRemove(uuid);
}

fn viewport_destroy(com: *Compositor, key: ViewportKey) void {
    const rs = com.resources.getPtr(key.client_uuid) orelse return;
    const vp = rs.viewports.get(key.viewport_id) orelse return;

    const has_keyboard_focus = std.meta.eql(com.input_focus_keyboard, key);
    const has_mouse_focus = std.meta.eql(com.input_focus_mouse, key);

    const old_capacity = com.server_events.capacity;
    vp.memory_reserve_for_destroy.release(com);
    std.debug.assert(
        com.server_events.capacity ==
            old_capacity + Viewport.MemoryReserveForDestroy.server_events_len,
    );

    if (has_keyboard_focus) {
        com.keyboard_focus_switch_assume_capacity(vp.parent_key);
    }

    if (has_mouse_focus) {
        com.mouse_focus_switch_assume_capacity(vp.parent_key);
    }

    if (vp.parent_key) |parent_key| {
        const parent = com.viewport_from_key(parent_key).?;
        parent.remote_viewport_remove(key);

        com.server_events.push_assume_capacity(.{
            .remote_viewport_closed = .{
                .client_uuid = parent_key.client_uuid,
                .payload = .{ .viewport_key = key },
            },
        });

        vp.parent_key = null;
    }

    for (vp.remote_viewports.items) |rvp_key| {
        const rvp = com.viewport_from_key(rvp_key).?;
        rvp.parent_key = null;
    }
    vp.remote_viewports.clearRetainingCapacity();

    _ = rs.viewports.orderedRemove(vp.id);
    vp.destroy(com.gpa);

    log.debug("{f} of {f} destroyed", .{ key.viewport_id, key.client_uuid });
}

fn viewport_should_close(com: *Compositor, args: @FieldType(Event, "viewport_should_close")) !void {
    try com.server_events.ensure_unused_capacity(1);
    com.server_events.push_assume_capacity(.{
        .viewport_close = .{
            .client_uuid = args.viewport_key.client_uuid,
            .payload = .{ .viewport_id = args.viewport_key.viewport_id },
        },
    });
}

fn buffer_create_cpu(com: *Compositor, args: @FieldType(Event, "buffer_create_cpu")) !void {
    try com.server_events.ensure_unused_capacity(1);
    const rs = com.resources.getPtr(args.client_uuid).?;

    const buffer = try com.buffer_create_cpu_inner(
        rs,
        args.payload.size,
        args.payload.format,
    );

    com.server_events.push_assume_capacity(.{
        .buffer_created_cpu = .{
            .client_uuid = args.client_uuid,
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

fn buffer_create_cpu_inner(com: *Compositor, rs: *ClientResources, size: ptypes.Size, format: ptypes.BufferFormat) !BufferCreateCpu {
    try rs.buffers.ensureUnusedCapacity(com.gpa, 1);

    const size_bytes = size.width * size.height * format.bytes_per_pixel();

    switch (com.native_tag()) {
        .wayland => |tag| {
            const wl = tag.compositor(com);
            const fd: ptypes.CpuBufferHandle = @enumFromInt(try std.posix.memfd_create("agce-buffer", 0));
            errdefer fd.close();

            if (std.posix.errno(std.posix.system.ftruncate(@intFromEnum(fd), @intCast(size_bytes))) != .SUCCESS)
                return error.FtruncateFailed;

            const buffer_id = rs.next_buffer_id.increment();
            try wl.buffer_create_and_register_cpu(
                com,
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
            const handle: ptypes.CpuBufferHandle = .from_HANDLE(win32_memory.CreateFileMappingA(
                win32_foundation.INVALID_HANDLE_VALUE,
                null,
                win32_memory.PAGE_READWRITE,
                0,
                @intCast(size_bytes),
                null,
            ) orelse return error.FailedToCreateFileMapping);
            errdefer handle.close();

            var bitmap_info: win32_gdi.BITMAPINFO = undefined;
            bitmap_info.bmiHeader.biSize = @sizeOf(win32_gdi.BITMAPINFOHEADER);
            bitmap_info.bmiHeader.biWidth = size.width;
            bitmap_info.bmiHeader.biHeight = -size.height;
            bitmap_info.bmiHeader.biPlanes = 1;

            switch (format) {
                .argb8888 => {
                    bitmap_info.bmiHeader.biBitCount = 32;
                    bitmap_info.bmiHeader.biCompression = win32_gdi.BI_RGB;
                },
            }

            var pixels: *anyopaque = undefined;

            const bitmap = win32_gdi.CreateDIBSection(
                null,
                &bitmap_info,
                win32_gdi.DIB_RGB_COLORS,
                @ptrCast(&pixels),
                handle.to_HANDLE(),
                0,
            ) orelse return error.FailedToCreateDIBSection;
            errdefer _ = win32_gdi.DeleteObject(bitmap);

            const hdc = win32_gdi.CreateCompatibleDC(null);
            errdefer _ = win32_gdi.DeleteDC(hdc);

            if (win32_gdi.SelectObject(hdc, bitmap) == null) {
                return error.FailedToSelectObject;
            }

            const buffer_id = rs.next_buffer_id.increment();
            rs.buffers.putAssumeCapacity(buffer_id, .init_win32(.{
                .cpu = .{
                    .handle = handle,
                    .hdc = hdc,
                    .bitmap = bitmap,
                    .pixels = pixels,
                    .format = format,
                    .size = size,
                },
            }));

            return .{
                .handle = handle,
                .buffer_id = buffer_id,
            };
        },
    }
}

fn buffer_create_gbm_bo(com: *Compositor, args: @FieldType(Event, "buffer_create_gbm_bo")) !void {
    if (!constants.os_has_gbm) {
        return error.MessageUnsupportedByOS;
    }

    if (args.payload.size.width <= 0 or args.payload.size.height <= 0) return error.InvalidSize;

    const size = args.payload.size;

    var bo: ClientResources.GbmBo = try .init(
        com.gbm,
        args.payload.size,
        args.payload.format,
    );
    errdefer bo.deinit(com.gbm);

    const rs = com.resources.getPtr(args.client_uuid).?;
    try rs.gbm_bos.ensureUnusedCapacity(com.gpa, 1);

    switch (com.linux) {
        .wayland => |wl| {
            const id = try wl.buffer_create_and_register_gpu_async(
                rs,
                com,
                args.payload.viewport_id,
                &bo,
                size,
                args.payload.format,
            );

            rs.gbm_bos.putAssumeCapacityNoClobber(id, bo);
        },
    }
}

fn texture_create_d3d(com: *Compositor, args: @FieldType(Event, "texture_create_d3d")) !void {
    std.debug.assert(args.payload.version == .d3d11);
    try com.server_events.ensure_unused_capacity(1);

    const win32 = switch (com.native_tag()) {
        .win32 => |tag| tag.compositor(com),
        else => return error.MessageUnsupportedByOS,
    };

    if (args.payload.size.width <= 0 or args.payload.size.height <= 0) return error.InvalidSize;

    const rs = com.resources.getPtr(args.client_uuid).?;
    try rs.buffers.ensureUnusedCapacity(com.gpa, 1);

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
    errdefer acquire_shared_handle.close();

    const release_shared_handle = try release.create_shared_handle();

    errdefer comptime unreachable;

    const texture_shared_handle = win32.d11_context.shared_handle_from_texture_2d(texture);

    const buffer_id = rs.next_buffer_id.increment();

    rs.buffers.putAssumeCapacityNoClobber(buffer_id, .init_win32(.{
        .d11 = .{
            .texture = texture,
            .acquire = acquire,
            .release = release,
            .format = args.payload.format,
        },
    }));

    com.server_events.push_assume_capacity(.{
        .texture_created_d3d = .{
            .client_uuid = args.client_uuid,
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
    no_sync: @FieldType(Event, "buffer_present"),
    sync: @FieldType(Event, "buffer_present_with_sync"),
};

fn present_queue_push(com: *Compositor, args: BufferQueuePresent) !void {
    try com.present_queue.ensureUnusedCapacity(com.gpa, 1);

    const client_uuid, const viewport_id, const render_size, const buffer_id = switch (args) {
        inline else => |v| .{
            v.client_uuid,           v.payload.viewport_id,
            v.payload.viewport_size, v.payload.buffer_id,
        },
    };

    const viewport_key: ViewportKey = .{ .client_uuid = client_uuid, .viewport_id = viewport_id };
    const vp = com.viewport_from_key(viewport_key) orelse {
        log.err("Viewport does not exist {f} {f}", .{ viewport_key.client_uuid, viewport_key.viewport_id });
        return;
    };

    const rs = com.resources.getPtr(client_uuid) orelse return;
    const window_size = com.muxi.window_size(vp.window_id) orelse return;

    vp.render_size = render_size;
    if (vp.parent_key == null) {
        vp.clipping_rect = .{
            .x = 0,
            .y = 0,
            .width = render_size.width,
            .height = render_size.height,
        };
    }

    const buffer = rs.buffers.getPtr(buffer_id) orelse {
        if (rs.wl_buffers_pending.contains(buffer_id)) {
            log.warn("Buffer is pending {} for {}", .{ buffer_id, client_uuid });
        } else {
            log.err("Buffer does not exist {} for {}", .{ buffer_id, client_uuid });
        }
        return;
    };

    if (buffer.format() != vp.format) {
        return error.BufferAndViewportFormatMismatch;
    }

    com.present_queue.appendAssumeCapacity(.init(
        client_uuid,
        viewport_id,
        buffer_id,
        window_size,
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

pub fn present(com: *Compositor) !void {
    try com.server_events.ensure_unused_capacity(com.present_queue.items.len);

    // FIXME: This could block forever on windows if we wait on a
    // timeline point that never gets signaled
    while (com.present_queue.items.len > 0) {
        switch (com.native_tag()) {
            inline else => |tag| {
                tag.compositor(com).present(com, tag);
            },
        }

        var i = com.present_queue.items.len;
        while (i > 0) {
            i -= 1;
            if (com.present_queue.items[i].state == .presented) {
                _ = com.present_queue.orderedRemove(i);
            }
        }
    }
}

fn buffer_destroy(com: *Compositor, args: @FieldType(Event, "buffer_destroy")) !void {
    const rs = com.resources.getPtr(args.client_uuid) orelse return;
    rs.buffer_destroy(com, args.payload.buffer_id);
}

pub fn viewport_create(com: *Compositor, args: @FieldType(Event, "viewport_create")) !void {
    if (args.payload.size.width <= 0 or args.payload.size.height <= 0) {
        return error.InvalidSize;
    }

    var reserve: Viewport.MemoryReserveForDestroy = try .init(com);
    errdefer reserve.release(com);
    try com.server_events.ensure_unused_capacity(2);

    const result: ViewportCreateResult = blk: {
        if (args.payload.viewport_id.is_server_id()) {
            break :blk try com.viewport_create_with_remote_viewport(reserve, args);
        } else {
            const key = try com.viewport_create_with_mux_window(reserve, args);
            break :blk .{ .create_with_window = key };
        }
    };

    switch (result) {
        .create_with_window => |key| {
            com.server_events.push_assume_capacity(.{
                .viewport_created = .{
                    .client_uuid = key.client_uuid,
                    .payload = .{
                        .viewport_id = key.viewport_id,
                        .status = .success,
                    },
                },
            });
        },
        .create_with_remote_viewport => |v| {
            com.server_events.push_assume_capacity(.{
                .viewport_created = .{
                    .client_uuid = v.embedded.client_uuid,
                    .payload = .{
                        .viewport_id = v.embedded.viewport_id,
                        .status = .success,
                    },
                },
            });

            com.server_events.push_assume_capacity(.{
                .remote_viewport_embedded = .{
                    .client_uuid = v.embeder.key.client_uuid,
                    .payload = .{
                        .remote_viewport_id = v.embeder.key.remote_viewport_id,
                        .status = .success,
                        .render_size = v.embeder.render_size,
                        .viewport_key = v.embedded,
                    },
                },
            });
        },
    }
}

fn viewport_create_with_remote_viewport(
    com: *Compositor,
    reserve: Viewport.MemoryReserveForDestroy,
    args: @FieldType(Event, "viewport_create"),
) !Compositor.ViewportCreateResult {
    const embedded_key = args.client_uuid.viewport_key(args.payload.viewport_id);

    std.debug.assert(embedded_key.viewport_id.is_server_id());

    const embedded = com.resources.getPtr(embedded_key.client_uuid) orelse return error.ClientDoesNotExist;
    std.debug.assert(
        embedded.viewports_pending.orderedRemove(embedded_key.viewport_id),
    );

    const embeder = try com.resources_of_embeder_get(embedded_key);
    const remote_viewport_data =
        embeder.remote_viewports_pending_fetch_remove_by_embedded_key(embedded_key) orelse
        return error.RemoteViewportDoesNotExist;

    switch (remote_viewport_data.embed_in) {
        .viewport => |id| {
            const embeder_viewport = embeder.viewports.get(id) orelse
                return error.ViewportDoesNotExist;

            try embeder_viewport.remote_viewports.ensureUnusedCapacity(com.gpa, 1);

            try embedded.viewport_create(.{
                .com = com,
                .parent = .{ .viewport = embeder_viewport },
                .key = embedded_key,
                .window_id = embeder_viewport.window_id,
                .clipping_rect = remote_viewport_data.clip_rect,
                .render_size = args.payload.size,
                .parent_key = .{ .client_uuid = embeder.client_uuid, .viewport_id = embeder_viewport.id },
                .format = args.payload.format,
                .buffer_type = args.payload.buffer_type,
                .reserve = reserve,
            });

            embeder_viewport.remote_viewports.appendAssumeCapacity(embedded_key);
        },
        .window => |id| {
            const window_handle = com.muxi.window_handle_from_id(id) orelse
                return error.WindowDoesNotExist;

            try embedded.viewport_create(.{
                .com = com,
                .parent = .{ .window = window_handle },
                .key = embedded_key,
                .window_id = id,
                .clipping_rect = remote_viewport_data.clip_rect,
                .render_size = args.payload.size,
                .parent_key = null,
                .format = args.payload.format,
                .buffer_type = args.payload.buffer_type,
                .reserve = reserve,
            });
        },
    }

    log.info("{f} of {f} {f} created with {f} {f}", .{
        remote_viewport_data.remote_viewport_id,
        embeder.client_uuid,
        remote_viewport_data.embed_in,
        embedded_key.client_uuid,
        embedded_key.viewport_id,
    });

    return .{
        .create_with_remote_viewport = .{
            .embeder = .{
                .key = .{
                    .client_uuid = embeder.client_uuid,
                    .remote_viewport_id = remote_viewport_data.remote_viewport_id,
                },
                .render_size = args.payload.size,
            },

            .embedded = embedded_key,
        },
    };
}

fn viewport_create_with_mux_window(
    com: *Compositor,
    reserve: Viewport.MemoryReserveForDestroy,
    args: @FieldType(Event, "viewport_create"),
) !ViewportKey {
    std.debug.assert(!args.payload.viewport_id.is_server_id());

    const key: ViewportKey = .{
        .client_uuid = args.client_uuid,
        .viewport_id = args.payload.viewport_id,
    };
    const window_handle = com.muxi.window_handle_for_viewport(key, args.payload.size) orelse return error.FailedToGetWindowHandle;
    const window_id = com.muxi.window_id_from_handle(window_handle) orelse return error.FailedToGetWindowID;

    const rs = com.resources.getPtr(args.client_uuid) orelse return error.ClientDoesNotExist;

    try rs.viewport_create(.{
        .com = com,
        .parent = .{ .window = window_handle },
        .key = key,
        .window_id = window_id,
        .clipping_rect = .{
            .x = 0,
            .y = 0,
            .width = args.payload.size.width,
            .height = args.payload.size.height,
        },
        .render_size = args.payload.size,
        .parent_key = null,
        .format = args.payload.format,
        .buffer_type = args.payload.buffer_type,
        .reserve = reserve,
    });

    log.debug("{f} of {f} created", .{ args.payload.viewport_id, rs.client_uuid });

    return .{ .client_uuid = rs.client_uuid, .viewport_id = args.payload.viewport_id };
}

pub fn viewport_from_key(com: *Compositor, key: ViewportKey) ?*Viewport {
    const rs = com.resources.getPtr(key.client_uuid) orelse return null;
    const vp = rs.viewports.get(key.viewport_id) orelse return null;

    return vp;
}

pub fn remote_viewport_from_key(com: *Compositor, key: ViewportKey, parent_client_uuid: ClientUUID) !*Viewport {
    const rs = com.resources.getPtr(key.client_uuid) orelse return error.ClientDoesNotExist;
    const vp = rs.viewports.get(key.viewport_id) orelse return error.ViewportDoesNotExist;

    const real_parent = if (vp.parent_key) |p| p.client_uuid else com.muxi.uuid();

    if (real_parent != parent_client_uuid) {
        return error.ClientDoesNotOwnViewport;
    }

    return vp;
}

pub fn resources_of_embeder_get(com: *Compositor, to_embed: ViewportKey) error{EmbederClientDoesNotExist}!*ClientResources {
    for (com.resources.values()) |*rs| {
        if (rs.client_uuid == to_embed.client_uuid) continue;

        for (rs.remote_viewports_pending.values()) |remote| {
            if (std.meta.eql(to_embed, remote.to_embed)) {
                return rs;
            }
        }
    }

    return error.EmbederClientDoesNotExist;
}

pub fn viewport_pos_set(com: *Compositor, args: @FieldType(Event, "viewport_pos_set")) !void {
    std.debug.assert(args.payload.viewport_key.client_uuid != args.client_uuid);

    const vp = try com.remote_viewport_from_key(args.payload.viewport_key, args.client_uuid);

    std.debug.assert(vp.id.is_server_id());

    const pos = args.payload.pos;

    if (pos.x < 0 or pos.y < 0) {
        return error.InvalidPosition;
    }

    const set_position = pos.x != vp.clipping_rect.x or pos.y != vp.clipping_rect.y;
    vp.clipping_rect.x = pos.x;
    vp.clipping_rect.y = pos.y;

    switch (com.native_tag()) {
        .wayland => |tag| {
            const nvp = tag.viewport(vp);
            if (set_position) {
                nvp.subsurface.set_position(
                    vp.clipping_rect.x,
                    vp.clipping_rect.y,
                );
            }
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

pub fn viewport_size_set(com: *Compositor, args: @FieldType(Event, "viewport_size_set")) !void {
    std.debug.assert(args.payload.viewport_key.client_uuid != args.client_uuid);
    try com.server_events.ensure_unused_capacity(1);

    const key = args.payload.viewport_key;
    const vp = try com.remote_viewport_from_key(key, args.client_uuid);

    std.debug.assert(vp.id.is_server_id());

    const size = args.payload.size;
    const window_size = com.muxi.window_size(vp.window_id) orelse return error.ViewportHasNoWindow;

    if (size.width <= 0 or size.height <= 0) {
        return error.InvalidSize;
    }

    vp.clipping_rect.width = size.width;
    vp.clipping_rect.height = size.height;

    switch (com.native_tag()) {
        .wayland => |tag| {
            const nvp = tag.viewport(vp);
            const min_size = nvp.min_source_size(window_size);
            nvp.viewport.setSource(
                .fromInt(0),
                .fromInt(0),
                .fromInt(@intCast(min_size.width)),
                .fromInt(@intCast(min_size.height)),
            );
            nvp.surface.commit();
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

    com.server_events.push_assume_capacity(.{
        .viewport_resize = .{
            .client_uuid = key.client_uuid,
            .payload = .{
                .viewport_id = key.viewport_id,
                .size = vp.clipping_rect.size(),
            },
        },
    });
}

pub fn viewport_display_state_set(com: *Compositor, args: @FieldType(Event, "viewport_display_state_set")) !void {
    std.debug.assert(args.payload.viewport_key.client_uuid != args.client_uuid);
    try com.server_events.ensure_unused_capacity(2);

    const key = args.payload.viewport_key;
    const vp = try com.remote_viewport_from_key(key, args.client_uuid);

    std.debug.assert(vp.id.is_server_id());

    const old = vp.state;
    vp.state = args.payload.state;

    if (vp.state == old) return;

    switch (com.native_tag()) {
        .wayland => |tag| {
            const nvp = tag.viewport(vp);

            switch (vp.state) {
                .hidden => {
                    // NOTE: If needed, attach a null buffer recursivly for all children
                    nvp.surface.attach(null, 0, 0);
                    nvp.surface.commit();
                },
                .shown => {
                    // NOTE: Maybe, attach the last buffer to re-present the surface ?
                    // Or send an event asking for a redraw
                },
            }
        },
        .win32 => |tag| {
            const nrvp = tag.viewport(vp);
            const cmd = switch (vp.state) {
                .hidden => win32_win.SW_HIDE,
                .shown => win32_win.SW_SHOW,
            };

            _ = win32_win.ShowWindow(nrvp.child_window_handle, cmd);
        },
    }

    {
        const parent_uuid = if (vp.parent_key) |k| k.client_uuid else com.muxi.uuid();

        com.server_events.push_assume_capacity(.{
            .remote_viewport_display_state = .{
                .client_uuid = parent_uuid,
                .payload = .{
                    .viewport_key = args.payload.viewport_key,
                    .state = args.payload.state,
                },
            },
        });
    }

    com.server_events.push_assume_capacity(.{
        .viewport_display_state = .{
            .client_uuid = key.client_uuid,
            .payload = .{
                .viewport_id = key.viewport_id,
                .state = args.payload.state,
            },
        },
    });
}

pub fn viewport_close(com: *Compositor, args: @FieldType(Event, "viewport_close")) !void {
    std.debug.assert(args.payload.viewport_key.client_uuid != args.client_uuid);

    // validate the viewport exists and is owned by the client
    _ = try com.remote_viewport_from_key(args.payload.viewport_key, args.client_uuid);

    try com.viewport_should_close(.{ .viewport_key = args.payload.viewport_key });
}

pub fn cursor_shape_set(com: *Compositor, args: @FieldType(Event, "cursor_shape_set")) !void {
    const viewport_key: ViewportKey = .{
        .client_uuid = args.client_uuid,
        .viewport_id = args.payload.viewport_id,
    };
    const vp = com.viewport_from_key(viewport_key) orelse return;
    vp.cursor_shape = args.payload.shape;

    com.cursor_shape_set_from_viewport(vp, viewport_key);
}

pub fn remote_viewport_embed_with_viewport(com: *Compositor, args: @FieldType(Event, "remote_viewport_embed")) !void {
    try com.remote_viewport_embed(
        args.client_uuid,
        args.payload.remote_viewport_id,
        args.payload.rect,
        .{ .viewport = args.payload.embeder_viewport_id },
        args.payload.client_uuid_to_embed,
    );
}

pub fn remote_viewport_embed_with_window(
    com: *Compositor,
    args: @FieldType(Event, "remote_viewport_embed_with_window"),
) !void {
    try com.remote_viewport_embed(
        args.client_uuid,
        args.payload.remote_viewport_id,
        args.payload.rect,
        .{ .window = args.payload.window_id },
        args.payload.client_uuid_to_embed,
    );
}

pub fn remote_viewport_embed(
    com: *Compositor,
    request_from: ClientUUID,
    remote_viewport_id: ptypes.RemoteViewportID,
    rect: ptypes.Rect,
    parent: ClientResources.RemoteViewportPending.EmbedIn,
    request_to: ClientUUID,
) !void {
    try com.server_events.ensure_unused_capacity(1);

    const to_embed = com.resources.getPtr(request_to) orelse return;
    const embeder = com.resources.getPtr(request_from) orelse return;

    try embeder.remote_viewports_pending.ensureUnusedCapacity(com.gpa, 1);
    try to_embed.viewports_pending.ensureUnusedCapacity(com.gpa, 1);

    const viewport_id = to_embed.next_viewport_id.increment_for_server();
    to_embed.viewports_pending.putAssumeCapacityNoClobber(viewport_id, {});

    embeder.remote_viewports_pending.putAssumeCapacityNoClobber(
        remote_viewport_id,
        .{
            .to_embed = request_to.viewport_key(viewport_id),
            .clip_rect = rect,
            .embed_in = parent,
            .remote_viewport_id = remote_viewport_id,
        },
    );

    com.server_events.push_assume_capacity(.{
        .viewport_create = .{
            .client_uuid = request_to,
            .payload = .{ .viewport_id = viewport_id, .size = rect.size() },
        },
    });
}
pub fn cursor_shape_set_from_viewport(com: *Compositor, vp: *Viewport, viewport_key: ViewportKey) void {
    if (!std.meta.eql(com.input_focus_mouse, viewport_key)) return;

    switch (com.native_tag()) {
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

pub fn mouse_focus_switch_assume_capacity(com: *Compositor, maybe_key: ?ViewportKey) void {
    std.debug.assert(com.server_events.capacity >= 2);

    if (std.meta.eql(com.input_focus_mouse, maybe_key)) return;

    if (com.input_focus_mouse) |old| {
        com.server_events.push_assume_capacity(.{
            .mouse_leave = .{
                .client_uuid = old.client_uuid,
                .payload = .{
                    .viewport_id = old.viewport_id,
                },
            },
        });
    }

    com.input_focus_mouse = maybe_key;

    if (maybe_key) |key| {
        const vp = com.viewport_from_key(key) orelse return;
        com.server_events.push_assume_capacity(.{
            .mouse_enter = .{
                .client_uuid = key.client_uuid,
                .payload = .{ .viewport_id = key.viewport_id },
            },
        });

        com.cursor_shape_set_from_viewport(vp, key);
    }
}

pub fn keyboard_focus_switch_assume_capacity(com: *Compositor, maybe_key: ?ViewportKey) void {
    std.debug.assert(com.server_events.capacity >= 2);

    if (std.meta.eql(com.input_focus_keyboard, maybe_key)) return;

    if (com.input_focus_keyboard) |old| {
        com.server_events.push_assume_capacity(.{
            .keyboard_leave = .{
                .client_uuid = old.client_uuid,
                .payload = .{ .viewport_id = old.viewport_id },
            },
        });
    }

    com.input_focus_keyboard = maybe_key;

    if (maybe_key) |key| {
        com.server_events.push_assume_capacity(.{
            .keyboard_enter = .{
                .client_uuid = key.client_uuid,
                .payload = .{ .viewport_id = key.viewport_id },
            },
        });

        switch (com.native_tag()) {
            .wayland => {},
            .win32 => |tag| {
                // windows requires explict focusing to receive
                // keyboard events for child windows
                tag.guard();
                const vp = com.viewport_from_key(key) orelse return;
                const nvp = tag.viewport(vp);
                _ = win32_kbm.SetFocus(nvp.child_window_handle);
            },
        }
    }
}

pub fn keyboard_key(com: *Compositor, args: @FieldType(Event, "keyboard_key")) !void {
    try com.server_events.ensure_unused_capacity(2);

    const key = com.input_focus_keyboard orelse return;

    com.server_events.push_assume_capacity(.{
        .keyboard_key = .{
            .client_uuid = key.client_uuid,
            .payload = .{
                .viewport_id = key.viewport_id,
                .key = args.key,
                .state = args.state,
                .modifiers = args.modifiers,
            },
        },
    });

    switch (com.native_tag()) {
        .wayland => |tag| {
            const wl = tag.compositor(com);
            if (wl.input_repeat_future) |*future| {
                future.cancel(wl.io);
            }

            wl.input_repeat_future = null;

            if (Wayland.process_char(args.char)) |char| {
                com.server_events.push_assume_capacity(.{
                    .keyboard_char = .{
                        .client_uuid = key.client_uuid,
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
                    com,
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

pub fn keyboard_enter(com: *Compositor, args: @FieldType(Event, "keyboard_enter")) !void {
    try com.server_events.ensure_unused_capacity(2);
    com.keyboard_focus_switch_assume_capacity(args.viewport_key);
}

pub fn mouse_enter(com: *Compositor, args: @FieldType(Event, "mouse_enter")) !void {
    try com.server_events.ensure_unused_capacity(2);
    com.mouse_focus_switch_assume_capacity(args.viewport_key);
}

pub fn mouse_leave(com: *Compositor, args: @FieldType(Event, "mouse_leave")) !void {
    try com.server_events.ensure_unused_capacity(1);

    com.server_events.push_assume_capacity(.{
        .mouse_leave = .{
            .client_uuid = args.viewport_key.client_uuid,
            .payload = .{
                .viewport_id = args.viewport_key.viewport_id,
            },
        },
    });

    if (std.meta.eql(com.input_focus_mouse, args.viewport_key)) {
        com.input_focus_mouse = null;
    }
}

pub fn mouse_motion(com: *Compositor, args: @FieldType(Event, "mouse_motion")) !void {
    const key = com.input_focus_mouse orelse return;

    try com.server_events.ensure_unused_capacity(1);
    com.server_events.push_assume_capacity(.{
        .mouse_motion = .{
            .client_uuid = key.client_uuid,
            .payload = .{
                .viewport_id = key.viewport_id,
                .x = args.x,
                .y = args.y,
            },
        },
    });
}

pub fn mouse_button(com: *Compositor, args: @FieldType(Event, "mouse_button")) !void {
    try com.server_events.ensure_unused_capacity(3);

    const key = com.input_focus_mouse orelse return;
    if (args.state == .pressed) {
        com.keyboard_focus_switch_assume_capacity(key);
    }

    com.server_events.push_assume_capacity(.{
        .mouse_button = .{
            .client_uuid = key.client_uuid,
            .payload = .{
                .viewport_id = key.viewport_id,
                .button = args.button,
                .state = args.state,
            },
        },
    });
}

pub fn mouse_scroll(com: *Compositor, args: @FieldType(Event, "mouse_scroll")) !void {
    try com.server_events.ensure_unused_capacity(1);

    const key = com.input_focus_mouse orelse return;

    com.server_events.push_assume_capacity(.{
        .mouse_scroll = .{
            .client_uuid = key.client_uuid,
            .payload = .{
                .viewport_id = key.viewport_id,
                .axis = args.axis,
                .value = args.value,
            },
        },
    });
}

pub const RemoteViewportKey = struct {
    client_uuid: ClientUUID,
    remote_viewport_id: ptypes.RemoteViewportID,
};

pub const BufferKey = struct {
    client_uuid: ClientUUID,
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
    create_with_remote_viewport: struct {
        embeder: struct {
            key: RemoteViewportKey,
            render_size: ptypes.Size,
        },
        embedded: ViewportKey,
    },
};

pub const ParentOfViewport = union(enum) {
    window: *WindowHandle,
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
    buffer_create_cpu: WithClientUUID(client_to_server.BufferCreateCpu),
    buffer_create_gbm_bo: WithClientUUID(client_to_server.BufferCreateGbmBo),
    buffer_present: WithClientUUID(client_to_server.BufferPresent),
    buffer_present_with_sync: WithClientUUID(client_to_server.BufferPresentWithSync),
    buffer_destroy: WithClientUUID(client_to_server.BufferDestroy),

    texture_create_d3d: WithClientUUID(client_to_server.TextureCreateD3D),

    viewport_create: WithClientUUID(client_to_server.ViewportCreate),
    viewport_destroy: WithClientUUID(client_to_server.ViewportDestroy),
    viewport_should_close: ViewportShouldClose,
    viewport_pos_set: WithClientUUID(client_to_server.ViewportPosSet),

    remote_viewport_embed: WithClientUUID(client_to_server.RemoteViewportEmbed),
    remote_viewport_embed_with_window: WithClientUUID(RemoteViewportEmbedWithWindow),
    viewport_size_set: WithClientUUID(client_to_server.ViewportSizeSet),
    viewport_display_state_set: WithClientUUID(client_to_server.ViewportDisplayStateSet),
    viewport_close: WithClientUUID(client_to_server.RemoteViewportClose),

    cursor_shape_set: WithClientUUID(client_to_server.CursorShape),

    keyboard_key: KeyboardKey,
    keyboard_enter: KeyboardEnter,

    mouse_enter: MouseEnter,
    mouse_leave: MouseLeave,
    mouse_motion: MouseMotion,
    mouse_button: MouseButton,
    mouse_scroll: MouseScroll,

    const WithClientUUID = client_to_server.WithClientUUID;

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
        client_uuid: ClientUUID,
    };

    pub const RemoteViewportEmbedWithWindow = struct {
        client_uuid_to_embed: ptypes.ClientUUID,
        remote_viewport_id: ptypes.RemoteViewportID,
        rect: ptypes.Rect,
        window_id: WindowID,
    };

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

    pub fn compositor(
        comptime tag: NativeTag,
        com: *Compositor,
    ) if (tag.os_matches_tag()) *compositor_type(tag) else noreturn {
        tag.guard();
        return switch (tag) {
            .wayland => com.linux.wayland,
            .win32 => com.win32,
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

    pub fn buffer(
        comptime tag: NativeTag,
        b: *Buffer,
    ) if (tag.os_matches_tag()) *buffer_type(tag) else noreturn {
        tag.guard();
        return switch (tag) {
            .wayland => &b.native.wayland,
            .win32 => &b.native,
        };
    }

    fn compositor_type(comptime tag: NativeTag) type {
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

    fn buffer_type(comptime tag: NativeTag) type {
        return switch (tag) {
            .wayland => Wayland.Buffer,
            .win32 => Win32.Buffer,
        };
    }

    fn os_matches_tag(comptime tag: NativeTag) bool {
        return switch (tag) {
            .wayland => os == .linux,
            .win32 => os == .windows,
        };
    }
};

pub const BufferPresent = struct {
    client_uuid: ClientUUID,
    viewport_id: ViewportID,
    buffer_id: BufferID,
    render_size: ptypes.Size,
    window_size: ptypes.Size,
    sync: ?Sync,
    state: State,

    pub fn init(
        client_uuid: ClientUUID,
        viewport_id: ViewportID,
        buffer_id: BufferID,
        window_size: ptypes.Size,
        render_size: ptypes.Size,
        sync: ?Sync,
    ) BufferPresent {
        return .{
            .client_uuid = client_uuid,
            .viewport_id = viewport_id,
            .buffer_id = buffer_id,
            .window_size = window_size,
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

pub const WindowHandle = opaque {
    pub fn cast(handle: *WindowHandle, comptime tag: NativeTag) Type(tag) {
        switch (tag) {
            .wayland => {
                comptime std.debug.assert(os == .linux);
                return @ptrCast(handle);
            },
            .win32 => {
                comptime std.debug.assert(os == .windows);
                return @ptrCast(handle);
            },
        }
    }

    fn Type(comptime tag: NativeTag) type {
        return switch (tag) {
            .wayland => *cwl.Surface,
            .win32 => win32_foundation.HWND,
        };
    }
};

pub const MuxInterface = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        window_handle_for_viewport: *const fn (*anyopaque, ViewportKey, ptypes.Size) ?*WindowHandle,
        window_id_from_handle: *const fn (*anyopaque, *WindowHandle) ?WindowID,
        window_handle_from_id: *const fn (*anyopaque, WindowID) ?*WindowHandle,
        window_size: *const fn (*anyopaque, WindowID) ?ptypes.Size,
        uuid: *const fn (*anyopaque) ClientUUID,
    };

    pub fn window_handle_for_viewport(self: MuxInterface, key: ViewportKey, size: ptypes.Size) ?*WindowHandle {
        return self.vtable.window_handle_for_viewport(self.ptr, key, size);
    }

    pub fn window_id_from_handle(self: MuxInterface, handle: *WindowHandle) ?WindowID {
        return self.vtable.window_id_from_handle(self.ptr, handle);
    }

    pub fn window_handle_from_id(self: MuxInterface, id: WindowID) ?*WindowHandle {
        return self.vtable.window_handle_from_id(self.ptr, id);
    }

    pub fn window_size(self: MuxInterface, id: WindowID) ?ptypes.Size {
        return self.vtable.window_size(self.ptr, id);
    }

    pub fn uuid(self: MuxInterface) ClientUUID {
        return self.vtable.uuid(self.ptr);
    }
};

pub const Linux = union(enum) { wayland: *Wayland };

pub const Wayland = @import("wayland/Wayland.zig");
pub const Win32 = @import("win32/Win32.zig");
pub const Viewport = @import("Viewport.zig");
pub const Buffer = @import("Buffer.zig");

const std = @import("std");
const Io = std.Io;
const ClientUUID = ptypes.ClientUUID;
const ptypes = @import("protocol").types;
const ViewportID = ptypes.ViewportID;
const os = @import("builtin").os.tag;
const log = std.log.scoped(.Compositor);
const BufferID = ptypes.BufferID;
const ClientResources = @import("ClientResources.zig");
const win32_win = @import("win32").ui.windows_and_messaging;
const c_linux = @import("c_linux");
const constants = @import("constants");
const client_to_server = @import("protocol").client_to_server;
const utils = @import("utils");
const pinput = @import("protocol").input;
const Server = @import("server/Server.zig");
const ServerEvent = @import("server/Server.zig").Event;
const win32_memory = @import("win32").system.memory;
const win32_foundation = @import("win32").foundation;
const win32_gdi = @import("win32").graphics.gdi;
const win32_kbm = @import("win32").ui.input.keyboard_and_mouse;
const d11 = @import("win32").graphics.direct3d11;
const d3d = @import("win32").graphics.direct3d;
const dxgi = @import("win32").graphics.dxgi;
const ServerQueue = @import("server/EventQueue.zig");
const cwl = @import("wayland").client.wl;
const ViewportKey = ptypes.ViewportKey;
