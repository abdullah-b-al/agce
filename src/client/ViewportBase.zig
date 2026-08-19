const ViewportBase = @This();

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

pub fn init(
    client: *Client,
    id: ViewportID,
    width: u32,
    height: u32,
    format: ptypes.BufferFormat,
    vsync: bool,
) ViewportBase {
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
    };
}

pub fn deinit(base: *ViewportBase) void {
    base.messages.deinit(base.client.gpa);
    base.events.deinit(base.client.gpa);
    base.buffers_status.deinit(base.client.gpa);
}

pub fn push_message(base: *ViewportBase, message: Client.Message) void {
    base.messages.insertAssumeCapacity(0, message);
}

pub fn push_event(base: *ViewportBase, event: Client.Event) void {
    base.events.insertAssumeCapacity(0, event);
}

pub fn handle_message(base: *ViewportBase, comptime tag: Client.Message.Tag, message: Client.Message) !void {
    std.debug.assert(tag == message);
    const msg = @field(message, @tagName(tag));

    switch (tag) {
        .viewport_created => {
            std.debug.assert(base.status == .pending);
            switch (msg.status) {
                .success => base.status = .created,
                .failure => base.status = .failed,
            }
        },
        .viewport_resize => {
            const vp = base.client.viewports.get(msg.viewport_id) orelse return;
            switch (vp) {
                .gl => |gl| try gl.resize(msg.width, msg.height),
                .cpu => |cpu| try cpu.resize(msg),
            }
        },
        .viewport_closed => {
            base.open = true;
        },

        .buffer_released => {
            const vp = base.client.viewports.get(msg.viewport_id) orelse return;
            switch (vp) {
                inline else => |v| v.buffer_released(msg.buffer_id),
            }
        },
        .buffer_created => {
            const ptr = base.buffers_status.getPtr(msg.message.buffer_id).?;
            std.debug.assert(ptr.* == .pending);
            ptr.* = switch (msg.message.status) {
                .success => .created,
                .failure => .failed,
            };
        },
        .buffer_destroyed => {
            const vp = base.client.viewports.getPtr(msg.viewport_id) orelse return;
            switch (vp.*) {
                inline else => |v| v.buffer_destroyed(msg.message.buffer_id),
            }
        },
        .frame_render => {
            const vp = base.client.viewports.get(msg.viewport_id).?;
            switch (vp) {
                inline else => |v| v.frame_render(),
            }
        },
    }
}

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
