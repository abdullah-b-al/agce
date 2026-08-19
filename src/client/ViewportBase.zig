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
    };
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
