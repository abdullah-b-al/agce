const Client = @This();

io: Io,
gpa: std.mem.Allocator,
environ_map: std.process.Environ.Map,
connection: net.Stream,
registered: bool,

next_viewport_id: ptypes.ViewportID,
next_buffer_id: ptypes.BufferID,
next_sub_viewport_id: ptypes.SubViewportID,

viewports: std.array_hash_map.Auto(ViewportID, *Viewport),
viewports_from_server: std.array_hash_map.Auto(ViewportID, ptypes.Size),
sub_viewports: std.array_hash_map.Auto(SubViewportID, *SubViewport),

processes: std.ArrayList(*Process),

messages_arena: std.heap.ArenaAllocator,

gbm: ?Gbm,
gl_context: ?opengl.ContextLinux,

env: Env,

pub fn init(
    io: Io,
    gpa: std.mem.Allocator,
    environ_map: *std.process.Environ.Map,
) !Client {
    var map = try environ_map.clone(gpa);
    errdefer map.deinit();

    const env: Env = .extract(&map);

    var path_buf: [constants.socket_max_path]u8 = undefined;
    const path = utils.unix_address_path(environ_map, &path_buf);
    const address = try net.UnixAddress.init(path);

    const stream = try address.connect(io);

    return .{
        .io = io,
        .gpa = gpa,
        .environ_map = map,
        .connection = stream,
        .registered = false,
        .messages_arena = .init(gpa),
        .next_viewport_id = .first_for_client,
        .next_buffer_id = .first,
        .next_sub_viewport_id = .first,
        .viewports = .empty,
        .viewports_from_server = .empty,
        .sub_viewports = .empty,
        .processes = .empty,
        .gbm = null,
        .gl_context = null,

        .env = env,
    };
}

pub fn deinit(client: *Client) void {
    for (client.processes.items) |p| {
        if (!p.deinited) {
            p.deinit();
            log.err("Process {*} leaked", .{p});
        }
        client.gpa.destroy(p);
    }

    for (client.viewports.values()) |vp| {
        if (!vp.deinited) {
            vp.deinit();
            log.err("{f} leaked", .{vp.id});
        }
        client.gpa.destroy(vp);
    }

    for (client.sub_viewports.values()) |svp| {
        if (!svp.deinited) {
            svp.deinit();
            log.err("{f} leaked", .{svp.id});
        }
        client.gpa.destroy(svp);
    }

    if (client.gbm) |gbm| {
        gbm.dri.close(client.io);
        c_linux.gbm_device_destroy(gbm.device);
    }

    const containers = .{
        &client.viewports,
        &client.sub_viewports,
        &client.viewports_from_server,
        &client.processes,
    };

    inline for (containers) |container| {
        container.deinit(client.gpa);
    }

    client.environ_map.deinit();
    client.messages_arena.deinit();
    client.connection.close(client.io);
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

pub fn init_gl(client: *Client, major: c_int, minor: c_int) !void {
    std.debug.assert(client.gbm != null);
    const gbm = client.gbm.?;

    const gl = try opengl.init_linux(gbm.device, major, minor);
    try opengl.load_gl(gl);

    client.gl_context = gl;
}

pub fn update_by_tag(client: *Client, viewport_id: ViewportID, comptime tag: Message.Tag) !void {
    const vp = client.viewports.get(viewport_id) orelse return error.ViewportDoesNotExist;
    var i = vp.messages.items.len;
    while (i > 0) {
        i -= 1;
        const message = vp.messages.items[i];
        if (message == tag) {
            try vp.message_handle(tag, message);
            _ = vp.messages.orderedRemove(i);
        }
    }
}

pub fn wait_for(client: *Client, viewport_id: ViewportID, tag: Message.Tag) !void {
    try client.wait_for_count(viewport_id, tag, 1);
}

pub fn wait_for_count(client: *Client, viewport_id: ViewportID, tag: Message.Tag, min_count: usize) !void {
    const vp = client.viewports.get(viewport_id) orelse return error.ViewportDoesNotExist;
    while (true) {
        try client.poll(.none);

        var count: usize = 0;
        for (vp.messages.items) |message| {
            if (message == tag)
                count += 1;
        }

        if (count >= min_count) {
            break;
        }
    }
}

pub fn poll(client: *Client, timeout: Io.Timeout) !void {
    defer _ = client.messages_arena.reset(.{ .retain_with_limit = 1024 * 1024 });

    try client.viewports_from_server.ensureUnusedCapacity(client.gpa, 1);
    for (client.viewports.values()) |vp| {
        try vp.messages.ensureUnusedCapacity(client.gpa, 1);
        try vp.events.ensureUnusedCapacity(client.gpa, 1);
    }

    const messages = try server_to_client.message_receive_all(
        client.io,
        client.messages_arena.allocator(),
        client.connection,
        timeout,
    );

    errdefer comptime unreachable;

    for (messages) |message| {
        client.poll_process_message(message);
    }
}

fn poll_process_message(client: *Client, message: server_to_client.MessagePayload) void {
    switch (message) {
        .registered => {
            client.registered = true;
        },
        .generated_client_full_id => |result| {
            const process = blk: for (client.processes.items) |process| {
                if (process.full_id == null) break :blk process;
            } else null;

            if (process) |p| {
                p.received_id(result.full_id);
            } else unreachable;
        },
        .client_registered => |e| {
            const process = blk: for (client.processes.items) |process| {
                const full_id = process.full_id orelse continue;
                if (full_id.id == e.client_id) break :blk process;
            } else null;

            if (process) |p| {
                p.client_connected();
            }
        },
        .client_disconnected => |e| {
            for (client.processes.items) |p| {
                if (p.full_id) |c| if (c.id == e.client_id) {
                    p.status = .disconnected;
                };
            }
        },
        .viewport_create => |e| {

            // TODO: Maybe these shouldn't trust the server and should error instead of asserting
            std.debug.assert(
                @intFromEnum(e.viewport_id) >= @intFromEnum(ViewportID.first_for_server),
            );
            client.viewports_from_server.putAssumeCapacityNoClobber(
                e.viewport_id,
                .{ .width = e.width, .height = e.height },
            );
        },

        .sub_viewport_embeded => |e| {
            const vp = client.sub_viewports.get(e.sub_viewport_id) orelse return;
            switch (e.status) {
                .success => vp.state = .shown,
                .failure => vp.state = .failed,
            }
            vp.render_size = e.render_size;
        },
        .sub_viewport_display_state => |e| {
            const svp = client.sub_viewports.get(e.sub_viewport_id) orelse return;
            switch (svp.state) {
                .closed, .pending, .failed => return,
                .shown, .hidden => {},
            }
            svp.state = switch (e.state) {
                .shown => .shown,
                .hidden => .hidden,
            };
        },
        .sub_viewport_closed => |e| {
            const svp = client.sub_viewports.get(e.sub_viewport_id) orelse return;
            svp.state = .closed;
        },
        .viewport_resize => |e| {
            const vp = client.viewports.get(e.viewport_id) orelse return;
            vp.event_push(.{ .viewport_resize = e });
            vp.message_push(.{ .viewport_resize = e });
        },
        .viewport_closed => |e| {
            const vp = client.viewports.get(e.viewport_id) orelse return;
            vp.event_push(.{ .viewport_closed = e });
            vp.message_push(.{ .viewport_closed = e });
        },

        inline .mouse_enter,
        .mouse_leave,
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

        inline .buffer_destroyed, .buffer_created => |e, tag| {
            const vp = client.viewport_from_buffer_id(e.buffer_id) orelse return;
            const msg = @unionInit(Message, @tagName(tag), .{
                .viewport_id = vp.id,
                .message = e,
            });
            vp.message_push(msg);
        },

        inline .frame_render,
        .buffer_released,
        .viewport_created,
        => |e, tag| {
            const vp = client.viewports.get(e.viewport_id) orelse return;
            const msg = @unionInit(Message, @tagName(tag), e);
            vp.message_push(msg);
        },
    }
}

pub fn viewport_from_buffer_id(client: *Client, buffer_id: BufferID) ?*Viewport {
    for (client.viewports.values()) |vp| {
        if (vp.has_buffer(buffer_id)) {
            return vp;
        }
    }

    return null;
}

pub fn viewport_create(
    client: *Client,
    tag: Viewport.Renderer.Tag,
    size: ptypes.Size,
    vsync: bool,
) !*Viewport {
    const id = client.next_viewport_id.increment_for_client();

    const vp = switch (tag) {
        .gl => try client.viewport_create_with_id(.gl, id, size, vsync),
        .cpu => try client.viewport_create_with_id(.cpu, id, size, vsync),
    };

    return vp;
}

pub fn viewport_create_from_pending(
    client: *Client,
    tag: Viewport.Renderer.Tag,
    id: ViewportID,
    vsync: bool,
    size: ptypes.Size,
) !*Viewport {
    std.debug.assert(
        client.viewports_from_server.contains(id),
    );

    const vp = switch (tag) {
        .gl => try client.viewport_create_with_id(.gl, id, size, vsync),
        .cpu => try client.viewport_create_with_id(.cpu, id, size, vsync),
    };

    _ = client.viewports_from_server.orderedRemove(id);

    return vp;
}

pub fn viewport_create_with_id(
    client: *Client,
    tag: Viewport.Renderer.Tag,
    id: ViewportID,
    requested_size: ptypes.Size,
    vsync: bool,
) !*Viewport {
    try client.viewports.ensureUnusedCapacity(client.gpa, 1);

    const vp = blk: {
        const renderer: Viewport.Renderer = switch (tag) {
            .gl => .{ .gl = .init(client.gbm.?, client.gl_context.?) },
            .cpu => .{ .cpu = .init() },
        };
        const vp = try client.gpa.create(Viewport);
        vp.* = .init(
            id,
            client,
            requested_size,
            .argb8888,
            vsync,
            renderer,
        );
        break :blk vp;
    };
    client.viewports.putAssumeCapacityNoClobber(vp.id, vp);

    switch (vp.renderer) {
        inline else => |*r, t| {
            const width, const height = utils.new_dimensions(requested_size.width, requested_size.height);
            const array = try buffers.buffers_create(
                Viewport.Renderer.RendererBuffer(t),
                2,
                vp,
                client,
                &r.buffers_collection,
                .{ client, width, height, vp.format },
            );

            for (array) |b| {
                r.buffers_collection.available.putAssumeCapacityNoClobber(b.id, b);
            }
        },
    }

    try client.send_viewport_create(id, requested_size);

    while (true) {
        try client.wait_for(id, .viewport_created);
        try client.update_by_tag(id, .viewport_created);

        switch (vp.status) {
            .pending => continue,
            .created => break,
            .failed => return error.ViewportCreateFailed,
        }
    }

    return vp;
}

pub fn frame_wait_for_vsync_if_enabled(client: *Client, vp: *Viewport) !void {
    if (!vp.vsync) return;
    try frame_wait_for_vsync(client, vp);
}

pub fn frame_wait_for_vsync(client: *Client, vp: *Viewport) !void {
    std.debug.assert(vp.vsync);

    while (!vp.can_render) {
        try client.wait_for(vp.id, .frame_render);
        try client.update_by_tag(vp.id, .frame_render);
    }
}

pub fn send_viewport_create(
    client: *Client,
    viewport_id: ViewportID,
    size: ptypes.Size,
) !void {
    const vp = client.viewports.get(viewport_id).?;

    const create_sync_timeline = blk: {
        break :blk switch (vp.renderer) {
            .gl => true,
            .cpu => false,
        };
    };

    try client_to_server.message_send_json(client.io, client.gpa, client.connection, .{
        .viewport_create = .{
            .viewport_id = viewport_id,
            .create_sync_timeline = create_sync_timeline,
            .vsync = vp.vsync,

            .size = size,
        },
    });
}

pub fn send_buffer_create_gpu_with_fds(
    client: *Client,
    vp: *Viewport,
    buffer: RendererGL.Buffer,
) !void {
    const acquire = buffer.acquire.fd(client.gbm.?);
    defer _ = std.os.linux.close(@intFromEnum(acquire));

    const release = buffer.release.fd(client.gbm.?);
    defer _ = std.os.linux.close(@intFromEnum(release));

    const buffer_fd: ptypes.GpuBufferFd = @enumFromInt(c_linux.gbm_bo_get_fd(buffer.bo));
    defer _ = std.os.linux.close(@intFromEnum(buffer_fd));

    vp.buffers_status.putAssumeCapacityNoClobber(buffer.id, .pending);
    try client_to_server.message_send_json(
        client.io,
        client.gpa,
        client.connection,
        .{
            .buffer_create_gpu_with_fds = .{
                .buffer_id = buffer.id,
                .width = c_linux.gbm_bo_get_width(buffer.bo),
                .height = c_linux.gbm_bo_get_height(buffer.bo),
                .format = buffer.format,
                .gbm_bo_modifier = c_linux.gbm_bo_get_modifier(buffer.bo),
                .fds = .{
                    .buffer = buffer_fd,
                    .acquire_timeline = acquire,
                    .release_timeline = release,
                },
            },
        },
    );
}

pub fn send_buffer_create_cpu_with_fd(
    client: *Client,
    vp: *Viewport,
    buffer: RendererCpu.Buffer,
) !void {
    vp.buffers_status.putAssumeCapacityNoClobber(buffer.id, .pending);
    try client_to_server.message_send_json(
        client.io,
        client.gpa,
        client.connection,
        .{
            .buffer_create_cpu_with_fd = .{
                .buffer_id = buffer.id,
                .width = buffer.width,
                .height = buffer.height,
                .format = buffer.format,
                .fd = buffer.fd,
            },
        },
    );
}

pub fn send_buffer_destroy(client: *Client, buffer_id: BufferID) !void {
    try client_to_server.message_send_json(
        client.io,
        client.gpa,
        client.connection,
        .{ .buffer_destroy = .{ .buffer_id = buffer_id } },
    );
}

pub fn sub_viewport_embed(
    client: *Client,
    viewport_id: ViewportID,
    client_id_to_embed: ptypes.ClientID,
    rect: ptypes.Rect,
) !*SubViewport {
    try client.sub_viewports.ensureUnusedCapacity(client.gpa, 1);
    const svp = try client.gpa.create(SubViewport);
    errdefer client.gpa.destroy(svp);

    const id = client.next_sub_viewport_id.increment();
    svp.* = .init(id, client, rect);

    client.sub_viewports.putAssumeCapacityNoClobber(id, svp);

    try client_to_server.message_send_json(
        client.io,
        client.gpa,
        client.connection,
        .{
            .sub_viewport_embed = .{
                .client_id_to_embed = client_id_to_embed,
                .embeder_viewport_id = viewport_id,
                .rect = rect,
                .sub_viewport_id = id,
            },
        },
    );

    return svp;
}

pub const Gbm = struct {
    dri: Io.File,
    device: *c_linux.struct_gbm_device,

    pub fn bo_create(gbm: Gbm, width: u32, height: u32) !*c_linux.struct_gbm_bo {
        return c_linux.gbm_bo_create(
            gbm.device,
            width,
            height,
            c_linux.GBM_BO_FORMAT_ARGB8888,
            c_linux.GBM_BO_USE_RENDERING,
        ) orelse error.FailedToGbmBoCreate;
    }

    pub fn syncobj_create(gbm: Gbm) u32 {
        var syncobj: u32 = undefined;
        const create_result = c_linux.drmSyncobjCreate(gbm.dri.handle, 0, &syncobj);
        std.debug.assert(create_result == 0);
        return syncobj;
    }

    pub fn syncobj_fd_from_handle(gbm: Gbm, syncobj: u32) c_int {
        var fd: c_int = undefined;
        const create_result = c_linux.drmSyncobjHandleToFD(gbm.dri.handle, syncobj, &fd);
        std.debug.assert(create_result == 0);
        return fd;
    }
};

pub const Event = union(enum) {
    const Payload = server_to_client.MessagePayload;

    viewport_resize: Payload.ViewportResize,
    viewport_closed: Payload.ViewportClosed,
    keyboard_char: Payload.KeyboardChar,
    keyboard_key: Payload.KeyboardKey,
    mouse_enter: Payload.MouseEnter,
    mouse_leave: Payload.MouseLeave,
    mouse_motion: Payload.MouseMotion,
    mouse_button: Payload.MouseButton,
    mouse_scroll: Payload.MouseScroll,
};

pub const Message = union(enum) {
    pub const Tag = std.meta.Tag(Message);
    const Payload = server_to_client.MessagePayload;

    viewport_resize: Payload.ViewportResize,
    viewport_closed: Payload.ViewportClosed,
    viewport_created: Payload.ViewportCreated,
    buffer_released: Payload.BufferReleased,
    buffer_destroyed: WithViewportID(Payload.BufferDestroyed),
    buffer_created: WithViewportID(Payload.BufferCreated),
    frame_render: Payload.FrameRender,
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
    client_full_id: ?ptypes.ClientFullID,

    pub fn extract(map: *std.process.Environ.Map) Env {
        defer {
            _ = map.swapRemove(constants.env_client_full_id);
            _ = map.swapRemove(constants.env_expect_viewport_key);
        }

        return .{
            .expect_viewport = if (map.get(constants.env_expect_viewport_key)) |value|
                std.mem.eql(u8, value, constants.env_expect_viewport_true)
            else
                false,

            .client_full_id = if (map.get(constants.env_client_full_id)) |value|
                .from_env_string(value)
            else
                null,
        };
    }
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
const SubViewportID = ptypes.SubViewportID;
const BufferID = ptypes.BufferID;
const log = std.log.scoped(.Client);
const buffers = @import("buffers.zig");
const Viewport = @import("Viewport.zig");
const SubViewport = @import("SubViewport.zig");
const RendererGL = @import("RendererGL.zig");
const RendererCpu = @import("RendererCpu.zig");
const Process = @import("Process.zig");
