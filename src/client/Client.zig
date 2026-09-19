const Client = @This();

io: Io,
gpa: std.mem.Allocator,
environ_map: std.process.Environ.Map,
connection: ServerConnection,
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

read_future: Io.Future(void),
messages_queue: *MessagesQueue,

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
        .environ_map = map,
        .connection = .{
            .format = .json,
            .stream = stream,
        },
        .messages_queue = queues,
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
        .read_future = future,
    };
}

pub fn deinit(client: *Client) void {
    client.read_future.cancel(client.io);

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

    if (constants.os_has_gbm) {
        if (client.gbm) |gbm| {
            gbm.dri.close(client.io);
            c_linux.gbm_device_destroy(gbm.device);
        }
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

pub fn poll(client: *Client, timeout: Io.Timeout) error{ Timeout, Canceled, OutOfMemory }!void {
    try client.messages_queue.messages_available.waitTimeout(client.io, timeout);
    client.messages_queue.messages_available.reset();

    try client.messages_queue.mutex.lock(client.io);
    defer client.messages_queue.mutex.unlock(client.io);

    const len = client.messages_queue.messages.items.len;

    try client.viewports_from_server.ensureUnusedCapacity(client.gpa, len);
    for (client.viewports.values()) |vp| {
        try vp.messages.ensureUnusedCapacity(client.gpa, len);
        try vp.events.ensureUnusedCapacity(client.gpa, len);
        try vp.pending_buffers_cpu.ensureUnusedCapacity(client.gpa, len);
        try vp.pending_buffers_gbm_bo.ensureUnusedCapacity(client.gpa, len);
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
                for (client.viewports.values()) |vp| {
                    vp.event_push(.wake_up);
                }
            }
        },
        .client_disconnected => |e| {
            for (client.processes.items) |p| {
                if (p.full_id) |c| if (c.id == e.client_id) {
                    p.status = .disconnected;
                };
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

        .sub_viewport_embeded => |e| {
            const svp = client.sub_viewports.get(e.sub_viewport_id) orelse return;
            switch (e.status) {
                .success => {
                    if (client.viewports.get(svp.parent)) |vp| {
                        vp.event_push(.{ .sub_viewport_embeded = svp.id });
                    }
                    svp.state = .shown;
                },
                .failure => svp.state = .failed,
            }
            svp.render_size = e.render_size;
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

            if (client.viewports.get(svp.parent)) |vp| {
                vp.event_push(.{ .sub_viewport_closed = svp.id });
            }
        },
        .viewport_resize => |e| {
            const vp = client.viewports.get(e.viewport_id) orelse return;
            vp.event_push(.{ .viewport_resize = e });
            vp.message_push(.{ .viewport_resize = e });
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
            const vp = client.viewports.get(e.viewport_id) orelse return;
            vp.pending_buffers_cpu.appendAssumeCapacity(e);
        },
        .buffer_created_gbm_bo => |e| {
            const vp = client.viewports.get(e.viewport_id) orelse return;
            vp.pending_buffers_gbm_bo.appendAssumeCapacity(e);
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

pub fn viewport_create(
    client: *Client,
    tag: Viewport.Renderer.Tag,
    size: ptypes.Size,
    throttle: bool,
) !*Viewport {
    const id = client.next_viewport_id.increment_for_client();

    const vp = switch (tag) {
        .gl => try client.viewport_create_with_id(.gl, id, size, throttle),
        .cpu => try client.viewport_create_with_id(.cpu, id, size, throttle),
    };

    return vp;
}

pub fn viewport_create_from_pending(
    client: *Client,
    tag: Viewport.Renderer.Tag,
    id: ViewportID,
    throttle: bool,
    size: ptypes.Size,
) !*Viewport {
    std.debug.assert(
        client.viewports_from_server.contains(id),
    );

    const vp = switch (tag) {
        .gl => try client.viewport_create_with_id(.gl, id, size, throttle),
        .cpu => try client.viewport_create_with_id(.cpu, id, size, throttle),
    };

    _ = client.viewports_from_server.orderedRemove(id);

    return vp;
}

pub fn viewport_create_with_id(
    client: *Client,
    tag: Viewport.Renderer.Tag,
    id: ViewportID,
    requested_size: ptypes.Size,
    throttle: bool,
) !*Viewport {
    try client.viewports.ensureUnusedCapacity(client.gpa, 1);
    const vp = blk: {
        const renderer: Viewport.Renderer = switch (tag) {
            .gl => if (RendererGL == Viewport.LinuxRendererGL)
                .{ .gl = .init(client.gbm.?, client.gl_context.?) }
            else
                @panic("TODO"),
            .cpu => .{ .cpu = .init() },
        };
        const vp = try client.gpa.create(Viewport);
        vp.* = .init(
            id,
            client,
            requested_size,
            .argb8888,
            throttle,
            renderer,
        );
        break :blk vp;
    };
    client.viewports.putAssumeCapacityNoClobber(vp.id, vp);

    try vp.buffers_create(requested_size);

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

pub fn throttle_frames_if_enabled(client: *Client, vp: *Viewport) !void {
    if (!vp.throttle_frames) return;
    try throttle_frames(client, vp);
}

pub fn throttle_frames(client: *Client, vp: *Viewport) !void {
    std.debug.assert(vp.throttle_frames);

    while (vp.frame_number > vp.refresh_cycle) {
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

    try client.connection.send_viewport_create(client.io, client.gpa, .{
        .viewport_id = viewport_id,
        .create_sync_timeline = create_sync_timeline,
        .size = size,
    });
}

pub fn send_buffer_destroy(client: *Client, buffer_id: BufferID) !void {
    try client.connection.send_buffer_destroy(
        client.io,
        client.gpa,
        .{ .buffer_id = buffer_id },
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
    svp.* = .init(viewport_id, id, client, rect);

    client.sub_viewports.putAssumeCapacityNoClobber(id, svp);

    try client.connection.send_sub_viewport_embed(
        client.io,
        client.gpa,
        .{
            .client_id_to_embed = client_id_to_embed,
            .embeder_viewport_id = viewport_id,
            .rect = rect,
            .sub_viewport_id = id,
        },
    );

    return svp;
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

    while (true) {
        _ = arena.reset(.{ .retain_with_limit = 1024 * 1024 }); // 1MB

        const message = switch (os) {
            .linux => ServerConnection.receive_linux(io, arena.allocator(), stream),
            .windows => ServerConnection.receive_windows(io, arena.allocator(), stream),
            else => comptime unreachable,
        } catch |err| switch (err) {
            error.OutOfMemory => continue,

            error.Unexpected,
            error.ConnectionResetByPeer,
            error.ConnectionClosed,
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

pub const Event = union(enum) {
    viewport_resize: server_to_client.ViewportResize,
    viewport_close: server_to_client.ViewportClose,
    keyboard_char: server_to_client.KeyboardChar,
    keyboard_key: server_to_client.KeyboardKey,
    mouse_enter: server_to_client.MouseEnter,
    mouse_leave: server_to_client.MouseLeave,
    mouse_motion: server_to_client.MouseMotion,
    mouse_button: server_to_client.MouseButton,
    mouse_scroll: server_to_client.MouseScroll,
    sub_viewport_closed: SubViewportID,
    sub_viewport_embeded: SubViewportID,
    wake_up,
};

pub const Message = union(enum) {
    pub const Tag = std.meta.Tag(Message);

    viewport_resize: server_to_client.ViewportResize,
    viewport_created: server_to_client.ViewportCreated,
    buffer_released: server_to_client.BufferReleased,
    frame_render: server_to_client.FrameRender,
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
const Viewport = @import("Viewport.zig");
const SubViewport = @import("SubViewport.zig");
const RendererGL = Viewport.RendererGL;
const RendererCpu = Viewport.RendererCpu;
const Process = @import("Process.zig");
const ServerConnection = @import("ServerConnection.zig");
const os = @import("builtin").os.tag;
