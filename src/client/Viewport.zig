const Viewport = @This();

deinited: bool,

client: *Client,
id: ViewportID,
frame_number: usize,
size: ptypes.Size,
format: ptypes.BufferFormat,
should_close: bool,
throttle_frames: bool,
refresh_cycle: u32,
last_presented_refresh_cycle: u32,
current_buffer: ?BufferID,

status: Client.CreateStatus,
buffers_status: std.array_hash_map.Auto(BufferID, CreateStatus),

messages: std.ArrayList(Client.Message),
events: std.ArrayList(Client.Event),

renderer: Renderer,

pub fn init(
    id: ViewportID,
    client: *Client,
    size: ptypes.Size,
    format: ptypes.BufferFormat,
    throttle: bool,
    renderer: Renderer,
) Viewport {
    return .{
        .client = client,
        .deinited = false,
        .id = id,
        .size = size,
        .format = format,
        .throttle_frames = throttle,

        .should_close = false,
        .refresh_cycle = 0,
        .last_presented_refresh_cycle = 0,
        .frame_number = 0,
        .current_buffer = null,

        .messages = .empty,
        .events = .empty,

        .buffers_status = .empty,
        .status = .pending,
        .renderer = renderer,
    };
}

pub fn deinit(vp: *Viewport) void {
    std.debug.assert(!vp.deinited);

    switch (vp.renderer) {
        inline else => |*r| r.deinit(vp.client.gpa),
    }
    vp.messages.deinit(vp.client.gpa);
    vp.events.deinit(vp.client.gpa);
    vp.buffers_status.deinit(vp.client.gpa);
    vp.deinited = true;
}

pub fn has_buffer(vp: *Viewport, buffer_id: BufferID) bool {
    return vp.buffers_status.contains(buffer_id);
}

pub fn event_push(vp: *Viewport, event: Client.Event) void {
    vp.events.insertAssumeCapacity(0, event);
}

pub fn event_pop(vp: *Viewport) ?Client.Event {
    return vp.events.pop();
}

pub fn message_push(vp: *Viewport, message: Client.Message) void {
    vp.messages.insertAssumeCapacity(0, message);
}

pub fn message_handle(vp: *Viewport, comptime tag: Client.Message.Tag, message: Client.Message) !void {
    std.debug.assert(tag == message);
    const msg = @field(message, @tagName(tag));

    switch (tag) {
        .viewport_created => {
            std.debug.assert(vp.status == .pending);
            switch (msg.status) {
                .success => vp.status = .created,
                .failure => vp.status = .failed,
            }
        },
        .viewport_resize => {
            switch (vp.renderer) {
                .gl => |*gl| try gl.resize(vp, msg.size),
                .cpu => |*cpu| try cpu.resize(vp, msg),
            }
        },

        .buffer_released => {
            switch (vp.renderer) {
                .gl => {}, // relies on timelines
                inline else => |*r| r.buffer_released(msg.buffer_id),
            }
        },
        .buffer_created => {
            const ptr = vp.buffers_status.getPtr(msg.message.buffer_id).?;
            std.debug.assert(ptr.* == .pending);
            ptr.* = switch (msg.message.status) {
                .success => .created,
                .failure => .failed,
            };
        },
        .buffer_destroyed => {
            switch (vp.renderer) {
                inline else => |*r| r.buffer_destroyed(msg.message.buffer_id),
            }
        },
        .frame_render => {
            vp.refresh_cycle = msg.refresh_cycle;
        },
    }
}

pub fn viewport_resize(vp: *Viewport, size: ptypes.Size) void {
    const buffer_size = switch (vp.renderer) {
        inline else => |r| r.buffer_size(),
    };

    const width = @min(buffer_size.width, size.width);
    const height = @min(buffer_size.height, size.height);

    vp.size = .{ .width = width, .height = height };
}

pub fn buffer_present(vp: *Viewport) !void {
    defer {
        vp.current_buffer = null;
    }

    const buffer: *anyopaque, const message: client_to_server.MessagePayload =
        blk: switch (vp.renderer) {
            .cpu => |*cpu| {
                const buffer = cpu.buffers_collection.available.getPtr(vp.current_buffer.?).?;
                std.debug.assert(buffer.released);

                break :blk .{
                    buffer,
                    .{
                        .buffer_present = .{
                            .viewport_id = vp.id,
                            .buffer_id = buffer.id,
                            .viewport_size = vp.size,
                        },
                    },
                };
            },
            .gl => |*gl| {
                const buffer = gl.buffers_collection.available.getPtr(vp.current_buffer.?) orelse
                    @panic("Buffer prematurely destroyed");
                std.debug.assert(buffer.released);
                buffer.release.point.advance();

                break :blk .{
                    buffer,
                    .{
                        .buffer_present_with_sync = .{
                            .viewport_id = vp.id,
                            .buffer_id = buffer.id,
                            .acquire_point = buffer.acquire.point,
                            .release_point = buffer.release.point,
                            .viewport_size = vp.size,
                        },
                    },
                };
            },
        };

    try client_to_server.message_send_json(
        vp.client.io,
        vp.client.gpa,
        vp.client.connection,
        message,
    );

    switch (vp.renderer) {
        .cpu => |_, tag| {
            const b: *Renderer.RendererBuffer(tag) = @ptrCast(@alignCast(buffer));
            b.released = false;
        },
        .gl => |_, tag| {
            const b: *Renderer.RendererBuffer(tag) = @ptrCast(@alignCast(buffer));
            b.acquire.point.advance();
            b.released = false;
        },
    }

    vp.last_presented_refresh_cycle = vp.refresh_cycle;

    vp.frame_number += 1;
}

pub const Renderer = union(enum) {
    pub const Tag = std.meta.Tag(Renderer);

    gl: RendererGL,
    cpu: RendererCpu,

    pub fn RendererBuffer(comptime tag: Tag) type {
        return switch (tag) {
            .gl => RendererGL.Buffer,
            .cpu => RendererCpu.Buffer,
        };
    }
};

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const client_to_server = @import("protocol").client_to_server;
const server_to_client = @import("protocol").server_to_client;
const ptypes = @import("protocol").types;
const c_linux = @import("c_linux");
const glad = @import("glad");
const ViewportID = ptypes.ViewportID;
const BufferID = ptypes.BufferID;
const Client = @import("Client.zig");
const buffers = @import("buffers.zig");
const BufferStatus = @import("buffers.zig").BufferStatus;
const CreateStatus = Client.CreateStatus;
const BufferPresented = server_to_client.MessagePayload.BufferPresented;
const log = std.log.scoped(.Viewport);
const RendererGL = @import("RendererGL.zig");
const RendererCpu = @import("RendererCpu.zig");
