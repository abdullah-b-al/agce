const Viewport = @This();

id: ViewportID,
window_id: WindowID,
clipping_rect: ptypes.Rect,
render_size: ptypes.Size,
state: ptypes.ViewportDisplayState,
parent_key: ?ViewportKey,
sub_viewports: std.array_hash_map.Auto(ptypes.SubViewportID, ViewportKey),

win32: if (os == .windows) Win32.Viewport else void,
linux: if (os == .linux) Linux else void,

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

        .win32 = undefined,
        .linux = undefined,
    };

    switch (ws.native_tag()) {
        .wayland => |tag| {
            const wl = tag.window_system(ws);
            vp.linux = .{
                .wayland = try .init(
                    ws,
                    wl,
                    vp,
                    parent,
                    key.client_id,
                    create_sync_timeline,
                ),
            };
        },
        .win32 => |tag| {
            const win32 = tag.window_system(ws);
            vp.win32 = try .init(ws, win32, vp, parent, key.client_id);
        },
    }

    return vp;
}

pub fn destroy(vp: *Viewport, gpa: std.mem.Allocator) void {
    // Sub-viewports should be closed before calling deinit
    std.debug.assert(vp.sub_viewports.count() == 0);
    // If the viewport is a sub-viewport we must inform the parent then set to null
    std.debug.assert(vp.parent_key == null);

    vp.sub_viewports.deinit(gpa);

    switch (vp.native_tag()) {
        .wayland => |tag| {
            const nvp = tag.viewport(vp);
            if (nvp.sync_surface) |sync| {
                sync.destroy();
            }
            nvp.viewport.destroy();
            nvp.subsurface.subsurface.destroy();
            nvp.surface.destroy();
        },
        .win32 => |tag| {
            tag.guard();
            @panic("TODO");
        },
    }

    gpa.destroy(vp);
}

pub fn native_tag(vp: *Viewport) WindowSystem.NativeTag {
    return switch (os) {
        .linux => switch (vp.linux) {
            .wayland => .wayland,
        },
        .windows => .win32,
        else => comptime unreachable,
    };
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
const os = @import("builtin").os.tag;
const Win32 = @import("../win32/Win32.zig");
