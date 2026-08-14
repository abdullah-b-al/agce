const Client = @This();

io: Io,
gpa: std.mem.Allocator,
connection: net.Stream,

next_viewport_id: ptypes.ViewportID,
next_buffer_id: ptypes.BufferID,

viewports: std.array_hash_map.Auto(ViewportID, Viewport),

buffers_status: std.array_hash_map.Auto(BufferID, BufferStatus),

messages_arena: std.heap.ArenaAllocator,
messages: std.ArrayList(Message),
events: std.ArrayList(Event),

gbm: ?Gbm,
gl_context: ?opengl.ContextLinux,

pub fn init(
    io: Io,
    gpa: std.mem.Allocator,
    environ_map: *std.process.Environ.Map,
) !Client {
    var path_buf: [utils.socket_max_path]u8 = undefined;
    const path = utils.unix_address_path(environ_map, &path_buf);
    const address = try net.UnixAddress.init(path);

    const stream = try address.connect(io);

    return .{
        .io = io,
        .gpa = gpa,
        .connection = stream,
        .messages_arena = .init(gpa),
        .messages = .empty,
        .events = .empty,
        .next_viewport_id = .first_for_client,
        .next_buffer_id = .first,
        .viewports = .empty,
        .buffers_status = .empty,
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

    client.buffers_status.deinit(client.gpa);

    if (client.gbm) |gbm| {
        gbm.dri.close(client.io);
        c_linux.gbm_device_destroy(gbm.device);
    }
    client.messages_arena.deinit();
    client.messages.deinit(client.gpa);
    client.events.deinit(client.gpa);

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

pub fn update_by_tag(client: *Client, comptime tag: Message.Tag) !void {
    var i = client.messages.items.len;
    while (i > 0) {
        i -= 1;
        const message = client.messages.items[i];
        if (message == tag) {
            try client.message_handle(tag, message);
            _ = client.messages.orderedRemove(i);
        }
    }
}

pub fn poll_for_events(client: *Client, timeout: Io.Timeout) !void {
    // In a loop to ignore messages that are not events
    while (client.events.items.len == 0) {
        try client.poll_once(timeout);
    }
}

pub fn wait_for(client: *Client, tag: Message.Tag) !void {
    try client.wait_for_count(tag, 1);
}

pub fn wait_for_count(client: *Client, tag: Message.Tag, min_count: usize) !void {
    while (true) {
        try client.poll_once(.none);

        var count: usize = 0;
        for (client.messages.items) |message| {
            if (message == tag)
                count += 1;
        }

        if (count >= min_count) {
            break;
        }
    }
}

// TODO: Poll all available messages
pub fn poll_once(client: *Client, timeout: Io.Timeout) !void {
    defer _ = client.messages_arena.reset(.{ .retain_with_limit = 4096 });

    try client.messages.ensureUnusedCapacity(client.gpa, 1);
    try client.events.ensureUnusedCapacity(client.gpa, 1);
    const message = try server_to_client.message_receive(
        client.io,
        client.messages_arena.allocator(),
        client.connection,
        timeout,
    );

    errdefer comptime unreachable;

    switch (message) {
        .viewport_resize => |e| {
            client.events.insertAssumeCapacity(0, .{ .viewport_resize = e });
            client.messages.insertAssumeCapacity(0, .{ .viewport_resize = e });
        },
        .viewport_closed => |e| {
            client.events.insertAssumeCapacity(0, .{ .viewport_closed = e });
            client.messages.insertAssumeCapacity(0, .{ .viewport_closed = e });
        },

        inline .mouse_enter,
        .mouse_leave,
        .mouse_motion,
        .mouse_button,
        .mouse_scroll,
        .keyboard_key,
        => |e, tag| {
            const event = @unionInit(Event, @tagName(tag), e);
            client.events.insertAssumeCapacity(0, event);
        },

        inline .frame_render,
        .buffer_released,
        .buffer_destroyed,
        .buffer_created,
        => |e, tag| {
            const msg = @unionInit(Message, @tagName(tag), e);
            client.messages.insertAssumeCapacity(0, msg);
        },
    }
}

pub fn message_handle(client: *Client, comptime tag: Message.Tag, message: Message) !void {
    std.debug.assert(tag == message);
    const msg = @field(message, @tagName(tag));

    switch (tag) {
        .viewport_resize => {
            const vp = client.viewports.get(msg.viewport_id) orelse return;
            switch (vp) {
                .gl => |gl| try gl.resize(msg.width, msg.height),
                .cpu => |cpu| try cpu.resize(msg),
            }
        },
        .viewport_closed => {
            const vp = client.viewports.get(msg.viewport_id) orelse return;
            switch (vp) {
                inline else => |v| v.close(),
            }
        },

        .buffer_released => {
            const vp = client.viewports.get(msg.viewport_id) orelse return;
            switch (vp) {
                inline else => |v| v.buffer_released(msg.buffer_id),
            }
        },
        .buffer_created => {
            // This handler only registers the status of the buffer.
            // Buffer creation should be done synchronously

            const ptr = client.buffers_status.getPtr(msg.buffer_id).?;
            std.debug.assert(ptr.* == .pending);
            ptr.* = switch (msg.status) {
                .success => .created,
                .failure => .failed,
            };
        },
        .buffer_destroyed => {
            const vp = client.viewport_from_buffer_id(msg.buffer_id) orelse return;
            switch (vp) {
                inline else => |v| v.buffer_destroyed(msg.buffer_id),
            }
        },
        .frame_render => {
            const vp = client.viewports.get(msg.viewport_id).?;
            switch (vp) {
                inline else => |v| v.frame_render(),
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

    client.buffers_status.putAssumeCapacityNoClobber(buffer.id, .pending);
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
    client.buffers_status.putAssumeCapacityNoClobber(buffer.id, .pending);
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

pub const Event = union(enum) {
    viewport_resize: ptypes.ViewportResize,
    viewport_closed: server_to_client.MessagePayload.ViewportClosed,
    keyboard_key: server_to_client.MessagePayload.KeyboardKey,
    mouse_enter: server_to_client.MessagePayload.MouseEnter,
    mouse_leave: server_to_client.MessagePayload.MouseLeave,
    mouse_motion: server_to_client.MessagePayload.MouseMotion,
    mouse_button: server_to_client.MessagePayload.MouseButton,
    mouse_scroll: server_to_client.MessagePayload.MouseScroll,
};

pub const Message = union(enum) {
    pub const Tag = std.meta.Tag(Message);

    viewport_resize: ptypes.ViewportResize,
    viewport_closed: server_to_client.MessagePayload.ViewportClosed,
    buffer_released: server_to_client.MessagePayload.BufferReleased,
    buffer_destroyed: server_to_client.MessagePayload.BufferDestroyed,
    buffer_created: server_to_client.MessagePayload.BufferCreated,
    frame_render: server_to_client.MessagePayload.FrameRender,
};

pub const BufferStatus = enum {
    created,
    pending,
    failed,
};

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const utils = @import("utils");
const client_to_server = @import("protocol").client_to_server;
const server_to_client = @import("protocol").server_to_client;
const ptypes = @import("protocol").types;
const opengl = @import("opengl.zig");
const c_linux = @import("c_linux");
const glad = @import("glad");
const ViewportID = ptypes.ViewportID;
const BufferID = ptypes.BufferID;
const ViewportGL = @import("ViewportGL.zig");
const ViewportCpu = @import("ViewportCpu.zig");
const log = std.log.scoped(.Client);
