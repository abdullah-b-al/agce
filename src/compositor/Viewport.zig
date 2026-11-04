const Viewport = @This();

id: ViewportID,
window_id: WindowID,
clipping_rect: ptypes.Rect,
render_size: ptypes.Size,
state: ptypes.ViewportDisplayState,
parent_key: ?ViewportKey,
remote_viewports: std.ArrayList(ViewportKey),
format: ptypes.BufferFormat,
cursor_shape: ptypes.CursorShape,

win32: if (os == .windows) Win32.Viewport else void,
linux: if (os == .linux) Linux else void,

pub fn create(
    com: *Compositor,
    parent: ParentOfViewport,
    key: ViewportKey,
    window_id: WindowID,
    clipping_rect: ptypes.Rect,
    render_size: ptypes.Size,
    parent_key: ?ViewportKey,
    create_sync_timeline: bool,
    format: ptypes.BufferFormat,
) !*Viewport {
    const vp = try com.gpa.create(Viewport);
    errdefer com.gpa.destroy(vp);

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
        .remote_viewports = .empty,
        .format = format,
        .cursor_shape = .default,

        .win32 = undefined,
        .linux = undefined,
    };

    switch (com.native_tag()) {
        .wayland => |tag| {
            const wl = tag.compositor(com);
            vp.linux = .{
                .wayland = try .init(
                    com,
                    wl,
                    vp,
                    parent,
                    key.client_uuid,
                    create_sync_timeline,
                ),
            };
        },
        .win32 => |tag| {
            const win32 = tag.compositor(com);
            vp.win32 = try .init(com, win32, vp, parent, key.client_uuid);
        },
    }

    return vp;
}

pub fn destroy(vp: *Viewport, gpa: std.mem.Allocator) void {
    // Remote viewports should be closed before calling deinit
    std.debug.assert(vp.remote_viewports.items.len == 0);
    // If the viewport is a remote viewport we must inform the parent then set to null
    std.debug.assert(vp.parent_key == null);

    vp.remote_viewports.deinit(gpa);

    switch (vp.native_tag()) {
        .wayland => |tag| {
            const nvp = tag.viewport(vp);
            nvp.deinit();
        },
        .win32 => |tag| {
            const nvp = tag.viewport(vp);
            nvp.deinit();
        },
    }

    gpa.destroy(vp);
}

pub fn remote_viewport_remove(vp: *Viewport, key: ViewportKey) void {
    for (vp.remote_viewports.items, 0..) |rk, i| {
        if (std.meta.eql(rk, key)) {
            _ = vp.remote_viewports.orderedRemove(i);
            return;
        }
    }
}

pub fn native_tag(vp: *Viewport) Compositor.NativeTag {
    return switch (os) {
        .linux => switch (vp.linux) {
            .wayland => .wayland,
        },
        .windows => .win32,
        else => comptime unreachable,
    };
}

pub fn should_be_hidden(vp: *Viewport, com: *Compositor) bool {
    if (vp.state == .hidden) return true;

    var maybe_parent = com.viewport_from_key(vp.parent_key orelse return false);

    while (maybe_parent) |parent| {
        if (parent.state == .hidden) return true;

        maybe_parent = com.viewport_from_key(parent.parent_key orelse return false);
    }

    return false;
}

pub const Linux = union(enum) {
    wayland: Wayland.Viewport,
};

const std = @import("std");
const ptypes = @import("protocol").types;
const ClientUUID = @import("server/Clients.zig").ClientUUID;
const Compositor = @import("Compositor.zig");
const ViewportKey = ptypes.ViewportKey;
const WindowID = Compositor.WindowID;
const ViewportID = ptypes.ViewportID;
const log = std.log.scoped(.Wayland);
const c_linux = @import("c_linux");
const Wayland = @import("wayland/Wayland.zig");
const Buffer = @import("ClientResources.zig").Buffer;
const ParentOfViewport = Compositor.ParentOfViewport;
const os = @import("builtin").os.tag;
const Win32 = @import("win32/Win32.zig");
