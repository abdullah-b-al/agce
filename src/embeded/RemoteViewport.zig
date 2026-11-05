const RemoteViewport = @This();

embeded: *Embeded,
window_id: WindowID,
id: RemoteViewportID,
render_size: ptypes.Size,
pos: ptypes.Pos,
size: ptypes.Size,
state: State,

pub fn init(
    em: *Embeded,
    window_id: WindowID,
    id: RemoteViewportID,
    rect: ptypes.Rect,
) RemoteViewport {
    return .{
        .embeded = em,
        .window_id = window_id,
        .id = id,
        .pos = .from_rect(rect),
        .size = .from_rect(rect),
        .render_size = .{ .width = 0, .height = 0 },
        .state = .pending,
    };
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
const ptypes = @import("protocol").types;
const RemoteViewportID = ptypes.RemoteViewportID;
const ViewportID = ptypes.ViewportID;
const BufferID = ptypes.BufferID;
const WindowID = @import("compositor").Compositor.WindowID;
const Embeded = @import("Embeded.zig");
