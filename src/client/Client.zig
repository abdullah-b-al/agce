const Client = @This();

io: Io,
gpa: std.mem.Allocator,
connection: net.Stream,

next_viewport_id: ptypes.ViewportID,
next_buffer_id: ptypes.BufferID,

viewports: std.array_hash_map.Auto(ViewportID, Viewport),

messages_arena: std.heap.ArenaAllocator,
messages: std.ArrayList(server_to_client.MessagePayload),

gbm: ?Gbm,
gl_context: ?opengl.ContextLinux,

pub fn init(
    io: Io,
    gpa: std.mem.Allocator,
    environ_map: *std.process.Environ.Map,
) !Client {
    var path_buf: [constants.socket_max_path]u8 = undefined;
    const path = utils.unix_address_path(environ_map, &path_buf);
    const address = try net.UnixAddress.init(path);

    const stream = try address.connect(io);

    return .{
        .io = io,
        .gpa = gpa,
        .connection = stream,
        .messages_arena = .init(gpa),
        .messages = .empty,
        .next_viewport_id = .first_for_client,
        .next_buffer_id = .first,
        .viewports = .empty,
        .gbm = null,
        .gl_context = null,
    };
}

pub fn deinit(client: *Client) void {
    for (client.viewports.values()) |vp| {
        switch (vp) {
            inline else => |v| {
                v.deinit();
                client.gpa.destroy(v);
            },
        }
    }
    client.viewports.deinit(client.gpa);

    if (client.gbm) |gbm| {
        gbm.dri.close(client.io);
        c_linux.gbm_device_destroy(gbm.device);
    }
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

pub fn init_gl(client: *Client) !void {
    std.debug.assert(client.gbm != null);
    const gbm = client.gbm.?;

    const gl = try opengl.init_linux(gbm.device);
    try opengl.load_gl(gl);

    client.gl_context = gl;
}

pub fn viewport_create_gl(client: *Client, width: u32, height: u32) !*ViewportGL {
    const format: ptypes.BufferFormat = .argb8888;
    try client.viewports.ensureUnusedCapacity(client.gpa, 1);

    const vp = try client.gpa.create(ViewportGL);
    vp.* = try .init(client, width, height);

    try vp.buffer_new(width, height, format);
    try vp.buffer_new(width, height, format);

    client.viewports.putAssumeCapacityNoClobber(vp.id, .{ .gl = vp });

    try client.messages_wait_for_buffer_created(2);
    try client.messages_handle();

    return vp;
}

pub fn viewport_create_cpu(client: *Client, width: u32, height: u32) !*ViewportCpu {
    try client.viewports.ensureUnusedCapacity(client.gpa, 1);
    const vp = try client.gpa.create(ViewportCpu);
    vp.* = try .init(client, width, height);

    try vp.buffer_new(width, height);
    try vp.buffer_new(width, height);

    client.viewports.putAssumeCapacityNoClobber(vp.id, .{ .cpu = vp });

    try client.messages_wait_for_buffer_created(2);
    try client.messages_handle();

    return vp;
}

pub fn window_create(
    client: *Client,
    viewport_id: ViewportID,
    width: u32,
    height: u32,
) !void {
    const create_sync_timeline = blk: {
        const vp = client.viewports.get(viewport_id).?;
        break :blk switch (vp) {
            .gl => true,
            .cpu => false,
        };
    };

    try client_to_server.message_send_json(client.io, client.gpa, client.connection, .{
        .window_create = .{
            .viewport_id = viewport_id,
            .width = width,
            .height = height,
            .create_sync_timeline = create_sync_timeline,
        },
    });
}

pub fn messages_poll_and_handle(client: *Client, timeout: Io.Timeout) !void {
    while (true) {
        client.message_poll(timeout) catch |err| switch (err) {
            error.Timeout => break,
            else => |e| return e,
        };
    }

    try client.messages_handle();
}

pub fn messages_wait_for_buffer_created(client: *Client, min_count: usize) !void {
    const timeout: Io.Timeout = .none;
    while (true) {
        try client.message_poll(timeout);

        var count: usize = 0;
        for (client.messages.items) |message| {
            if (message == .buffer_created)
                count += 1;
        }

        if (count >= min_count) {
            break;
        }
    }
}

fn message_poll(client: *Client, timeout: Io.Timeout) !void {
    if (client.messages.items.len == 0) {
        _ = client.messages_arena.reset(.{ .retain_with_limit = 4096 });
    }

    try client.messages.ensureUnusedCapacity(client.gpa, 1);
    const message = try server_to_client.message_receive(
        client.io,
        client.messages_arena.allocator(),
        client.connection,
        timeout,
    );

    client.messages.insertAssumeCapacity(0, message);
}

fn messages_handle(client: *Client) !void {
    while (client.messages.pop()) |message| {
        try client.message_handle(message);
    }

    _ = client.messages_arena.reset(.{ .retain_with_limit = 4096 });
}

fn message_handle(client: *Client, message: server_to_client.MessagePayload) !void {
    switch (message) {
        .viewport_resize => |msg| {
            log.debug("Received {t} {}", .{ message, msg });
            const vp = client.viewports.get(msg.viewport_id).?;
            switch (vp) {
                .gl => |gl| try gl.resize(msg.width, msg.height),
                .cpu => |cpu| try cpu.resize(msg),
            }
        },

        .buffer_released => |msg| {
            log.debug("Received {t} {}", .{ message, msg });
            const vp = client.viewports.get(msg.viewport_id).?;
            switch (vp) {
                inline else => |v| v.buffer_released(msg.buffer_id),
            }
        },
        .buffer_created => |msg| {
            log.debug("Received {t} {}", .{ message, msg });

            const vp = client.viewport_from_buffer_id(msg.buffer_id) orelse return;
            switch (msg.status) {
                .success => {
                    switch (vp) {
                        inline else => |v| try v.buffer_created(msg.buffer_id),
                    }
                },
                .failure => @panic("TODO"),
            }
        },
        .buffer_destroyed => |msg| {
            log.debug("Received {t} {}", .{ message, msg });
            const vp = client.viewport_from_buffer_id(msg.buffer_id) orelse return;
            switch (vp) {
                inline else => |v| v.buffer_destroyed(msg.buffer_id),
            }
        },
    }
}

pub fn viewport_from_buffer_id(client: *Client, buffer_id: BufferID) ?Viewport {
    for (client.viewports.values()) |vp| {
        switch (vp) {
            inline else => |v| {
                if (v.has_buffer(buffer_id)) {
                    return vp;
                }
            },
        }
    }

    return null;
}

pub fn send_buffer_create_gpu_with_fds(
    client: *Client,
    buffer: ViewportGL.Buffer,
) !void {
    const acquire = buffer.acquire.fd(client.gbm.?);
    defer _ = std.os.linux.close(@intFromEnum(acquire));

    const release = buffer.release.fd(client.gbm.?);
    defer _ = std.os.linux.close(@intFromEnum(release));

    const buffer_fd: ptypes.GpuBufferFd = @enumFromInt(c_linux.gbm_bo_get_fd(buffer.bo));
    defer _ = std.os.linux.close(@intFromEnum(buffer_fd));

    try client_to_server.message_send_json(
        client.io,
        client.gpa,
        client.connection,
        .{
            .buffer_create_gpu_with_fds = .{
                .id = buffer.id,
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

pub fn send_buffer_create_cpu_with_fd(client: *Client, buffer: ViewportCpu.Buffer) !void {
    try client_to_server.message_send_json(
        client.io,
        client.gpa,
        client.connection,
        .{
            .buffer_create_cpu_with_fd = .{
                .id = buffer.id,
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

const Viewport = union(enum) {
    gl: *ViewportGL,
    cpu: *ViewportCpu,
};

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const constants = @import("../constants.zig");
const utils = @import("../utils.zig");
const client_to_server = @import("../protocol/client_to_server.zig");
const server_to_client = @import("../protocol/server_to_client.zig");
const common = @import("../protocol/common.zig");
const ptypes = @import("../protocol/types.zig");
const opengl = @import("../opengl.zig");
const c_linux = @import("c_linux");
const glad = @import("glad");
const ViewportID = ptypes.ViewportID;
const BufferID = ptypes.BufferID;
const ViewportGL = @import("ViewportGL.zig");
const ViewportCpu = @import("ViewportCpu.zig");
const log = std.log.scoped(.Client);
