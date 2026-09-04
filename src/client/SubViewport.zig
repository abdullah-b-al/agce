const SubViewport = @This();

client: *Client,
deinited: bool,
id: SubViewportID,
render_size: ptypes.Size,
pos: ptypes.Pos,
size: ptypes.Size,
state: State,

pub fn init(
    id: SubViewportID,
    client: *Client,
    rect: ptypes.Rect,
) SubViewport {
    return .{
        .client = client,
        .deinited = false,
        .id = id,
        .pos = .from_rect(rect),
        .size = .from_rect(rect),
        .render_size = .{ .width = 0, .height = 0 },
        .state = .pending,
    };
}
pub fn deinit(svp: *SubViewport) void {
    std.debug.assert(!svp.deinited);
    svp.deinited = true;
}

pub const State = enum {
    shown,
    hidden,
    pending,
    failed,
    closed,

    pub fn from_display_state(s: ptypes.ViewportDisplayState) State {
        return switch (s) {
            .shown => .shown,
            .hidden => .hidden,
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
const SubViewportID = ptypes.SubViewportID;
const BufferID = ptypes.BufferID;
const Client = @import("Client.zig");
const buffers = @import("buffers.zig");
const BufferStatus = @import("buffers.zig").BufferStatus;
const CreateStatus = Client.CreateStatus;
const log = std.log.scoped(.Viewport);
const RendererGL = @import("RendererGL.zig");
const RendererCpu = @import("RendererCpu.zig");
