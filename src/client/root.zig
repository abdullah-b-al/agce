pub const Event = Client.Event;
pub const opengl = @import("opengl.zig");

pub const ViewportID = ptypes.ViewportID;
pub const SubViewportID = ptypes.SubViewportID;
pub const BufferID = ptypes.BufferID;
pub const CursorShape = ptypes.CursorShape;
pub const ClientInfo = ptypes.ClientInfo;
pub const ClientID = ptypes.ClientID;
pub const Rect = ptypes.Rect;

pub const Key = @import("protocol").input.Key;
pub const KeyState = @import("protocol").input.KeyState;
pub const MouseButton = @import("protocol").input.MouseButton;

pub const ClientHandle = opaque {
    fn cast(handle: *ClientHandle) *Client {
        return @ptrCast(@alignCast(handle));
    }
};

pub const GlViewportID = struct { generic: ViewportID };
pub const CpuViewportID = struct { generic: ViewportID };

pub const FrameBeginGl = struct {
    fbo: c_uint,
    viewport_width: u32,
    viewport_height: u32,
};

pub const FrameBeginCpu = struct {
    buffer: []u8,
    width: u32,
    height: u32,
    bytes_per_pixel: u8,
    viewport_width: u32,
    viewport_height: u32,
};

pub fn init(
    io: std.Io,
    gpa: std.mem.Allocator,
    environ_map: *std.process.Environ.Map,
    info: ?ClientInfo,
) !*ClientHandle {
    const client = try gpa.create(Client);
    errdefer gpa.destroy(client);

    client.* = try .init(io, gpa, environ_map, info);
    errdefer client.deinit();

    if (client.info) |i| {
        try client_to_server.message_send_json(
            io,
            gpa,
            client.connection,
            .{ .client_info_set = i },
        );
    }

    return @ptrCast(client);
}

pub fn deinit(handle: *ClientHandle) void {
    const client = handle.cast();
    const gpa = client.gpa;

    client.deinit();
    gpa.destroy(client);
}

pub fn init_opengl(handle: *ClientHandle, major: c_int, minor: c_int) !void {
    const client = handle.cast();
    try client.init_gbm();
    try client.init_gl(major, minor);
}

pub fn poll(handle: *ClientHandle, timeout: std.Io.Timeout) !void {
    const client = handle.cast();
    while (true) {
        client.poll_once(timeout) catch |err| switch (err) {
            error.Timeout => break,
            else => |e| return e,
        };
    }
}

pub fn poll_once(handle: *ClientHandle, timeout: std.Io.Timeout) !void {
    const client = handle.cast();
    try client.poll_once(timeout);
}

pub fn poll_for_events(handle: *ClientHandle, timeout: std.Io.Timeout) !void {
    const client = handle.cast();
    // In a loop to ignore messages that are not events
    while (client.events.items.len == 0) {
        try client.poll_once(timeout);
    }
}

pub fn update(handle: *ClientHandle) !void {
    const client = handle.cast();
    while (client.messages.pop()) |message| {
        switch (message) {
            inline else => |_, tag| {
                client.message_handle(tag, message) catch |err| switch (err) {
                    else => |e| return e,
                };
            },
        }
    }
}

pub fn event_pop(handle: *ClientHandle, viewport_id: ViewportID) ?Client.Event {
    const client = handle.cast();

    var i = client.events.items.len;
    while (i > 0) {
        i -= 1;
        const event = client.events.items[i];

        const event_viewport_id = switch (event) {
            inline else => |v| v.viewport_id,
        };

        if (event_viewport_id == viewport_id) {
            return client.events.orderedRemove(i);
        }
    }

    return null;
}

pub fn viewport_pending_peek(handle: *ClientHandle) ?ViewportID {
    const client = handle.cast();
    if (client.viewports_from_server.count() == 0)
        return null;

    return client.viewports_from_server.keys()[0];
}

pub fn viewport_resize(handle: *ClientHandle, id: ViewportID, requseted_width: u32, requseted_height: u32) !void {
    const client = handle.cast();
    const vp = client.viewports.get(id) orelse return;
    const buffer_size = switch (vp) {
        inline else => |v| v.buffer_size(),
    };

    const width = @min(buffer_size[0], requseted_width);
    const height = @min(buffer_size[1], requseted_height);

    try client_to_server.message_send_json(
        client.io,
        client.gpa,
        client.connection,
        .{
            .viewport_resize = .{
                .viewport_id = id,
                .width = width,
                .height = height,
            },
        },
    );

    switch (vp) {
        inline else => |v| {
            v.width = width;
            v.height = width;
        },
    }
}

pub fn viewport_size(handle: *ClientHandle, id: ViewportID) ?[2]u32 {
    const client = handle.cast();
    const vp = client.viewports.get(id) orelse return null;
    return switch (vp) {
        inline else => |v| .{ v.width, v.height },
    };
}

pub fn viewport_open(handle: *ClientHandle, id: ViewportID) bool {
    const client = handle.cast();
    const vp = client.viewports.get(id) orelse return false;
    return switch (vp) {
        inline else => |v| v.open,
    };
}

pub fn frame_wait_for_vsync_if_enabled(handle: *ClientHandle, viewport_id: ViewportID) !void {
    const client = handle.cast();
    const vp = client.viewports.get(viewport_id) orelse return;
    const vsync_enabled = switch (vp) {
        .cpu => @panic("TODO"),
        .gl => |gl| gl.vsync,
    };
    if (!vsync_enabled) return;
    try frame_wait_for_vsync(handle, viewport_id);
}

pub fn frame_wait_for_vsync(handle: *ClientHandle, viewport_id: ViewportID) !void {
    const client = handle.cast();
    const vp = client.viewports.get(viewport_id) orelse return;
    const vsync_enabled = switch (vp) {
        .cpu => @panic("TODO"),
        .gl => |gl| gl.vsync,
    };
    std.debug.assert(vsync_enabled);

    const can_render: *bool = switch (vp) {
        .cpu => @panic("TODO"),
        .gl => |gl| &gl.can_render,
    };

    while (!can_render.*) {
        try client.wait_for(.frame_render);
        try client.update_by_tag(.frame_render);
    }
}

pub fn gl_viewport_create_from_pending(handle: *ClientHandle, vsync: bool, viewport_id: ViewportID) !GlViewportID {
    const client = handle.cast();

    std.debug.assert(
        client.viewports_from_server.contains(viewport_id),
    );
    const size = client.viewports_from_server.get(viewport_id).?;

    const vp = try client.gl_viewport_create_with_id(viewport_id, size.width, size.height, vsync);

    _ = client.viewports_from_server.orderedRemove(viewport_id);

    try client.send_viewport_create(viewport_id, size.width, size.height, false);
    while (vp.create_status == .pending) {
        try client.wait_for(.viewport_created);
        try client.update_by_tag(.viewport_created);

        switch (vp.create_status) {
            .pending, .created => {},
            .failed => return error.ViewportCreateFailed,
        }
    }

    return .{ .generic = viewport_id };
}

pub fn gl_viewport_create(handle: *ClientHandle, width: u32, height: u32, vsync: bool) !GlViewportID {
    const client = handle.cast();

    const id = client.next_viewport_id.increment_for_client();
    const vp = try client.gl_viewport_create_with_id(id, width, height, vsync);

    try client.send_viewport_create(id, width, height, true);
    while (vp.create_status == .pending) {
        try client.wait_for(.viewport_created);
        try client.update_by_tag(.viewport_created);

        switch (vp.create_status) {
            .pending, .created => {},
            .failed => return error.ViewportCreateFailed,
        }
    }

    return .{ .generic = id };
}

pub fn gl_frame_begin(handle: *ClientHandle, viewport_id: GlViewportID) !FrameBeginGl {
    const client = handle.cast();

    const vp = client.viewports.get(viewport_id.generic) orelse return error.ViewportDoesNotExist;
    std.debug.assert(vp == .gl);
    const gl = vp.gl;

    if (!gl.open) return error.ViewportClosed;

    std.debug.assert(gl.current_buffer == null);

    const buffer = gl.get_buffer(std.math.maxInt(i64)) catch |err| switch (err) {
        error.Timeout => unreachable,
    };

    gl.current_buffer = buffer.id;
    return .{
        .fbo = buffer.fbo,
        .viewport_width = gl.width,
        .viewport_height = gl.height,
    };
}

pub fn gl_frame_end(handle: *ClientHandle, viewport_id: GlViewportID) void {
    const client = handle.cast();
    const vp = client.viewports.get(viewport_id.generic) orelse @panic("Viewport destroyed or never existed");
    std.debug.assert(vp == .gl);
    const gl = vp.gl;

    const buffer = gl.buffers_collection.available.getPtr(gl.current_buffer.?) orelse
        @panic("Buffer prematurely destroyed");

    gl.frame_end(buffer);
}

pub fn gl_frame_present(handle: *ClientHandle, viewport_id: GlViewportID) !void {
    const client = handle.cast();
    const vp = client.viewports.get(viewport_id.generic) orelse
        @panic("Viewport destroyed or never existed");

    std.debug.assert(vp == .gl);
    const gl = vp.gl;
    defer gl.current_buffer = null;

    const buffer = gl.buffers_collection.available.getPtr(gl.current_buffer.?) orelse
        @panic("Buffer prematurely destroyed");

    try gl.buffer_present(buffer);
}

pub fn cpu_viewport_create(handle: *ClientHandle, width: u32, height: u32) !CpuViewportID {
    const client = handle.cast();

    const id = client.next_viewport_id.increment_for_client();
    const vp = try client.cpu_viewport_create_with_id(id, width, height);

    try client.send_viewport_create(vp.id, width, height, true);
    while (vp.create_status == .pending) {
        try client.wait_for(.viewport_created);
        try client.update_by_tag(.viewport_created);

        switch (vp.create_status) {
            .pending, .created => {},
            .failed => return error.ViewportCreateFailed,
        }
    }

    return .{ .generic = vp.id };
}

pub fn cpu_viewport_create_from_pending(handle: *ClientHandle, viewport_id: ViewportID) !CpuViewportID {
    const client = handle.cast();

    std.debug.assert(
        client.viewports_from_server.contains(viewport_id),
    );
    const size = client.viewports_from_server.get(viewport_id).?;

    const vp = try client.cpu_viewport_create_with_id(viewport_id, size.width, size.height);

    _ = client.viewports_from_server.orderedRemove(viewport_id);

    try client.send_viewport_create(viewport_id, size.width, size.height, false);
    while (vp.create_status == .pending) {
        try client.wait_for(.viewport_created);
        try client.update_by_tag(.viewport_created);

        switch (vp.create_status) {
            .pending, .created => {},
            .failed => return error.ViewportCreateFailed,
        }
    }

    return .{ .generic = viewport_id };
}
pub fn cpu_frame_begin(handle: *ClientHandle, viewport_id: CpuViewportID) !FrameBeginCpu {
    const client = handle.cast();

    const vp = client.viewports.get(viewport_id.generic) orelse return error.ViewportDoesNotExist;
    std.debug.assert(vp == .cpu);
    const cpu = vp.cpu;

    if (!cpu.open) return error.ViewportClosed;

    std.debug.assert(cpu.current_buffer == null);

    var buffer: ?*ViewportCpu.Buffer = null;
    while (buffer == null) {
        buffer = cpu.get_buffer() orelse {
            std.debug.assert(cpu.buffers_collection.available.count() > 0);
            try client.wait_for(.buffer_released);
            try client.update_by_tag(.buffer_released);
            continue;
        };
    }

    cpu.current_buffer = buffer.?.id;

    return .{
        .buffer = buffer.?.data,
        .width = buffer.?.width,
        .height = buffer.?.height,
        .bytes_per_pixel = buffer.?.format.bytes_per_pixel(),
        .viewport_width = cpu.width,
        .viewport_height = cpu.height,
    };
}

pub fn cpu_frame_end(_: *ClientHandle, _: CpuViewportID) void {}

pub fn cpu_frame_present(handle: *ClientHandle, viewport_id: CpuViewportID) !void {
    const client = handle.cast();

    const vp = client.viewports.get(viewport_id.generic) orelse return;
    std.debug.assert(vp == .cpu);
    const cpu = vp.cpu;
    defer cpu.current_buffer = null;

    const buffer = cpu.buffers_collection.available.getPtr(cpu.current_buffer.?).?;
    try cpu.buffer_present(buffer);
}

pub fn cursor_shape_set(handle: *ClientHandle, viewport_id: ViewportID, shape: CursorShape) !void {
    const client = handle.cast();

    try client_to_server.message_send_json(
        client.io,
        client.gpa,
        client.connection,
        .{
            .cursor_shape_set = .{ .viewport_id = viewport_id, .shape = shape },
        },
    );
}

pub fn sub_viewport_embed(
    handle: *ClientHandle,
    viewport_id: ViewportID,
    client_id_to_embed: ClientID,
    rect: Rect,
) !SubViewportID {
    const client = handle.cast();

    const id = client.next_sub_viewport_id.increment();

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

    return id;
}

pub fn sub_viewport_rect_set(
    handle: *ClientHandle,
    sub_viewport_id: SubViewportID,
    rect: Rect,
) !void {
    const client = handle.cast();

    try client_to_server.message_send_json(
        client.io,
        client.gpa,
        client.connection,
        .{
            .sub_viewport_rect_set = .{
                .rect = rect,
                .sub_viewport_id = sub_viewport_id,
            },
        },
    );
}

pub fn client_info_iterator(handle: *ClientHandle) ClientInfoIterator {
    return .{
        .handle = handle,
        .i = 0,
    };
}

pub const ClientInfoIterator = struct {
    handle: *ClientHandle,
    i: usize,

    pub fn next(iter: *ClientInfoIterator) ?Result {
        const client = iter.handle.cast();
        if (iter.i >= client.other_clients.count()) return null;
        defer iter.i += 1;

        const id, const clone = .{
            client.other_clients.keys()[iter.i],
            client.other_clients.values()[iter.i],
        };

        return .{
            .client_id = id,
            .info = .{
                .name = clone.strings[clone.name.offset..][0..clone.name.len],
            },
        };
    }

    pub const Result = struct {
        client_id: ptypes.ClientID,
        info: ptypes.ClientInfo,
    };
};

const std = @import("std");
const ptypes = @import("protocol").types;
const client_to_server = @import("protocol").client_to_server;
const server_to_client = @import("protocol").server_to_client;
const Client = @import("Client.zig");
const ViewportGL = @import("ViewportGL.zig");
const ViewportCpu = @import("ViewportCpu.zig");
const buffers = @import("buffers.zig");
