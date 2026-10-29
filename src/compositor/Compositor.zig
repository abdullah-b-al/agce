const Compositor = @This();

io: Io,
gpa: std.mem.Allocator,

server: *Server,
muxi: ?MuxInterface,

class_of_window: [:0]const u8,
/// Used in windows
class_of_viewport: [:0]const u8,

/// Used in windows to prevent accesing freed data in callbacks
destroy_started: bool,

resources: std.array_hash_map.Auto(ClientID, ClientResources),
windows: std.array_hash_map.Auto(WindowID, Window),

window_next_id: WindowID,

server_events: ServerQueue,
deferred_events: std.ArrayList(Event),
present_queue: std.ArrayList(BufferPresent),

gbm: Gbm,

win32: if (os == .windows) *Win32 else void,
linux: if (os == .linux) Linux else void,

input_focus_mouse: ?ViewportKey,
input_focus_keyboard: ?ViewportKey,

pub fn create(
    io: Io,
    gpa: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    class: []const u8,
) !*Compositor {
    return blk: switch (os) {
        .linux => {
            const display = try cwl.Display.connect(null);
            break :blk try .create_wayland(io, gpa, environ_map, display, class, null);
        },
        .windows => {
            const hinstance = @import("win32").system.library_loader.GetModuleHandleW(null).?;
            break :blk try .create_win32(
                io,
                gpa,
                environ_map,
                hinstance,
                class,
                null,
            );
        },
        else => @compileError("Unsupported OS"),
    };
}

pub fn create_wayland(
    io: Io,
    gpa: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    display: *cwl.Display,
    class: []const u8,
    muxi: ?MuxInterface,
) !*Compositor {
    const com: *Compositor = try .create_undefined_native(
        io,
        gpa,
        environ_map,
        class,
        muxi,
    );

    const wl: *Wayland = try .create(io, gpa, display);
    com.linux = .{ .wayland = wl };

    try wl.set_listeners(com);

    return com;
}

pub fn create_win32(
    io: Io,
    gpa: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    instance: Win32.HINSTANCE,
    class: []const u8,
    muxi: ?MuxInterface,
) !*Compositor {
    const com: *Compositor = try .create_undefined_native(
        io,
        gpa,
        environ_map,
        class,
        muxi,
    );

    com.win32 = try .create(com, instance);

    return com;
}

fn create_undefined_native(
    io: Io,
    gpa: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    class: []const u8,
    muxi: ?MuxInterface,
) !*Compositor {
    const server = try Server.create(io, environ_map, gpa);
    errdefer server.destroy();

    const class_window_dupe = try gpa.dupeZ(u8, class);
    errdefer gpa.free(class_window_dupe);
    const class_viewport = try std.fmt.allocPrintSentinel(gpa, "{s}-viewport", .{class_window_dupe}, 0);
    errdefer gpa.free(class_viewport);

    const com = try gpa.create(Compositor);
    errdefer gpa.destroy(com);

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

    com.* = .{
        .io = io,
        .gpa = gpa,
        .server = server,
        .muxi = muxi,
        .class_of_window = class_window_dupe,
        .class_of_viewport = class_viewport,
        .resources = .empty,
        .windows = .empty,
        .gbm = gbm,

        .window_next_id = .first,
        .destroy_started = false,

        .server_events = .init(gpa),
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
        &com.windows,
        &com.deferred_events,
        &com.present_queue,
    }) |entry| {
        entry.deinit(com.gpa);
    }

    com.gpa.free(com.class_of_window);
    com.gpa.free(com.class_of_viewport);

    com.server.destroy();

    com.gpa.destroy(com);
}

pub fn window_register(com: *Compositor, win: Window) error{OutOfMemory}!void {
    try com.windows.ensureUnusedCapacity(com.gpa, 1);
    com.windows.putAssumeCapacityNoClobber(win.id, win);
}

pub fn window_update_size(com: *Compositor, id: WindowID, size: ptypes.Size) error{WindowNotRegistered}!void {
    const win = com.windows.getPtr(id) orelse return error.WindowNotRegistered;
    std.debug.assert(size.width > 0);
    std.debug.assert(size.height > 0);
    win.size = size;
}

pub fn window_focused_by_keyboard(com: *Compositor, viewport_key: ViewportKey) void {
    if (com.input_focus_keyboard == null) {
        com.keyboard_focus_set(viewport_key);
    }
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
            log.err("TODO: Dispatch events of viewports only", .{});
            // var msg: win32_win.MSG = undefined;

            // while (win32_win.PeekMessageA(&msg, null, 0, 0, win32_win.PM_REMOVE) > 0) {
            //     _ = win32_win.TranslateMessage(&msg);
            //     _ = win32_win.DispatchMessageA(&msg);
            // }
        },
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
        .viewport_destroy => |args| {
            try com.server_events.ensure_unused_capacity(1);
            com.viewport_destroy(.{ .client_id = args.client_id, .viewport_id = args.payload.viewport_id });
        },
        .viewport_should_close => |args| try com.viewport_should_close(args),

        .sub_viewport_embed => |args| try com.sub_viewport_embed(args),
        .sub_viewport_pos_set => |args| try com.sub_viewport_pos_set(args),
        .sub_viewport_size_set => |args| try com.sub_viewport_size_set(args),
        .sub_viewport_display_state_set => |args| try com.sub_viewport_display_state_set(args),
        .sub_viewport_close => |args| try com.sub_viewport_close(args),

        .cursor_shape_set => |args| try com.cursor_shape_set(args),

        .keyboard_key => |args| try com.keyboard_key(args),
        .keyboard_enter => |args| try com.keyboard_enter(args),
        .keyboard_leave => |args| try com.keyboard_leave(args),
        .mouse_enter => |args| try com.mouse_enter(args),
        .mouse_leave => |args| try com.mouse_leave(args),
        .mouse_motion => |args| try com.mouse_motion(args),
        .mouse_button => |args| try com.mouse_button(args),
        .mouse_scroll => |args| try com.mouse_scroll(args),
    }
}

pub fn client_registered(com: *Compositor, client_id: ClientID) !void {
    try com.resources.putNoClobber(com.gpa, client_id, .init(client_id));
}

pub fn client_disconnected(com: *Compositor, id: ClientID) void {
    const rs = com.resources.getPtr(id) orelse {
        log.warn("Tried to disconnected an nonexistent client {}", .{id});
        return;
    };

    var i = rs.viewports.count();
    while (i > 0) {
        i -= 1;
        const vp_id = rs.viewports.keys()[i];
        com.viewport_destroy(.{ .client_id = rs.client_id, .viewport_id = vp_id });
    }

    rs.deinit(com);
    _ = com.resources.orderedRemove(id);
}

fn viewport_destroy(com: *Compositor, key: ViewportKey) void {
    std.debug.assert(com.server_events.capacity >= 2);

    const rs = com.resources.getPtr(key.client_id) orelse return;
    const vp = rs.viewports.get(key.viewport_id) orelse return;

    if (vp.parent_key) |parent| {
        const p = com.viewport_from_key(parent).?;

        const svp_id = p.sub_viewport_id_from_key(key).?;

        _ = p.sub_viewports.orderedRemove(svp_id);
        com.server_events.push_assume_capacity(.{
            .sub_viewport_closed = .{
                .client_id = parent.client_id,
                .payload = .{ .sub_viewport_id = svp_id },
            },
        });

        if (std.meta.eql(com.input_focus_keyboard, key)) {
            com.keyboard_focus_set(parent);
        }

        if (std.meta.eql(com.input_focus_mouse, key)) {
            com.mouse_focus_set_and_push_event(parent);
        }

        vp.parent_key = null;
    }

    for (vp.sub_viewports.values()) |svp_key| {
        const svp = com.viewport_from_key(svp_key).?;
        svp.parent_key = null;
    }
    vp.sub_viewports.clearRetainingCapacity();

    _ = rs.viewports.orderedRemove(vp.id);
    vp.destroy(com.gpa);

    log.debug("{f} of {f} destroyed", .{ key.viewport_id, key.client_id });
}

fn viewport_should_close(com: *Compositor, args: Event.TypeOf(.viewport_should_close)) !void {
    try com.server_events.ensure_unused_capacity(1);
    com.server_events.push_assume_capacity(.{
        .viewport_close = .{
            .client_id = args.viewport_key.client_id,
            .payload = .{ .viewport_id = args.viewport_key.viewport_id },
        },
    });
}

fn buffer_create_cpu(com: *Compositor, args: Event.TypeOf(.buffer_create_cpu)) !void {
    try com.server_events.ensure_unused_capacity(1);
    const rs = com.resources.getPtr(args.client_id).?;

    const buffer = try com.buffer_create_cpu_inner(
        rs,
        args.payload.size,
        args.payload.format,
    );

    com.server_events.push_assume_capacity(.{
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
            rs.buffers.putAssumeCapacity(buffer_id, .init_win32(.{ .cpu = .{
                .handle = handle,
                .pixels = pixels,
                .format = format,
                .size = size,
            } }));

            return .{
                .handle = handle,
                .buffer_id = buffer_id,
            };
        },
    }
}

fn buffer_create_gbm_bo(com: *Compositor, args: Event.TypeOf(.buffer_create_gbm_bo)) !void {
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

    const rs = com.resources.getPtr(args.client_id).?;
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

fn texture_create_d3d(com: *Compositor, args: Event.TypeOf(.texture_create_d3d)) !void {
    std.debug.assert(args.payload.version == .d3d11);
    try com.server_events.ensure_unused_capacity(1);

    const win32 = switch (com.native_tag()) {
        .win32 => |tag| tag.compositor(com),
        else => return error.MessageUnsupportedByOS,
    };

    if (args.payload.size.width <= 0 or args.payload.size.height <= 0) return error.InvalidSize;

    const rs = com.resources.getPtr(args.client_id).?;
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

fn present_queue_push(com: *Compositor, args: BufferQueuePresent) !void {
    try com.present_queue.ensureUnusedCapacity(com.gpa, 1);

    const client_id, const viewport_id, const render_size, const buffer_id = switch (args) {
        inline else => |v| .{
            v.client_id,             v.payload.viewport_id,
            v.payload.viewport_size, v.payload.buffer_id,
        },
    };

    const viewport_key: ViewportKey = .{ .client_id = client_id, .viewport_id = viewport_id };
    const vp = com.viewport_from_key(viewport_key) orelse {
        log.err("Viewport does not exist {f} {f}", .{ viewport_key.client_id, viewport_key.viewport_id });
        return;
    };

    const win = com.window_from_viewport_key(viewport_key) orelse return error.ViewportHasNoWindow;

    const rs = com.resources.getPtr(client_id) orelse return;

    vp.render_size = render_size;
    if (vp.parent_key == null) {
        vp.clipping_rect = .{
            .x = 0,
            .y = 0,
            .width = render_size.width,
            .height = render_size.height,
        };
    }

    try rs.buffers_commited.ensureUnusedCapacity(com.gpa, 1);
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

    com.present_queue.appendAssumeCapacity(.init(
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

fn buffer_destroy(com: *Compositor, args: Event.TypeOf(.buffer_destroy)) !void {
    const rs = com.resources.getPtr(args.client_id) orelse return;
    rs.buffer_destroy(com, args.payload.buffer_id);
}

pub fn viewport_create(com: *Compositor, args: Event.TypeOf(.viewport_create)) !void {
    if (args.payload.size.width <= 0 or args.payload.size.height <= 0) {
        return error.InvalidSize;
    }

    try com.server_events.ensure_unused_capacity(2);

    const result: ViewportCreateResult = blk: {
        if (args.payload.viewport_id.is_server_id()) {
            break :blk try com.viewport_create_with_sub_viewport(args);
        } else {
            const key = try com.viewport_create_with_window(args);
            break :blk .{ .create_with_window = key };
        }
    };

    switch (result) {
        .create_with_window => |key| {
            com.server_events.push_assume_capacity(.{
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
            com.server_events.push_assume_capacity(.{
                .viewport_created = .{
                    .client_id = v.embeded.client_id,
                    .payload = .{
                        .viewport_id = v.embeded.viewport_id,
                        .status = .success,
                    },
                },
            });

            com.server_events.push_assume_capacity(.{
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
    com: *Compositor,
    args: Event.TypeOf(.viewport_create),
) !Compositor.ViewportCreateResult {
    const embeded_key: ViewportKey = .{
        .client_id = args.client_id,
        .viewport_id = args.payload.viewport_id,
    };

    std.debug.assert(embeded_key.viewport_id.is_server_id());

    const embeded = com.resources.getPtr(embeded_key.client_id) orelse return error.ClientDoesNotExist;
    std.debug.assert(
        embeded.viewports_pending.orderedRemove(embeded_key.viewport_id),
    );

    const embeder = try com.resources_of_embeder_get(embeded_key);
    const sub_viewport_data =
        embeder.sub_viewports_pending_fetch_remove_by_embeded_key(embeded_key) orelse
        return error.SubViewportDoesNotExist;

    const embeder_viewport = embeder.viewports.get(sub_viewport_data.embed_in) orelse
        return error.ViewportDoesNotExist;

    try embeder_viewport.sub_viewports.ensureUnusedCapacity(com.gpa, 1);

    try embeded.viewport_create(
        com,
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

pub fn window_id_from_handle(com: *Compositor, handle: *WindowHandle) ?WindowID {
    for (com.windows.values()) |win| {
        if (win.handle == handle) return win.id;
    }

    return null;
}

fn viewport_create_with_window(com: *Compositor, args: Event.TypeOf(.viewport_create)) !ViewportKey {
    std.debug.assert(!args.payload.viewport_id.is_server_id());

    const key: ViewportKey = .{
        .client_id = args.client_id,
        .viewport_id = args.payload.viewport_id,
    };
    const maybe_window_handle = if (com.muxi) |muxi|
        muxi.window_handle_for_viewport(key, args.payload.size)
    else
        null;
    const window_handle = maybe_window_handle orelse return error.FailedToGetWindow;

    const window_id = com.window_id_from_handle(window_handle).?;

    const rs = com.resources.getPtr(args.client_id) orelse return error.ClientDoesNotExist;

    try rs.viewport_create(
        com,
        .{ .window = window_handle },
        args.payload.viewport_id,
        window_id,
        .{ .x = 0, .y = 0, .width = args.payload.size.width, .height = args.payload.size.height },
        args.payload.size,
        args.payload.create_sync_timeline,
        null,
        args.payload.format,
    );

    log.debug("{f} of {f} created", .{ args.payload.viewport_id, rs.client_id });

    return .{ .client_id = rs.client_id, .viewport_id = args.payload.viewport_id };
}

pub fn viewport_from_key(com: *Compositor, key: ViewportKey) ?*Viewport {
    const rs = com.resources.getPtr(key.client_id) orelse return null;
    const vp = rs.viewports.get(key.viewport_id) orelse return null;

    return vp;
}

pub fn window_from_viewport_key(com: *Compositor, key: ViewportKey) ?Window {
    const rs = com.resources.getPtr(key.client_id).?;
    const vp = rs.viewports.get(key.viewport_id).?;
    return com.windows.get(vp.window_id);
}

pub fn resources_of_embeder_get(com: *Compositor, to_embed: ViewportKey) error{EmbederClientDoesNotExist}!*ClientResources {
    for (com.resources.values()) |*rs| {
        if (rs.client_id == to_embed.client_id) continue;

        for (rs.sub_viewports_pending.values()) |sub| {
            if (std.meta.eql(to_embed, sub.to_embed)) {
                return rs;
            }
        }
    }

    return error.EmbederClientDoesNotExist;
}

pub fn sub_viewport_pos_set(com: *Compositor, args: Event.TypeOf(.sub_viewport_pos_set)) !void {
    const key = blk: {
        const rs = com.resources.getPtr(args.client_id) orelse return;
        break :blk rs.viewport_key_from_sub_viewport_id(args.payload.sub_viewport_id) orelse
            return error.SubViewportDoesNotExist;
    };

    std.debug.assert(key.viewport_id.is_server_id());

    const pos = args.payload.pos;
    const rs = com.resources.getPtr(key.client_id) orelse return error.ClientDoesNotExist;
    const vp = rs.viewports.get(key.viewport_id) orelse return error.ViewportDoesNotExist;

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

pub fn sub_viewport_size_set(com: *Compositor, args: Event.TypeOf(.sub_viewport_size_set)) !void {
    try com.server_events.ensure_unused_capacity(1);

    const key = blk: {
        const rs = com.resources.getPtr(args.client_id) orelse return;
        break :blk rs.viewport_key_from_sub_viewport_id(args.payload.sub_viewport_id) orelse
            return error.SubViewportDoesNotExist;
    };

    std.debug.assert(key.viewport_id.is_server_id());

    const size = args.payload.size;
    const rs = com.resources.getPtr(key.client_id) orelse return error.ClientDoesNotExist;
    const vp = rs.viewports.get(key.viewport_id) orelse return error.ViewportDoesNotExist;
    const win = com.window_from_viewport_key(key) orelse return error.ViewportHasNoWindow;

    if (size.width <= 0 or size.height <= 0) {
        return error.InvalidSize;
    }

    vp.clipping_rect.width = size.width;
    vp.clipping_rect.height = size.height;

    switch (com.native_tag()) {
        .wayland => |tag| {
            const nvp = tag.viewport(vp);
            const min_size = nvp.min_source_size(win);
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
            .client_id = key.client_id,
            .payload = .{
                .viewport_id = key.viewport_id,
                .size = vp.clipping_rect.size(),
            },
        },
    });
}

pub fn sub_viewport_display_state_set(com: *Compositor, args: Event.TypeOf(.sub_viewport_display_state_set)) !void {
    try com.server_events.ensure_unused_capacity(2);

    const svp_viewport_key = blk: {
        const rs = com.resources.getPtr(args.client_id) orelse return;
        break :blk rs.viewport_key_from_sub_viewport_id(args.payload.sub_viewport_id) orelse
            return error.SubViewportDoesNotExist;
    };

    std.debug.assert(svp_viewport_key.viewport_id.is_server_id());

    const svp_rs = com.resources.getPtr(svp_viewport_key.client_id) orelse return;
    const svp = svp_rs.viewports.get(svp_viewport_key.viewport_id) orelse return error.ViewportDoesNotExist;

    const old = svp.state;
    svp.state = args.payload.state;

    if (svp.state == old) return;

    switch (com.native_tag()) {
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
    com.server_events.push_assume_capacity(.{
        .sub_viewport_display_state = .{
            .client_id = parent_key.client_id,
            .payload = .{
                .sub_viewport_id = args.payload.sub_viewport_id,
                .state = args.payload.state,
            },
        },
    });

    com.server_events.push_assume_capacity(.{
        .viewport_display_state = .{
            .client_id = svp_viewport_key.client_id,
            .payload = .{
                .viewport_id = svp_viewport_key.viewport_id,
                .state = args.payload.state,
            },
        },
    });
}

pub fn sub_viewport_close(com: *Compositor, args: Event.TypeOf(.sub_viewport_close)) !void {
    const key = blk: {
        const rs = com.resources.getPtr(args.client_id) orelse return;
        break :blk rs.viewport_key_from_sub_viewport_id(args.payload.sub_viewport_id) orelse
            return error.SubViewportDoesNotExist;
    };

    try com.viewport_should_close(.{ .viewport_key = key });
}

pub fn cursor_shape_set(com: *Compositor, args: Event.TypeOf(.cursor_shape_set)) !void {
    const viewport_key: ViewportKey = .{
        .client_id = args.client_id,
        .viewport_id = args.payload.viewport_id,
    };
    const vp = com.viewport_from_key(viewport_key) orelse return;
    vp.cursor_shape = args.payload.shape;

    com.cursor_shape_set_from_viewport(vp, viewport_key);
}

pub fn sub_viewport_embed(com: *Compositor, args: Event.TypeOf(.sub_viewport_embed)) !void {
    try com.server_events.ensure_unused_capacity(1);

    const to_embed = com.resources.getPtr(args.payload.client_id_to_embed) orelse return;
    const embeder = com.resources.getPtr(args.client_id) orelse return;

    try embeder.sub_viewports_pending.ensureUnusedCapacity(com.gpa, 1);
    try to_embed.viewports_pending.ensureUnusedCapacity(com.gpa, 1);

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

    com.server_events.push_assume_capacity(.{
        .viewport_create = .{
            .client_id = args.payload.client_id_to_embed,
            .payload = .{
                .viewport_id = viewport_id,
                .size = args.payload.rect.size(),
            },
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

pub fn mouse_focus_set_and_push_event(com: *Compositor, key: ViewportKey) void {
    std.debug.assert(com.server_events.capacity >= 1);

    if (std.meta.eql(com.input_focus_mouse, key)) return;

    const vp = com.viewport_from_key(key) orelse return;

    com.input_focus_mouse = key;

    // TODO: Notify all viewports of this window that the mouse left
    com.server_events.push_assume_capacity(.{
        .mouse_enter = .{
            .client_id = key.client_id,
            .payload = .{ .viewport_id = key.viewport_id },
        },
    });

    com.cursor_shape_set_from_viewport(vp, key);
}

pub fn keyboard_focus_set(com: *Compositor, key: ViewportKey) void {
    if (std.meta.eql(com.input_focus_keyboard, key)) return;

    com.input_focus_keyboard = key;

    // TODO: Notify all viewports of this window that the keyboard left
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

pub fn keyboard_key(com: *Compositor, args: Event.TypeOf(.keyboard_key)) !void {
    try com.server_events.ensure_unused_capacity(2);

    const key = com.input_focus_keyboard orelse return;

    com.server_events.push_assume_capacity(.{
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

pub fn keyboard_enter(com: *Compositor, args: Event.TypeOf(.keyboard_enter)) !void {
    com.keyboard_focus_set(args.viewport_key);
}

pub fn keyboard_leave(com: *Compositor, _: Event.TypeOf(.keyboard_leave)) !void {
    com.input_focus_keyboard = null;
}

pub fn mouse_enter(com: *Compositor, args: Event.TypeOf(.mouse_enter)) !void {
    try com.server_events.ensure_unused_capacity(1);
    com.mouse_focus_set_and_push_event(args.viewport_key);
}

pub fn mouse_leave(com: *Compositor, args: Event.TypeOf(.mouse_leave)) !void {
    try com.server_events.ensure_unused_capacity(1);
    com.server_events.push_assume_capacity(.{
        .mouse_leave = .{
            .client_id = args.viewport_key.client_id,
            .payload = .{
                .viewport_id = args.viewport_key.viewport_id,
            },
        },
    });
}

pub fn mouse_motion(com: *Compositor, args: Event.TypeOf(.mouse_motion)) !void {
    const key = com.input_focus_mouse orelse return;

    try com.server_events.ensure_unused_capacity(1);
    com.server_events.push_assume_capacity(.{
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

pub fn mouse_button(com: *Compositor, args: Event.TypeOf(.mouse_button)) !void {
    try com.server_events.ensure_unused_capacity(1);

    const key = com.input_focus_mouse orelse return;
    if (args.state == .pressed) {
        com.keyboard_focus_set(key);
    }

    com.server_events.push_assume_capacity(.{
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

pub fn mouse_scroll(com: *Compositor, args: Event.TypeOf(.mouse_scroll)) !void {
    try com.server_events.ensure_unused_capacity(1);

    const key = com.input_focus_mouse orelse return;

    com.server_events.push_assume_capacity(.{
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
    };

    pub fn window_handle_for_viewport(self: MuxInterface, key: ViewportKey, size: ptypes.Size) ?*WindowHandle {
        return self.vtable.window_handle_for_viewport(self.ptr, key, size);
    }
};

pub const Linux = union(enum) { wayland: *Wayland };

pub const Wayland = @import("wayland/Wayland.zig");
pub const Win32 = @import("win32/Win32.zig");
pub const Viewport = @import("Viewport.zig");
pub const Window = @import("Window.zig");
pub const Buffer = @import("Buffer.zig");

const std = @import("std");
const Io = std.Io;
const ClientID = ptypes.ClientID;
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
