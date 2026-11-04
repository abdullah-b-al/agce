const ClientResources = @This();

client_uuid: ClientUUID,
wl_buffers_pending: std.array_hash_map.Auto(BufferID, void),

buffers_commited: std.array_hash_map.Auto(BufferID, BufferCommitted),

buffers: std.array_hash_map.Auto(BufferID, Buffer),

next_viewport_id: ViewportID,
next_buffer_id: BufferID,

viewports: std.array_hash_map.Auto(ViewportID, *Viewport),
viewports_pending: std.array_hash_map.Auto(ViewportID, void),
remote_viewports_pending: std.array_hash_map.Auto(RemoteViewportID, RemoteViewportPending),

gbm_bos: std.array_hash_map.Auto(BufferID, GbmBo),

pub fn init(id: ClientUUID) ClientResources {
    return .{
        .client_uuid = id,
        .wl_buffers_pending = .empty,
        .buffers_commited = .empty,
        .buffers = .empty,
        .next_viewport_id = .first_for_server,
        .next_buffer_id = .first,
        .viewports = .empty,
        .viewports_pending = .empty,
        .remote_viewports_pending = .empty,
        .gbm_bos = .empty,
    };
}

pub fn deinit(rs: *ClientResources, com: *Compositor) void {
    var i = rs.buffers.count();
    while (i > 0) {
        i -= 1;
        rs.buffer_destroy(com, rs.buffers.keys()[i]);
    }

    for (rs.viewports.values()) |vp| vp.destroy(com.gpa);

    if (constants.os_has_gbm) {
        for (rs.gbm_bos.values()) |*bo| bo.deinit(com.gbm);
    }

    inline for (.{
        &rs.wl_buffers_pending,
        &rs.buffers_commited,
        &rs.buffers,
        &rs.viewports,
        &rs.viewports_pending,
        &rs.remote_viewports_pending,
        &rs.gbm_bos,
    }) |entry| {
        entry.deinit(com.gpa);
    }
}

pub fn buffer_destroy(rs: *ClientResources, com: *Compositor, id: BufferID) void {
    const buffer = rs.buffers.getPtr(id) orelse return;

    switch (com.native_tag()) {
        .wayland => |tag| {
            const b = tag.buffer(buffer);
            if (rs.gbm_bos.getPtr(id)) |bo| {
                bo.deinit(com.gbm);
            }
            _ = rs.gbm_bos.orderedRemove(id);
            b.destroy();
        },
        .win32 => |tag| {
            tag.guard();
            buffer.deinit();
        },
    }

    _ = rs.buffers.orderedRemove(id);
}

pub fn remote_viewports_pending_fetch_remove_by_embeded_key(rs: *ClientResources, key: ViewportKey) ?RemoteViewportPending {
    const id = blk: {
        for (rs.remote_viewports_pending.values()) |remote| {
            if (std.meta.eql(remote.to_embed, key)) {
                break :blk remote.remote_viewport_id;
            }
        }

        return null;
    };

    return rs.remote_viewports_pending.fetchOrderedRemove(id).?.value;
}

pub fn viewport_create(
    rs: *ClientResources,
    com: *Compositor,
    parent: Compositor.ParentOfViewport,
    viewport_id: ViewportID,
    window_id: WindowID,
    rect: ptypes.Rect,
    render_size: ptypes.Size,
    create_sync_timeline: bool,
    parent_key: ?ViewportKey,
    format: ptypes.BufferFormat,
) !void {
    try rs.viewports.ensureUnusedCapacity(com.gpa, 1);
    const vp = try Viewport.create(
        com,
        parent,
        .{ .client_uuid = rs.client_uuid, .viewport_id = viewport_id },
        window_id,
        rect,
        render_size,
        parent_key,
        create_sync_timeline,
        format,
    );

    rs.viewports.putAssumeCapacity(viewport_id, vp);
}

pub fn viewport_key_from_remote_viewport_id(rs: *const ClientResources, id: RemoteViewportID) ?ViewportKey {
    for (rs.viewports.values()) |vp| {
        for (vp.remote_viewports.keys(), vp.remote_viewports.values()) |k, v| {
            if (k == id) return v;
        }
    }

    return null;
}

pub const RemoteViewportPending = struct {
    remote_viewport_id: RemoteViewportID,
    clip_rect: ptypes.Rect,
    to_embed: ViewportKey,
    embed_in: EmbedIn,

    pub const EmbedIn = union(enum) {
        viewport: ViewportID,
        window: WindowID,

        pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
            switch (self) {
                inline else => |v| try writer.print("{f}", .{v}),
            }
        }
    };
};

pub const GbmBo = if (!constants.os_has_gbm) void else struct {
    bo: *c_linux.struct_gbm_bo,
    acquire: ptypes.DrmSyncobjAcquireTimelineHandle,
    release: ptypes.DrmSyncobjReleaseTimelineHandle,

    pub fn init(gbm: Compositor.Gbm, size: ptypes.Size, format: ptypes.BufferFormat) !GbmBo {
        const bo_format = switch (format) {
            .argb8888 => c_linux.GBM_BO_FORMAT_ARGB8888,
        };

        const bo = c_linux.gbm_bo_create(
            gbm.device,
            @intCast(size.width),
            @intCast(size.height),
            bo_format,
            c_linux.GBM_BO_USE_RENDERING,
        ) orelse return error.FailedToGbmBoCreate;
        errdefer c_linux.gbm_bo_destroy(bo);

        var acquire: u32 = undefined;
        const create_acquire = c_linux.drmSyncobjCreate(gbm.dri.handle, 0, &acquire);
        if (create_acquire != 0) {
            return error.FailedToCreateSyncobj;
        }

        errdefer _ = c_linux.drmSyncobjDestroy(gbm.dri.handle, acquire);

        var release: u32 = undefined;
        const create_release = c_linux.drmSyncobjCreate(gbm.dri.handle, 0, &release);
        if (create_release != 0) {
            return error.FailedToCreateSyncobj;
        }

        return .{
            .bo = bo,
            .acquire = @enumFromInt(acquire),
            .release = @enumFromInt(release),
        };
    }

    pub fn deinit(bo: *GbmBo, gbm: Compositor.Gbm) void {
        _ = c_linux.drmSyncobjDestroy(gbm.dri.handle, @intFromEnum(bo.acquire));
        _ = c_linux.drmSyncobjDestroy(gbm.dri.handle, @intFromEnum(bo.release));
        c_linux.gbm_bo_destroy(bo.bo);
    }

    pub fn acquire_fd(bo: *const GbmBo, gbm: Compositor.Gbm) ptypes.DrmSyncobjAcquireTimelineFd {
        return @enumFromInt(
            gbm.syncobj_fd_from_handle(
                @intFromEnum(bo.acquire),
            ),
        );
    }

    pub fn release_fd(bo: *const GbmBo, gbm: Compositor.Gbm) ptypes.DrmSyncobjReleaseTimelineFd {
        return @enumFromInt(
            gbm.syncobj_fd_from_handle(
                @intFromEnum(bo.release),
            ),
        );
    }

    pub fn signal_release_timeline(bo: *const GbmBo, gbm: Compositor.Gbm, point: ptypes.ReleaseTimelinePoint) void {
        const handles = @intFromEnum(bo.release);
        var points = @intFromEnum(point);

        const result = c_linux.drmSyncobjTimelineSignal(
            gbm.dri.handle,
            &handles,
            &points,
            1,
        );

        // TODO: error handle
        std.debug.assert(result == 0);
    }
};

pub const BufferCommitted = struct {
    viewport_id: ViewportID,
    ptr: *ServeQueue.Node,
};

const std = @import("std");
const cwl = @import("wayland").client.wl;
const xdg = @import("wayland").client.xdg;
const zwp = @import("wayland").client.zwp;
const wp = @import("wayland").client.wp;
const Wayland = @import("wayland/Wayland.zig");
const ptypes = @import("protocol").types;
const BufferFormat = ptypes.BufferFormat;
const BufferAndTimelineFds = ptypes.BufferAndTimelineFds;
const c_linux = @import("c_linux");
const log = std.log.scoped(.ClientResources);
const ViewportKey = ptypes.ViewportKey;
const WindowID = @import("Compositor.zig").WindowID;
const BufferKey = @import("Compositor.zig").BufferKey;
const Compositor = @import("Compositor.zig");
const BufferID = ptypes.BufferID;
const ViewportID = ptypes.ViewportID;
const RemoteViewportID = ptypes.RemoteViewportID;
const ClientUUID = ptypes.ClientUUID;
const Viewport = @import("Viewport.zig");
const Buffer = @import("Buffer.zig");
const constants = @import("constants");
const ServeQueue = @import("server/EventQueue.zig");
