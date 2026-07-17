const Subsurface = @This();

subsurface: *cwl.Subsurface,
surface: *cwl.Surface,
viewport_key: ViewportKey,

pub fn create(wl: *Wayland, parent_surface: *cwl.Surface, key: ViewportKey) !Subsurface {
    const surface = try wl.compositor.createSurface();
    errdefer surface.destroy();

    const subsurface = try wl.subcompositor.getSubsurface(surface, parent_surface);

    return .{
        .surface = surface,
        .subsurface = subsurface,
        .viewport_key = key,
    };
}

const std = @import("std");
const cwl = @import("wayland").client.wl;
const xdg = @import("wayland").client.xdg;
const zwp = @import("wayland").client.zwp;
const ClientID = @import("../server/Clients.zig").ClientID;
const WindowSystem = @import("../WindowSystem.zig");
const ViewportKey = WindowSystem.ViewportKey;
const WindowID = WindowSystem.WindowID;
const log = std.log.scoped(.Wayland);
const utils = @import("../server/utils.zig");
const Buffers = @import("Buffers.zig");
const c_linux = @import("c_linux");
const DoubleBuffer = Buffers.DoubleBuffer;
const BufferID = Buffers.BufferID;
const Wayland = @import("Wayland.zig");
