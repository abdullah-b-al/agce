const Viewport = @This();

base: *const Compositor.Viewport,

refresh_cycle: u32,
surface: *cwl.Surface,
subsurface: Subsurface,
viewport: *wp.Viewport,

pub const InitError = error{
    OutOfMemory,
};
pub fn init(
    com: *Compositor,
    wl: *Wayland,
    base: *const Compositor.Viewport,
    parent: ParentOfViewport,
    client_uuid: ClientUUID,
) !Viewport {
    const surface = try wl.compositor.createSurface();
    errdefer surface.destroy();

    const parent_surface = switch (parent) {
        .window => |handle| handle.cast(.wayland),
        .viewport => |vp| vp.linux.wayland.surface,
    };
    const subsurface = try wl.subcompositor.getSubsurface(surface, parent_surface);
    subsurface.setDesync();
    const viewport = try wl.viewporter.getViewport(surface);

    viewport.setSource(
        .fromInt(0),
        .fromInt(0),
        .fromInt(@intCast(@min(base.render_size.width, base.clipping_rect.width))),
        .fromInt(@intCast(@min(base.render_size.height, base.clipping_rect.height))),
    );

    subsurface.setPosition(
        @intCast(base.clipping_rect.x),
        @intCast(base.clipping_rect.y),
    );

    try Wayland.frame_listener_set(com, surface, .{ .client_uuid = client_uuid, .viewport_id = base.id });

    return .{
        .base = base,
        .surface = surface,
        .subsurface = .init(subsurface),
        .viewport = viewport,
        .refresh_cycle = 0,
    };
}

pub fn deinit(vp: *Viewport) void {
    vp.viewport.destroy();
    vp.subsurface.subsurface.destroy();
    vp.surface.destroy();
}

pub fn remote_viewport_id_from_key(vp: *Viewport, key: ViewportKey) ?ptypes.RemoteViewportID {
    for (vp.remote_viewports.keys(), vp.remote_viewports.values()) |id, k| {
        if (std.meta.eql(key, k)) {
            return id;
        }
    }

    return null;
}

pub fn min_source_size(vp: *const Viewport, window_size: ptypes.Size) ptypes.Size {
    const width = @min(
        vp.base.render_size.width,
        vp.base.clipping_rect.width,
        window_size.width,
    );

    const height = @min(
        vp.base.render_size.height,
        vp.base.clipping_rect.height,
        window_size.height,
    );

    return .{
        .width = @max(1, width),
        .height = @max(1, height),
    };
}

pub fn min_source_size_with_buffer(vp: *const Viewport, window_size: ptypes.Size, buffer: *Buffer) ptypes.Size {
    const size = vp.min_source_size(window_size);
    return .{
        .width = @max(
            1,
            @min(size.width, buffer.width()),
        ),
        .height = @max(
            1,
            @min(size.height, buffer.height()),
        ),
    };
}

pub const Subsurface = struct {
    subsurface: *cwl.Subsurface,

    pub fn init(subsurface: *cwl.Subsurface) Subsurface {
        return .{
            .subsurface = subsurface,
        };
    }

    pub fn set_position(s: *Subsurface, x: i32, y: i32) void {
        s.subsurface.setPosition(x, y);
    }
};

const std = @import("std");
const cwl = @import("wayland").client.wl;
const xdg = @import("wayland").client.xdg;
const zwp = @import("wayland").client.zwp;
const wp = @import("wayland").client.wp;
const ptypes = @import("protocol").types;
const ClientUUID = ptypes.ClientUUID;
const Compositor = @import("../Compositor.zig");
const ParentOfViewport = Compositor.ParentOfViewport;
const ViewportKey = ptypes.ViewportKey;
const WindowID = Compositor.WindowID;
const ViewportID = ptypes.ViewportID;
const log = std.log.scoped(.Wayland);
const c_linux = @import("c_linux");
const Wayland = @import("Wayland.zig");
const Buffer = Wayland.Buffer;
