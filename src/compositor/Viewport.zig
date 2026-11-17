const Viewport = @This();

id: ViewportID,
window_id: WindowID,
clipping_rect: ptypes.Rect,
render_size: ptypes.Size,
state: ptypes.ViewportDisplayState,
parent_key: ?ViewportKey,
remote_viewports: std.ArrayList(ViewportKey),
format: ptypes.BufferFormat,
buffer_type: ptypes.BufferType,
cursor_shape: ptypes.CursorShape,

win32: if (os == .windows) Win32.Viewport else void,
linux: if (os == .linux) Linux else void,

memory_reserve_for_destroy: MemoryReserveForDestroy,

pub const CreateError = Wayland.Viewport.InitError || Win32.Viewport.InitError;

pub fn create(args: CreateArgs) CreateError!*Viewport {
    const vp = try args.com.gpa.create(Viewport);
    errdefer args.com.gpa.destroy(vp);

    if (args.parent_key) |p| {
        const is_server_id = args.key.viewport_id.is_server_id();
        const is_same_client = p.client_uuid == args.key.client_uuid;

        std.debug.assert(
            is_server_id or is_same_client,
        );

        std.debug.assert(!std.meta.eql(p, args.key));
    }

    vp.* = .{
        .id = args.key.viewport_id,
        .window_id = args.window_id,
        .parent_key = args.parent_key,
        .state = .shown,
        .clipping_rect = args.clipping_rect,
        .render_size = args.render_size,
        .remote_viewports = .empty,
        .format = args.format,
        .buffer_type = args.buffer_type,
        .cursor_shape = .default,

        .win32 = undefined,
        .linux = undefined,

        .memory_reserve_for_destroy = args.reserve,
    };

    switch (args.com.backend_tag()) {
        .wayland => |tag| {
            const wl = tag.compositor(args.com);

            vp.linux = .{
                .wayland = try .init(
                    args.com,
                    wl,
                    vp,
                    args.parent,
                    args.key.client_uuid,
                ),
            };
        },
        .win32 => |tag| {
            const win32 = tag.compositor(args.com);
            vp.win32 = try .init(args.com, win32, vp, args.parent, args.key.client_uuid);
        },
    }

    return vp;
}

pub fn destroy(vp: *Viewport, gpa: std.mem.Allocator) void {
    std.debug.assert(vp.memory_reserve_for_destroy.released);
    // Remote viewports should be closed before calling deinit
    std.debug.assert(vp.remote_viewports.items.len == 0);
    // If the viewport is a remote viewport we must inform the parent then set to null
    std.debug.assert(vp.parent_key == null);

    vp.remote_viewports.deinit(gpa);

    switch (vp.backend_tag()) {
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

pub fn backend_tag(vp: *Viewport) Compositor.BackendTag {
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

pub const MemoryReserveForDestroy = struct {
    pub const server_events_len = 5;
    server_events: [5]*ServerQueue.Node,
    released: bool,

    pub fn init(com: *Compositor) !MemoryReserveForDestroy {
        try com.server_events.ensure_unused_capacity(5);
        var nodes: [5]*ServerQueue.Node = undefined;

        for (&nodes) |*node| {
            node.* = com.server_events.create_assume_capacity();
        }

        return .{ .server_events = nodes, .released = false };
    }

    pub fn release(reserve: *MemoryReserveForDestroy, com: *Compositor) void {
        std.debug.assert(!reserve.released);
        for (reserve.server_events) |node| {
            com.server_events.destroy(node);
        }
        reserve.released = true;
        reserve.server_events = undefined;
    }
};

pub const CreateArgs = struct {
    com: *Compositor,
    parent: ParentOfViewport,
    key: ViewportKey,
    window_id: WindowID,
    clipping_rect: ptypes.Rect,
    render_size: ptypes.Size,
    parent_key: ?ViewportKey,
    format: ptypes.BufferFormat,
    buffer_type: ptypes.BufferType,
    reserve: MemoryReserveForDestroy,
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
const ServerQueue = @import("server/EventQueue.zig");
