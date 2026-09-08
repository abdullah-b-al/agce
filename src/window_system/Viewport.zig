const Viewport = @This();

id: ViewportID,
window_id: WindowID,
clipping_rect: ptypes.Rect,
render_size: ptypes.Size,
state: ptypes.ViewportDisplayState,
parent_key: ?ViewportKey,
sub_viewports: std.array_hash_map.Auto(ptypes.SubViewportID, ViewportKey),

native: Native,

pub fn create(
    ws: *WindowSystem,
    parent: ParentOfViewport,
    key: ViewportKey,
    window_id: WindowID,
    clipping_rect: ptypes.Rect,
    render_size: ptypes.Size,
    parent_key: ?ViewportKey,
    create_sync_timeline: bool,
) !*Viewport {
    const vp = try ws.gpa.create(Viewport);
    errdefer ws.gpa.destroy(vp);

    if (parent_key) |p| {
        std.debug.assert(key.viewport_id.is_server_id());
        std.debug.assert(!std.meta.eql(p, key));
    }

    vp.* = .{
        .id = key.viewport_id,
        .window_id = window_id,
        .parent_key = parent_key,
        .state = .shown,
        .clipping_rect = clipping_rect,
        .render_size = render_size,
        .sub_viewports = .empty,

        .native = undefined,
    };

    vp.native = switch (WindowSystem.Native) {
        WindowSystem.Linux => switch (ws.native) {
            .wayland => |wl| .{
                .wayland = try .init(
                    ws,
                    wl,
                    vp,
                    parent,
                    key.client_id,
                    create_sync_timeline,
                ),
            },
        },
        else => comptime unreachable,
    };

    return vp;
}

pub fn destroy(vp: *Viewport, gpa: std.mem.Allocator) void {
    // Sub-viewports should be closed before calling deinit
    std.debug.assert(vp.sub_viewports.count() == 0);
    // If the viewport is a sub-viewport we must inform the parent then set to null
    std.debug.assert(vp.parent_key == null);

    vp.sub_viewports.deinit(gpa);

    switch (WindowSystem.Native) {
        WindowSystem.Linux => {
            switch (vp.native) {
                .wayland => |*wl_vp| {
                    if (wl_vp.sync_surface) |sync| {
                        sync.destroy();
                    }
                    wl_vp.viewport.destroy();
                    wl_vp.subsurface.subsurface.destroy();
                    wl_vp.surface.destroy();
                },
            }
        },
        else => comptime unreachable,
    }

    gpa.destroy(vp);
}

pub fn sub_viewport_id_from_key(vp: *Viewport, key: ViewportKey) ?ptypes.SubViewportID {
    for (vp.sub_viewports.keys(), vp.sub_viewports.values()) |id, k| {
        if (std.meta.eql(key, k)) {
            return id;
        }
    }

    return null;
}

pub const Linux = union(enum) {
    wayland: Wayland.Viewport,
};

pub const Native = switch (WindowSystem.Native) {
    WindowSystem.Linux => Linux,
    WindowSystem.W32 => void,
    else => unreachable,
};

const std = @import("std");
const ptypes = @import("protocol").types;
const ClientID = @import("../server/Clients.zig").ClientID;
const WindowSystem = @import("../WindowSystem.zig");
const ViewportKey = WindowSystem.ViewportKey;
const WindowID = WindowSystem.WindowID;
const ViewportID = ptypes.ViewportID;
const log = std.log.scoped(.Wayland);
const c_linux = @import("c_linux");
const Wayland = @import("../wayland/Wayland.zig");
const Window = @import("Window.zig");
const Buffer = @import("ClientResources.zig").Buffer;
const SubViewport = @import("SubViewport.zig");
const ParentOfViewport = WindowSystem.ParentOfViewport;
