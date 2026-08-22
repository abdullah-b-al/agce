const SubViewport = @This();

client: *Client,
id: SubViewportID,
real_width: u32,
real_height: u32,
rect: ptypes.Rect,
open: bool,
status: CreateStatus,

pub fn init(
    id: SubViewportID,
    client: *Client,
    rect: ptypes.Rect,
) SubViewport {
    return .{
        .client = client,
        .id = id,
        .rect = rect,
        .real_width = 0,
        .real_height = 0,
        .status = .pending,
        .open = false,
    };
}

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const client_to_server = @import("protocol").client_to_server;
const ptypes = @import("protocol").types;
const c_linux = @import("c_linux");
const glad = @import("glad");
const SubViewportID = ptypes.SubViewportID;
const BufferID = ptypes.BufferID;
const Client = @import("Client.zig");
const buffers = @import("buffers.zig");
const BufferStatus = @import("buffers.zig").BufferStatus;
const CreateStatus = Client.CreateStatus;
const log = std.log.scoped(.Viewport);
const RendererGL = @import("RendererGL.zig");
const RendererCpu = @import("RendererCpu.zig");
