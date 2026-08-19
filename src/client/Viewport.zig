const Viewport = @This();

client: *Client,
id: ViewportID,
frame_number: usize,
width: u32,
height: u32,
format: ptypes.BufferFormat,
open: bool,
vsync: bool,
can_render: bool,
current_buffer: ?BufferID,

status: Client.CreateStatus,
buffers_status: std.array_hash_map.Auto(BufferID, CreateStatus),

messages: std.ArrayList(Client.Message),
events: std.ArrayList(Client.Event),

renderer: Renderer,

pub fn init(
    id: ViewportID,
    client: *Client,
    width: u32,
    height: u32,
    format: ptypes.BufferFormat,
    vsync: bool,
    renderer: Renderer,
) Viewport {
    return .{
        .client = client,
        .id = id,
        .width = width,
        .height = height,
        .format = format,
        .vsync = vsync,

        .open = true,
        .can_render = true,
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
    switch (vp.renderer) {
        inline else => |*r| r.deinit(vp.client.gpa),
    }
    vp.messages.deinit(vp.client.gpa);
    vp.events.deinit(vp.client.gpa);
    vp.buffers_status.deinit(vp.client.gpa);
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
                .gl => |*gl| try gl.resize(vp, msg.width, msg.height),
                .cpu => |*cpu| try cpu.resize(vp, msg),
            }
        },
        .viewport_closed => {
            vp.open = false;
        },

        .buffer_released => {
            switch (vp.renderer) {
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
            vp.can_render = true;
        },
    }
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
const ptypes = @import("protocol").types;
const c_linux = @import("c_linux");
const glad = @import("glad");
const ViewportID = ptypes.ViewportID;
const BufferID = ptypes.BufferID;
const Client = @import("Client.zig");
const buffers = @import("buffers.zig");
const BufferStatus = @import("buffers.zig").BufferStatus;
const CreateStatus = Client.CreateStatus;
const log = std.log.scoped(.Viewport);
const RendererGL = @import("RendererGL.zig");
const RendererCpu = @import("RendererCpu.zig");
