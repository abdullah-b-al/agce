const Viewport = @This();

base: *const Compositor.Viewport,

refresh_cycle: u32,
surface: *cwl.Surface,
pointer: Pointer,
subsurface: Subsurface,
viewport: *wp.Viewport,
sync_surface: ?*wp.LinuxDrmSyncobjSurfaceV1,

pub fn init(
    com: *Compositor,
    wl: *Wayland,
    base: *const Compositor.Viewport,
    parent: ParentOfViewport,
    client_id: ClientID,
    create_sync_timeline: bool,
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

    const sync_surface = if (create_sync_timeline)
        try wl.sync_object_manager.getSurface(surface)
    else
        null;

    try Wayland.frame_listener_set(com, surface, .{ .client_id = client_id, .viewport_id = base.id });

    return .{
        .base = base,
        .surface = surface,
        .pointer = .init,
        .subsurface = .init(subsurface),
        .sync_surface = sync_surface,
        .viewport = viewport,
        .refresh_cycle = 0,
    };
}

pub fn deinit(vp: *Viewport) void {
    if (vp.sync_surface) |sync| {
        sync.destroy();
    }
    vp.viewport.destroy();
    vp.subsurface.subsurface.destroy();
    vp.surface.destroy();
}

pub fn sub_viewport_id_from_key(vp: *Viewport, key: ViewportKey) ?ptypes.SubViewportID {
    for (vp.sub_viewports.keys(), vp.sub_viewports.values()) |id, k| {
        if (std.meta.eql(key, k)) {
            return id;
        }
    }

    return null;
}

pub fn min_source_size(vp: *const Viewport, win: Compositor.Window) ptypes.Size {
    const width = @min(
        vp.base.render_size.width,
        vp.base.clipping_rect.width,
        win.size.width,
    );

    const height = @min(
        vp.base.render_size.height,
        vp.base.clipping_rect.height,
        win.size.height,
    );

    return .{
        .width = @max(1, width),
        .height = @max(1, height),
    };
}

pub fn min_source_size_with_buffer(vp: *const Viewport, win: Compositor.Window, buffer: *Buffer) ptypes.Size {
    const size = vp.min_source_size(win);
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

pub const AcquireTimeline = struct {
    acquire: *wp.LinuxDrmSyncobjTimelineV1,

    pub fn init(m: *wp.LinuxDrmSyncobjManagerV1, acquire: ptypes.DrmSyncobjAcquireTimelineFd) !AcquireTimeline {
        return .{
            .acquire = try m.importTimeline(@intFromEnum(acquire)),
        };
    }

    pub fn set(t: AcquireTimeline, sync_surface: *wp.LinuxDrmSyncobjSurfaceV1, point: ptypes.AcquireTimelinePoint) void {
        const int = @intFromEnum(point);
        const lo: u32 = @truncate(int & 0xFF_FF_FF_FF);
        const hi: u32 = @truncate(int >> 32);
        sync_surface.setAcquirePoint(t.acquire, hi, lo);
    }
};

pub const ReleaseTimeline = struct {
    release: *wp.LinuxDrmSyncobjTimelineV1,

    pub fn init(m: *wp.LinuxDrmSyncobjManagerV1, release: ptypes.DrmSyncobjReleaseTimelineFd) !ReleaseTimeline {
        return .{
            .release = try m.importTimeline(@intFromEnum(release)),
        };
    }

    pub fn set(t: ReleaseTimeline, sync_surface: *wp.LinuxDrmSyncobjSurfaceV1, point: ptypes.ReleaseTimelinePoint) void {
        const int = @intFromEnum(point);
        const lo: u32 = @truncate(int & 0xFF_FF_FF_FF);
        const hi: u32 = @truncate(int >> 32);
        sync_surface.setReleasePoint(t.release, hi, lo);
    }
};

pub const Pointer = struct {
    pointer: ?*cwl.Pointer,
    shaper: ?*wp.CursorShapeDeviceV1,
    enter_serial: ?u32,

    pub const init: Pointer = .{ .pointer = null, .shaper = null, .enter_serial = null };

    pub fn on_surface_enter(
        p: *Pointer,
        cursor_manager: *wp.CursorShapeManagerV1,
        wl_pointer: *cwl.Pointer,
        enter_serial: u32,
    ) void {
        if (p.pointer != wl_pointer) {
            p.pointer = null;

            if (p.shaper) |shaper| {
                shaper.destroy();
                p.shaper = null;
            }
        }

        p.pointer = wl_pointer;

        if (p.shaper == null) {
            p.shaper = cursor_manager.getPointer(wl_pointer) catch null;
        }

        p.enter_serial = enter_serial;
    }

    pub fn set_shape(p: *Pointer, shape: wp.CursorShapeDeviceV1.Shape) void {
        if (p.shaper) |shaper| {
            const serial = p.enter_serial orelse return;
            shaper.setShape(serial, shape);
        }
    }
};

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
const ClientID = ptypes.ClientID;
const Compositor = @import("../Compositor.zig");
const ParentOfViewport = Compositor.ParentOfViewport;
const ViewportKey = Compositor.ViewportKey;
const WindowID = Compositor.WindowID;
const ViewportID = ptypes.ViewportID;
const log = std.log.scoped(.Wayland);
const c_linux = @import("c_linux");
const Wayland = @import("Wayland.zig");
const Buffer = Wayland.Buffer;
