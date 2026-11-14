const Client = @This();

io: Io,
gpa: std.mem.Allocator,
uuid: ptypes.ClientUUID,

environ_map: std.process.Environ.Map,
connection: ServerConnection,
registered: bool,

next_request_id: ptypes.RequestID,
next_viewport_id: ptypes.ViewportID,
next_remote_viewport_id: ptypes.RemoteViewportID,

viewports: std.array_hash_map.Auto(ViewportID, *Viewport),
viewports_from_server: std.array_hash_map.Auto(ViewportID, ptypes.Size),
remote_viewports: std.array_hash_map.Auto(RemoteViewportID, *RemoteViewport),

remote_clients: std.ArrayList(*RemoteClient),

messages_arena: std.heap.ArenaAllocator,

gbm: ?Gbm,
gl_context: ?opengl.ContextLinux,
d11_device: ?D11Device,

pending_viewports: std.array_hash_map.Auto(ptypes.RequestID, ViewportCreated),
pending_buffers_cpu: std.array_hash_map.Auto(ptypes.RequestID, BufferCreatedCpu),
pending_buffers_gbm_bo: std.array_hash_map.Auto(ptypes.RequestID, BufferCreatedGbmBo),
pending_textures_d3d: std.array_hash_map.Auto(ptypes.RequestID, TextureCreatedD3D),

env: Env,

read_future: Io.Future(void),
messages_queue: *MessagesQueue,

pub fn init(
    io: Io,
    gpa: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
) !Client {
    var map = try environ_map.clone(gpa);
    errdefer map.deinit();

    const env: Env = .extract(&map);

    const unix_path = if (environ_map.get(constants.env_agce_socket_path)) |path| blk: {
        break :blk try gpa.dupe(u8, path);
    } else blk: {
        const runtime_path = try known_folders.getPath(io, gpa, environ_map, .runtime) orelse
            return error.CouldNotGetRuntimeDirPath;
        defer gpa.free(runtime_path);

        break :blk try std.fs.path.join(gpa, &.{
            runtime_path,
            constants.socket_dir_name,
            constants.socket_mux_file_name,
        });
    };
    defer gpa.free(unix_path);

    const address = try net.UnixAddress.init(unix_path);

    const queues: *MessagesQueue = try .create(gpa);
    errdefer queues.destroy(gpa);

    const stream = try address.connect(io);

    const future = try io.concurrent(
        read_thread,
        .{ io, gpa, stream, queues },
    );

    return .{
        .io = io,
        .gpa = gpa,
        .uuid = env.client_uuid orelse .new(io),
        .environ_map = map,
        .connection = .{
            .format = .json,
            .stream = stream,
        },
        .messages_queue = queues,
        .registered = false,
        .messages_arena = .init(gpa),
        .next_request_id = .first,
        .next_viewport_id = .first_for_client,
        .next_remote_viewport_id = .first,
        .viewports = .empty,
        .viewports_from_server = .empty,
        .remote_viewports = .empty,
        .remote_clients = .empty,
        .gbm = null,
        .gl_context = null,
        .d11_device = null,

        .pending_viewports = .empty,
        .pending_buffers_cpu = .empty,
        .pending_buffers_gbm_bo = .empty,
        .pending_textures_d3d = .empty,

        .env = env,
        .read_future = future,
    };
}

pub fn deinit(client: *Client) void {
    client.read_future.cancel(client.io);

    for (client.remote_clients.items) |p| {
        client.gpa.destroy(p);
    }

    for (client.viewports.values()) |vp| {
        if (!vp.deinited) {
            vp.deinit();
            log.err("{f} leaked", .{vp.id});
        }
        client.gpa.destroy(vp);
    }

    for (client.remote_viewports.values()) |rvp| {
        if (!rvp.deinited) {
            rvp.deinit();
            log.err("{f} leaked", .{rvp.id});
        }
        client.gpa.destroy(rvp);
    }

    if (constants.os_has_gbm) {
        if (client.gbm) |gbm| {
            gbm.dri.close(client.io);
            c_linux.gbm_device_destroy(gbm.device);
        }
    }

    if (constants.os_has_d3d) {
        if (client.d11_device) |ctx| ctx.deinit();
    }

    const containers = .{
        &client.viewports,
        &client.remote_viewports,
        &client.viewports_from_server,
        &client.remote_clients,
        &client.pending_viewports,
        &client.pending_buffers_cpu,
        &client.pending_buffers_gbm_bo,
        &client.pending_textures_d3d,
    };

    inline for (containers) |container| {
        container.deinit(client.gpa);
    }

    client.messages_queue.destroy(client.gpa);
    client.environ_map.deinit();
    client.messages_arena.deinit();
    client.connection.stream.close(client.io);
}

pub fn init_gbm(client: *Client) !void {
    std.debug.assert(client.gbm == null);

    const dri = try Io.Dir.openFileAbsolute(
        client.io,
        "/dev/dri/renderD128",
        .{ .mode = .read_write },
    );

    const device = c_linux.gbm_create_device(dri.handle) orelse
        return error.CouldNotCreateGbmDevice;

    client.gbm = .{
        .dri = dri,
        .device = device,
    };
}

pub fn init_d3d11(client: *Client) !void {
    std.debug.assert(client.d11_device == null);
    if (!constants.os_has_d3d) {
        @panic("OS does not have d3d");
    }

    client.d11_device = try .init();
}

pub fn init_gl(client: *Client, major: c_int, minor: c_int) !void {
    std.debug.assert(client.gbm != null);
    const gbm = client.gbm.?;

    const gl = try opengl.init_linux(gbm.device, major, minor);
    try opengl.load_gl(gl);

    client.gl_context = gl;
}

pub fn poll(client: *Client, timeout: Io.Timeout) error{ Timeout, Canceled, OutOfMemory }!void {
    try client.messages_queue.messages_available.waitTimeout(client.io, timeout);
    client.messages_queue.messages_available.reset();

    try client.messages_queue.mutex.lock(client.io);
    defer client.messages_queue.mutex.unlock(client.io);

    const len = client.messages_queue.messages.items.len;

    try client.viewports_from_server.ensureUnusedCapacity(client.gpa, len);
    try client.pending_viewports.ensureUnusedCapacity(client.gpa, len);
    try client.pending_buffers_cpu.ensureUnusedCapacity(client.gpa, len);
    try client.pending_buffers_gbm_bo.ensureUnusedCapacity(client.gpa, len);
    try client.pending_textures_d3d.ensureUnusedCapacity(client.gpa, len);
    for (client.viewports.values()) |vp| {
        try vp.events.ensureUnusedCapacity(client.gpa, len);
    }

    while (client.messages_queue.messages.pop()) |message| {
        client.poll_process_message(message);
    }
}

fn poll_process_message(client: *Client, message: server_to_client.MessagePayload) void {
    switch (message) {
        .registered => {
            client.registered = true;
        },
        .client_registered => |e| {
            const remote: ?*RemoteClient = blk: for (client.remote_clients.items) |remote| {
                if (remote.uuid == e.client_uuid) break :blk remote;
            } else null;

            if (remote) |r| {
                r.connected();

                for (client.viewports.values()) |vp| {
                    vp.event_push(.wake_up);
                }
            }
        },
        .client_disconnected => |e| {
            for (client.remote_clients.items) |remote| {
                if (remote.uuid == e.client_uuid) {
                    remote.status = .disconnected;
                }
            }

            for (client.viewports.values()) |vp| {
                vp.event_push(.wake_up);
            }
        },
        .viewport_create => |e| {

            // TODO: Maybe these shouldn't trust the server and should error instead of asserting
            std.debug.assert(
                @intFromEnum(e.viewport_id) >= @intFromEnum(ViewportID.first_for_server),
            );
            client.viewports_from_server.putAssumeCapacityNoClobber(
                e.viewport_id,
                e.size,
            );
        },

        .remote_viewport_embedded => |e| {
            const rvp = client.remote_viewports.get(e.remote_viewport_id) orelse return;
            switch (e.status) {
                .success => {
                    if (client.viewports.get(rvp.parent)) |vp| {
                        vp.event_push(.{ .remote_viewport_embedded = rvp.id });
                    }
                    rvp.state = .{ .shown = e.viewport_key };
                },
                .failure => rvp.state = .failed,
            }
            rvp.render_size = e.render_size;
        },
        .remote_viewport_display_state => |e| {
            const rvp = blk: for (client.remote_viewports.values()) |rvp| {
                const key = switch (rvp.state) {
                    .shown, .hidden => |key| key,
                    .closed, .pending, .failed => continue,
                };

                if (std.meta.eql(key, e.viewport_key)) {
                    break :blk rvp;
                }
            } else return;

            const key = switch (rvp.state) {
                .shown, .hidden => |key| key,
                .closed, .failed, .pending => return,
            };
            rvp.state = .from_display_state(e.state, key);
        },
        .remote_viewport_closed => |e| {
            const rvp = blk: for (client.remote_viewports.values()) |rvp| {
                const key = switch (rvp.state) {
                    .shown, .hidden => |key| key,
                    .closed, .pending, .failed => continue,
                };

                if (std.meta.eql(key, e.viewport_key)) {
                    break :blk rvp;
                }
            } else return;

            rvp.state = .closed;

            if (client.viewports.get(rvp.parent)) |vp| {
                vp.event_push(.{ .remote_viewport_closed = rvp.id });
            }
        },
        .viewport_resize => |e| {
            const vp = client.viewports.get(e.viewport_id) orelse return;
            vp.event_push(.{ .viewport_resize = e });
        },
        .viewport_close => |e| {
            const vp = client.viewports.get(e.viewport_id) orelse return;
            vp.event_push(.{ .viewport_close = e });
        },
        .viewport_display_state => |e| {
            const vp = client.viewports.get(e.viewport_id) orelse return;
            vp.event_push(.wake_up);
        },

        inline .mouse_enter,
        .mouse_leave,
        .keyboard_enter,
        .keyboard_leave,
        .mouse_motion,
        .mouse_button,
        .mouse_scroll,
        .keyboard_key,
        .keyboard_char,
        => |e, tag| {
            const vp = client.viewports.get(e.viewport_id) orelse return;
            const event = @unionInit(Event, @tagName(tag), e);
            vp.event_push(event);
        },

        .buffer_created_cpu => |e| {
            client.pending_buffers_cpu.putAssumeCapacityNoClobber(e.request_id(), e);
        },
        .buffer_created_gbm_bo => |e| {
            client.pending_buffers_gbm_bo.putAssumeCapacityNoClobber(e.request_id(), e);
        },

        .texture_created_d3d => |e, tag| {
            if (!constants.os_has_d3d) {
                @panic("Received invalid message on os " ++ @tagName(tag));
            }
            client.pending_textures_d3d.putAssumeCapacityNoClobber(e.request_id(), e);
        },

        .viewport_created => |e| {
            client.pending_viewports.putAssumeCapacityNoClobber(e.request_id(), e);
        },

        .buffer_released => |e| {
            const vp = client.viewports.get(e.viewport_id) orelse return;
            switch (vp.renderer) {
                .d11 => {}, // relies on fences
                .gl => {}, // relies on timelines
                .cpu => {
                    const buffer = vp.buffers.cpu.getPtr(e.buffer_id) orelse return;
                    buffer.released = true;
                },
            }
        },

        .frame_render => |e| {
            const vp = client.viewports.get(e.viewport_id) orelse return;
            vp.refresh_cycle = e.refresh_cycle;
        },
    }
}

pub fn viewport_create(
    client: *Client,
    tag: Viewport.Renderer,
    parent_id: ?ptypes.ViewportID,
    rect: ptypes.Rect,
    throttle: bool,
) !*Viewport {
    const id = client.next_viewport_id.increment_for_client();

    const vp = switch (tag) {
        inline else => |t| try client.viewport_create_with_id(parent_id, t, id, rect, throttle),
    };

    return vp;
}

pub fn viewport_create_from_pending(
    client: *Client,
    tag: Viewport.Renderer,
    id: ViewportID,
    throttle: bool,
    size: ptypes.Size,
) !*Viewport {
    std.debug.assert(
        client.viewports_from_server.contains(id),
    );

    const vp = switch (tag) {
        inline else => |t| try client.viewport_create_with_id(
            null,
            t,
            id,
            .init(.{ .x = 0, .y = 0 }, size),
            throttle,
        ),
    };

    _ = client.viewports_from_server.orderedRemove(id);

    return vp;
}

pub fn viewport_create_with_id(
    client: *Client,
    parent_id: ?ptypes.ViewportID,
    comptime renderer: Viewport.Renderer,
    id: ViewportID,
    rect: ptypes.Rect,
    throttle: bool,
) !*Viewport {
    try client.viewports.ensureUnusedCapacity(client.gpa, 1);

    const vp = try client.gpa.create(Viewport);
    vp.* = .init(
        id,
        client,
        rect,
        .argb8888,
        throttle,
        renderer,
    );

    errdefer {
        vp.deinit();
        client.gpa.destroy(vp);
    }

    const buffer_type = vp.renderer.buffer_type();
    const width, const height = utils.new_dimensions(rect.width, rect.height);
    const buffer_size: ptypes.Size = .{ .width = width, .height = height };

    const viewport_rid = client.next_request_id.increment();
    const buffer_request_ids: []const ptypes.RequestID = &.{
        client.next_request_id.increment(),
        client.next_request_id.increment(),
    };

    try client.send_viewport_create(parent_id, viewport_rid, id, rect, vp.format, vp.renderer);
    try client.send_buffer_create(buffer_request_ids[0], vp.format, buffer_size, buffer_type);
    try client.send_buffer_create(buffer_request_ids[1], vp.format, buffer_size, buffer_type);

    while (true) {
        try client.poll(.none);

        // TODO: On failure destory buffers
        const maybe_failed = try client.buffers_create_from_pending_into(
            buffer_type,
            &vp.buffers,
            buffer_request_ids,
        );

        if (maybe_failed) |reason| {
            log.err("Failed to create buffer for viewport: error.{s}", .{reason.tag_name()});
            return error.ViewportCreateFailed;
        }

        const vp_status = client.pending_viewports.get(viewport_rid) orelse continue;

        switch (vp_status) {
            .success => {
                if (vp.buffers.count(vp.renderer) == buffer_request_ids.len) {
                    _ = client.pending_viewports.orderedRemove(viewport_rid);
                    break;
                }
            },
            .failure => |f| {
                log.err("Failed to create viewport: error.{s}", .{@tagName(f.reason)});
                return error.ViewportCreateFailed;
            },
        }
    }

    client.viewports.putAssumeCapacityNoClobber(vp.id, vp);
    return vp;
}

pub fn throttle_frames_if_enabled(client: *Client, vp: *Viewport) !void {
    if (!vp.throttle_frames) return;
    try throttle_frames(client, vp);
}

pub fn throttle_frames(client: *Client, vp: *Viewport) !void {
    std.debug.assert(vp.throttle_frames);

    while (vp.frame_number > vp.refresh_cycle) {
        try client.poll(.none);
    }
}

pub fn send_viewport_create(
    client: *Client,
    parent_id: ?ptypes.ViewportID,
    request_id: ptypes.RequestID,
    viewport_id: ViewportID,
    rect: ptypes.Rect,
    format: ptypes.BufferFormat,
    renderer: Viewport.Renderer,
) !void {
    std.debug.assert(!client.viewports.contains(viewport_id));
    std.debug.assert(parent_id != viewport_id);

    try client.connection.send_viewport_create(client.io, client.gpa, .{
        .parent_id = parent_id,
        .request_id = request_id,
        .viewport_id = viewport_id,
        .rect = rect,
        .format = format,
        .buffer_type = switch (renderer) {
            .cpu => .cpu,
            .gl => .gbm_bo,
            .d11 => .d11,
        },
    });
}

pub fn send_buffer_create(
    client: *Client,
    request_id: ptypes.RequestID,
    format: ptypes.BufferFormat,
    size: ptypes.Size,
    buffer_type: ptypes.BufferType,
) !void {
    switch (buffer_type) {
        .cpu => {
            try client.connection.send_buffer_create_cpu(
                client.io,
                client.gpa,
                .{
                    .request_id = request_id,
                    .format = format,
                    .size = size,
                },
            );
        },
        .gbm_bo => {
            if (!constants.os_has_gbm) @panic("OS does not support gbm");

            try client.connection.send_buffer_create_gbm_bo(
                client.io,
                client.gpa,
                .{
                    .request_id = request_id,
                    .format = format,
                    .size = size,
                },
            );
        },
        .d11 => {
            if (!constants.os_has_d3d) @panic("OS does not support d3d");

            try client.connection.send_texture_create_d3d(
                client.io,
                client.gpa,
                .{
                    .request_id = request_id,
                    .format = format,
                    .size = size,
                    .version = .d3d11,
                },
            );
        },
    }
}

const BuffersCreateRequestFailed = union(ptypes.BufferType) {
    cpu: BufferCreatedCpu.FailureReason,
    gbm_bo: BufferCreatedGbmBo.FailureReason,
    d11: TextureCreatedD3D.FailureReason,

    pub fn tag_name(u: @This()) [:0]const u8 {
        return switch (u) {
            inline else => |t| @tagName(t),
        };
    }
};

pub fn buffers_create_from_pending_into(
    client: *Client,
    buffer_type: ptypes.BufferType,
    buffers: *Buffers,
    request_ids_of_buffers: []const ptypes.RequestID,
) !?BuffersCreateRequestFailed {
    try buffers.cpu.ensureUnusedCapacity(client.gpa, request_ids_of_buffers.len);
    try buffers.gl_linux.ensureUnusedCapacity(client.gpa, request_ids_of_buffers.len);
    try buffers.d11.ensureUnusedCapacity(client.gpa, request_ids_of_buffers.len);

    switch (buffer_type) {
        inline else => |tag| {
            const Created = switch (tag) {
                .cpu => BufferCreatedCpu,
                .gbm_bo => BufferCreatedGbmBo,
                .d11 => TextureCreatedD3D,
            };

            const Buffer = switch (tag) {
                .cpu => Buffers.Cpu,
                .gbm_bo => Buffers.GlLinux,
                .d11 => Buffers.D11,
            };

            const from: *std.array_hash_map.Auto(ptypes.RequestID, Created) = switch (tag) {
                .cpu => &client.pending_buffers_cpu,
                .gbm_bo => &client.pending_buffers_gbm_bo,
                .d11 => &client.pending_textures_d3d,
            };

            const to = switch (tag) {
                .cpu => &buffers.cpu,
                .gbm_bo => &buffers.gl_linux,
                .d11 => &buffers.d11,
            };

            var i = from.count();
            while (i > 0) {
                i -= 1;
                const item = from.values()[i];
                for (request_ids_of_buffers) |rid| {
                    if (item.request_id() == rid) {
                        defer _ = from.orderedRemove(item.request_id());
                        switch (item) {
                            .success => |s| {
                                const buffer: Buffer = try .init(client, s);
                                to.putAssumeCapacityNoClobber(buffer.id, buffer);
                            },
                            .failure => |f| {
                                return @unionInit(
                                    BuffersCreateRequestFailed,
                                    @tagName(tag),
                                    f.reason,
                                );
                            },
                        }
                    }
                }
            }
        },
    }

    return null;
}

pub fn send_buffer_destroy(client: *Client, buffer_id: BufferID) !void {
    try client.connection.send_buffer_destroy(
        client.io,
        client.gpa,
        .{ .buffer_id = buffer_id },
    );
}

pub fn remote_viewport_embed(
    client: *Client,
    viewport_id: ViewportID,
    client_uuid_to_embed: ptypes.ClientUUID,
    rect: ptypes.Rect,
) !*RemoteViewport {
    try client.remote_viewports.ensureUnusedCapacity(client.gpa, 1);
    const rvp = try client.gpa.create(RemoteViewport);
    errdefer client.gpa.destroy(rvp);

    const id = client.next_remote_viewport_id.increment();
    rvp.* = .init(viewport_id, id, client, rect);

    client.remote_viewports.putAssumeCapacityNoClobber(id, rvp);

    try client.connection.send_remote_viewport_embed(
        client.io,
        client.gpa,
        .{
            .client_uuid_to_embed = client_uuid_to_embed,
            .embeder_viewport_id = viewport_id,
            .rect = rect,
            .remote_viewport_id = id,
        },
    );

    return rvp;
}

pub fn read_thread(
    io: Io,
    gpa: std.mem.Allocator,
    stream: net.Stream,
    queues: *Client.MessagesQueue,
) void {
    log.debug("Started read_thread", .{});
    defer log.debug("Exited read_thread", .{});

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    var reader_buffer: [4096]u8 = undefined;
    var reader = stream.reader(io, &reader_buffer);
    while (true) {
        _ = arena.reset(.{ .retain_with_limit = 1024 * 1024 }); // 1MB

        const message = switch (os) {
            .linux => ServerConnection.receive_linux(io, arena.allocator(), stream),
            .windows => blk: {
                const message = ServerConnection.receive_with_reader(
                    io,
                    arena.allocator(),
                    &reader.interface,
                ) catch |err| break :blk switch (err) {
                    error.ReadFailed => reader.err.?,
                    else => |e| break :blk e,
                };

                break :blk message;
            },
            else => comptime unreachable,
        } catch |err| switch (err) {
            error.EndOfStream, error.OutOfMemory => continue,

            error.Unexpected,
            error.ConnectionResetByPeer,
            error.Canceled,
            => return,

            else => |e| {
                std.log.err("Receive {}", .{e});
                continue;
            },
        };

        queues.mutex.lock(io) catch return;
        defer queues.mutex.unlock(io);

        queues.messages.ensureUnusedCapacity(gpa, 512) catch @panic("OOM");
        queues.messages.insertAssumeCapacity(0, message);
        queues.messages_available.set(io);
    }
}

pub const Gbm = if (!constants.os_has_gbm) void else struct {
    dri: Io.File,
    device: *c_linux.struct_gbm_device,
};

pub const D11Device = if (!constants.os_has_d3d) void else struct {
    device: *d11.ID3D11Device,
    device1: *d11.ID3D11Device1,
    device5: *d11.ID3D11Device5,

    context: *d11.ID3D11DeviceContext,
    context4: *d11.ID3D11DeviceContext4,

    pub fn init() !D11Device {
        const device, const context = blk: {
            var device: *d11.ID3D11Device = undefined;
            var context: *d11.ID3D11DeviceContext = undefined;
            var feature_level: d3d.D3D_FEATURE_LEVEL = undefined;

            const result = d11.D3D11CreateDevice(
                null,
                .HARDWARE,
                null,
                .{},
                null,
                0,
                d11.D3D11_SDK_VERSION,
                &device,
                &feature_level,
                &context,
            );

            if (result != win32_foundation.S_OK) {
                log.err("FailedToCreateD3D11Device: 0x{x}", .{result});
                return error.FailedToCreateD3D11Device;
            }

            break :blk .{ device, context };
        };

        const device1 = blk: {
            var device1: *d11.ID3D11Device1 = undefined;
            const result = device.IUnknown.QueryInterface(
                d11.IID_ID3D11Device1,
                @ptrCast(&device1),
            );
            if (result != win32_foundation.S_OK) {
                log.err("FailedToQueryD3D11Device1: 0x{x}", .{result});
                return error.FailedToQueryD3D11Device1;
            }
            break :blk device1;
        };

        const device5 = blk: {
            var device5: *d11.ID3D11Device5 = undefined;
            const result = device.IUnknown.QueryInterface(
                d11.IID_ID3D11Device5,
                @ptrCast(&device5),
            );
            if (result != win32_foundation.S_OK) {
                log.err("FailedToQueryD3D11Device5: 0x{x}", .{result});
                return error.FailedToQueryD3D11Device5;
            }
            break :blk device5;
        };

        const context4 = blk: {
            var context4: *d11.ID3D11DeviceContext4 = undefined;
            const result = context.IUnknown.QueryInterface(
                d11.IID_ID3D11DeviceContext4,
                @ptrCast(&context4),
            );
            if (result != win32_foundation.S_OK) {
                log.err("FailedToQueryD3D11Context4: 0x{x}", .{result});
                return error.FailedToQueryD3D11Context4;
            }
            break :blk context4;
        };

        return .{
            .device = device,
            .context = context,
            .device1 = device1,
            .device5 = device5,
            .context4 = context4,
        };
    }

    pub fn deinit(ctx: D11Device) void {
        _ = ctx.device1.IUnknown.Release();
        _ = ctx.device5.IUnknown.Release();

        _ = ctx.context4.IUnknown.Release();
        _ = ctx.context.IUnknown.Release();
        _ = ctx.device.IUnknown.Release();
    }
};

pub const Event = union(enum) {
    viewport_resize: server_to_client.ViewportResize,
    viewport_close: server_to_client.ViewportClose,
    keyboard_char: server_to_client.KeyboardChar,
    keyboard_key: server_to_client.KeyboardKey,
    keyboard_enter: server_to_client.KeyboardEnter,
    keyboard_leave: server_to_client.KeyboardLeave,
    mouse_enter: server_to_client.MouseEnter,
    mouse_leave: server_to_client.MouseLeave,
    mouse_motion: server_to_client.MouseMotion,
    mouse_button: server_to_client.MouseButton,
    mouse_scroll: server_to_client.MouseScroll,
    remote_viewport_closed: RemoteViewportID,
    remote_viewport_embedded: RemoteViewportID,
    wake_up,
};

pub fn WithViewportID(comptime T: type) type {
    return struct {
        viewport_id: ViewportID,
        message: T,
    };
}

pub const CreateStatus = enum {
    created,
    pending,
    failed,
};

const Env = struct {
    expect_viewport: bool,
    client_uuid: ?ptypes.ClientUUID,

    pub fn extract(map: *std.process.Environ.Map) Env {
        defer {
            _ = map.swapRemove(constants.env_client_uuid);
            _ = map.swapRemove(constants.env_expect_viewport_key);
        }

        return .{
            .expect_viewport = if (map.get(constants.env_expect_viewport_key)) |value|
                std.mem.eql(u8, value, constants.env_expect_viewport_true)
            else
                false,

            .client_uuid = if (map.get(constants.env_client_uuid)) |value|
                ptypes.ClientUUID.deserialize(value) catch |err| blk: {
                    log.err("ClientUUID parse failed {}", .{err});

                    break :blk null;
                }
            else
                null,
        };
    }
};

pub const MessagesQueue = struct {
    mutex: Io.Mutex,
    messages: std.ArrayList(server_to_client.MessagePayload),
    messages_available: Io.Event,

    pub fn create(gpa: std.mem.Allocator) !*MessagesQueue {
        const ptr = try gpa.create(MessagesQueue);
        ptr.* = .{
            .mutex = .init,
            .messages = .empty,
            .messages_available = .unset,
        };
        return ptr;
    }

    pub fn destroy(q: *MessagesQueue, gpa: std.mem.Allocator) void {
        q.messages.deinit(gpa);
        gpa.destroy(q);
    }
};

const RequestStatus = union(enum) {
    pending,
    success,
    failure: ptypes.RequestFailureReason,
};

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const utils = @import("utils");
const constants = @import("constants");
const client_to_server = @import("protocol").client_to_server;
const server_to_client = @import("protocol").server_to_client;
const ptypes = @import("protocol").types;
const opengl = @import("opengl.zig");
const c_linux = @import("c_linux");
const glad = @import("glad");
const ViewportID = ptypes.ViewportID;
const RemoteViewportID = ptypes.RemoteViewportID;
const BufferID = ptypes.BufferID;
const log = std.log.scoped(.Client);
const Viewport = @import("Viewport.zig");
const RemoteViewport = @import("RemoteViewport.zig");
const Process = @import("remote_client").Process;
const RemoteClient = @import("remote_client").RemoteClient;
const ServerConnection = @import("ServerConnection.zig");
const os = @import("builtin").os.tag;
const d11 = @import("win32").graphics.direct3d11;
const d3d = @import("win32").graphics.direct3d;
const win32_foundation = @import("win32").foundation;
const known_folders = @import("known-folders");
const Buffers = @import("Buffers.zig");
const BufferCreatedCpu = server_to_client.BufferCreatedCpu;
const BufferCreatedGbmBo = server_to_client.BufferCreatedGbmBo;
const TextureCreatedD3D = server_to_client.TextureCreatedD3D;
const ViewportCreated = server_to_client.ViewportCreated;
