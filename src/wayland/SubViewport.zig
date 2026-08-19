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
const cwl = @import("wayland").client.wl;
const xdg = @import("wayland").client.xdg;
const zwp = @import("wayland").client.zwp;
const wp = @import("wayland").client.wp;
const ptypes = @import("protocol").types;
const ClientID = @import("../server/Clients.zig").ClientID;
const WindowSystem = @import("../WindowSystem.zig");
const ViewportKey = WindowSystem.ViewportKey;
const WindowID = WindowSystem.WindowID;
const ViewportID = ptypes.ViewportID;
const log = std.log.scoped(.Wayland);
const c_linux = @import("c_linux");
const Wayland = @import("Wayland.zig");
const Window = @import("Window.zig");
const Buffer = @import("ClientResources.zig").Buffer;
const Viewport = @import("Viewport.zig");
