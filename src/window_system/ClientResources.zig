const ClientResources = @This();

client_id: ClientID,
wl_buffers_pending: std.array_hash_map.Auto(BufferID, void),

buffers_commited: std.array_hash_map.Auto(BufferID, ViewportID),

buffers: std.array_hash_map.Auto(BufferID, Buffer),

next_viewport_id: ViewportID,
viewports: std.array_hash_map.Auto(ViewportID, *Viewport),
viewports_pending: std.array_hash_map.Auto(ViewportID, void),
sub_viewports_pending: std.array_hash_map.Auto(SubViewportID, SubViewportPending),

pub fn init(id: ClientID) ClientResources {
    return .{
        .client_id = id,
        .wl_buffers_pending = .empty,
        .buffers_commited = .empty,
        .buffers = .empty,
        .next_viewport_id = .first_for_server,
        .viewports = .empty,
        .viewports_pending = .empty,
        .sub_viewports_pending = .empty,
    };
}

pub fn deinit(rs: *ClientResources, ws: *WindowSystem) void {
    var i = rs.buffers.count();
    while (i > 0) {
        i -= 1;
        rs.buffer_destroy(ws, rs.buffers.keys()[i]);
    }

    for (rs.viewports.values()) |vp| vp.destroy(ws.gpa);

    inline for (.{
        &rs.wl_buffers_pending,
        &rs.buffers_commited,
        &rs.buffers,
        &rs.viewports,
        &rs.viewports_pending,
        &rs.sub_viewports_pending,
    }) |entry| {
        entry.deinit(ws.gpa);
    }
}

pub fn buffer_destroy(rs: *ClientResources, ws: *WindowSystem, id: BufferID) void {
    const buffer = rs.buffers.getPtr(id) orelse return;

    switch (WindowSystem.Native) {
        WindowSystem.Linux => {
            switch (ws.native) {
                .wayland => |wl| {
                    _ = wl.wl_buffers.orderedRemove(.from_wl_buffer(buffer.wayland.wl_buffer()));
                    buffer.wayland.destroy();
                },
            }
        },
        else => unreachable,
    }

    _ = rs.buffers.orderedRemove(id);
}

pub fn sub_viewports_pending_fetch_remove_by_embeded_key(rs: *ClientResources, key: ViewportKey) ?SubViewportPending {
    const id = blk: {
        for (rs.sub_viewports_pending.values()) |sub| {
            if (std.meta.eql(sub.to_embed, key)) {
                break :blk sub.sub_viewport_id;
            }
        }

        return null;
    };

    return rs.sub_viewports_pending.fetchOrderedRemove(id).?.value;
}

pub fn viewport_create(
    rs: *ClientResources,
    ws: *WindowSystem,
    parent: WindowSystem.ParentOfViewport,
    viewport_id: ViewportID,
    window_id: WindowID,
    rect: ptypes.Rect,
    render_size: ptypes.Size,
    create_sync_timeline: bool,
    parent_key: ?ViewportKey,
) !void {
    try rs.viewports.ensureUnusedCapacity(ws.gpa, 1);
    const vp = try Viewport.create(
        ws,
        parent,
        .{ .client_id = rs.client_id, .viewport_id = viewport_id },
        window_id,
        rect,
        render_size,
        parent_key,
        create_sync_timeline,
    );

    rs.viewports.putAssumeCapacity(viewport_id, vp);
}

pub fn viewport_key_from_sub_viewport_id(rs: *const ClientResources, id: SubViewportID) ?ViewportKey {
    for (rs.viewports.values()) |vp| {
        for (vp.sub_viewports.keys(), vp.sub_viewports.values()) |k, v| {
            if (k == id) return v;
        }
    }

    return null;
}

pub const SubViewportPending = struct {
    sub_viewport_id: SubViewportID,
    clip_rect: ptypes.Rect,
    to_embed: ViewportKey,
    embed_in: ViewportID,
};

const std = @import("std");
const cwl = @import("wayland").client.wl;
const xdg = @import("wayland").client.xdg;
const zwp = @import("wayland").client.zwp;
const wp = @import("wayland").client.wp;
const Wayland = @import("../wayland/Wayland.zig");
const ptypes = @import("protocol").types;
const BufferFormat = ptypes.BufferFormat;
const BufferAndTimelineFds = ptypes.BufferAndTimelineFds;
const c_linux = @import("c_linux");
const log = std.log.scoped(.ClientResources);
const ViewportKey = @import("../WindowSystem.zig").ViewportKey;
const WindowID = @import("../WindowSystem.zig").WindowID;
const BufferKey = @import("../WindowSystem.zig").BufferKey;
const WindowSystem = @import("../WindowSystem.zig");
const BufferID = ptypes.BufferID;
const ViewportID = ptypes.ViewportID;
const SubViewportID = ptypes.SubViewportID;
const CpuBufferFd = ptypes.CpuBufferFd;
const ClientID = ptypes.ClientID;
const Dispatch = @import("../Dispatch.zig");
const Viewport = @import("Viewport.zig");
const Buffer = @import("buffer.zig").Buffer;
