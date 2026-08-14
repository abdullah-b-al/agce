pub const Event = Client.Event;
pub const opengl = @import("opengl.zig");

pub const ViewportID = ptypes.ViewportID;
pub const BufferID = ptypes.BufferID;

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
    width: u32,
    height: u32,
};

pub fn init(
    io: std.Io,
    gpa: std.mem.Allocator,
    environ_map: *std.process.Environ.Map,
) !*ClientHandle {
    const client = try gpa.create(Client);
    errdefer gpa.destroy(client);

    client.* = try .init(io, gpa, environ_map);

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

pub fn window_create(
    handle: *ClientHandle,
    viewport_id: ViewportID,
    width: u32,
    height: u32,
) !void {
    const client = handle.cast();

    const create_sync_timeline, const vsync = blk: {
        const vp = client.viewports.get(viewport_id).?;
        break :blk switch (vp) {
            .gl => |gl| .{ true, gl.vsync },
            .cpu => .{ false, false },
        };
    };

    try client_to_server.message_send_json(client.io, client.gpa, client.connection, .{
        .window_create = .{
            .viewport_id = viewport_id,
            .width = width,
            .height = height,
            .create_sync_timeline = create_sync_timeline,
            .vsync = vsync,
        },
    });
}

pub fn gl_viewport_create(handle: *ClientHandle, width: u32, height: u32, vsync: bool) !GlViewportID {
    const client = handle.cast();
    const format: ptypes.BufferFormat = .argb8888;
    try client.viewports.ensureUnusedCapacity(client.gpa, 1);

    const vp = try client.gpa.create(ViewportGL);
    vp.* = try .init(client, width, height, vsync);
    client.viewports.putAssumeCapacityNoClobber(vp.id, .{ .gl = vp });

    const array = try buffers.buffers_create(
        ViewportGL.Buffer,
        2,
        client,
        &vp.buffers_collection,
        .{ client, width, height, format },
    );

    errdefer comptime unreachable;

    for (array) |b| {
        vp.buffers_collection.available.putAssumeCapacityNoClobber(b.id, b);
    }

    return .{ .generic = vp.id };
}

pub fn gl_frame_begin(handle: *ClientHandle, viewport_id: GlViewportID) !FrameBeginGl {
    const client = handle.cast();

    const vp = client.viewports.get(viewport_id.generic) orelse return error.ViewportDoesNotExist;
    std.debug.assert(vp == .gl);
    const gl = vp.gl;

    std.debug.assert(gl.current_buffer == null);

    var buffer: ?*ViewportGL.Buffer = null;
    while (buffer == null) {
        buffer = gl.get_buffer(std.math.maxInt(i64)) catch |err| switch (err) {
            error.Timeout => unreachable,
        };
    }

    gl.current_buffer = buffer.?.id;
    return .{
        .fbo = buffer.?.fbo,
        .width = gl.width,
        .height = gl.height,
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

    try client.viewports.ensureUnusedCapacity(client.gpa, 1);
    const vp = try client.gpa.create(ViewportCpu);
    vp.* = try .init(client, width, height);

    const array = try buffers.buffers_create(
        ViewportCpu.Buffer,
        2,
        client,
        &vp.buffers_collection,
        .{ client, width, height, vp.format },
    );

    errdefer comptime unreachable;

    for (array) |b| {
        vp.buffers_collection.available.putAssumeCapacityNoClobber(b.id, b);
    }

    client.viewports.putAssumeCapacityNoClobber(vp.id, .{ .cpu = vp });

    return .{ .generic = vp.id };
}

pub fn cpu_frame_begin(handle: *ClientHandle, viewport_id: CpuViewportID) ![]u8 {
    const client = handle.cast();

    const vp = client.viewports.get(viewport_id.generic) orelse return error.ViewportDoesNotExist;
    std.debug.assert(vp == .cpu);
    const cpu = vp.cpu;

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

    return buffer.?.data;
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

const std = @import("std");
const ptypes = @import("protocol").types;
const client_to_server = @import("protocol").client_to_server;
const server_to_client = @import("protocol").server_to_client;
const Client = @import("Client.zig");
const ViewportGL = @import("ViewportGL.zig");
const ViewportCpu = @import("ViewportCpu.zig");
const buffers = @import("buffers.zig");
