const SubViewport = @This();

key: ViewportKey,
sub_viewport_id: ptypes.SubViewportID,

pub fn init(key: ViewportKey, sub_viewport_id: ptypes.SubViewportID) SubViewport {
    return .{
        .key = key,
        .sub_viewport_id = sub_viewport_id,
    };
}

const std = @import("std");
const ptypes = @import("protocol").types;
const ClientID = @import("server/Clients.zig").ClientID;
const Compositor = @import("Compositor.zig");
const ViewportKey = ptypes.ViewportKey;
const WindowID = Compositor.WindowID;
const ViewportID = ptypes.ViewportID;
const log = std.log.scoped(.Wayland);
const c_linux = @import("c_linux");
const Window = @import("Window.zig");
const Buffer = @import("ClientResources.zig").Buffer;
const Viewport = @import("Viewport.zig");
