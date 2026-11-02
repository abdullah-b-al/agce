const RemoteViewport = @This();

client: *Client,
deinited: bool,
parent: ViewportID,
id: RemoteViewportID,
render_size: ptypes.Size,
pos: ptypes.Pos,
size: ptypes.Size,
state: State,

pub fn init(
    parent: ViewportID,
    id: RemoteViewportID,
    client: *Client,
    rect: ptypes.Rect,
) RemoteViewport {
    return .{
        .client = client,
        .deinited = false,
        .parent = parent,
        .id = id,
        .pos = .from_rect(rect),
        .size = .from_rect(rect),
        .render_size = .{ .width = 0, .height = 0 },
        .state = .pending,
    };
}
pub fn deinit(rvp: *RemoteViewport) void {
    std.debug.assert(!rvp.deinited);
    rvp.deinited = true;
}

pub const State = union(enum) {
    shown: ptypes.ViewportKey,
    hidden: ptypes.ViewportKey,
    closed,
    pending,
    failed,

    pub fn from_display_state(s: ptypes.ViewportDisplayState, key: ptypes.ViewportKey) State {
        return switch (s) {
            .shown => .{ .shown = key },
            .hidden => .{ .hidden = key },
        };
    }

    pub fn to_display_state(s: State) ptypes.ViewportDisplayState {
        return switch (s) {
            .shown => .shown,

            .closed, .failed, .pending, .hidden => .hidden,
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
const RemoteViewportID = ptypes.RemoteViewportID;
const ViewportID = ptypes.ViewportID;
const BufferID = ptypes.BufferID;
const Client = @import("Client.zig");
const CreateStatus = Client.CreateStatus;
const log = std.log.scoped(.Viewport);
