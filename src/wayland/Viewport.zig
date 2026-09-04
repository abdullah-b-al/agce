const Viewport = @This();

id: ViewportID,
window_id: WindowID,
clipping_rect: ptypes.Rect,
render_size: ptypes.Size,
state: ptypes.ViewportDisplayState,
parent_key: ?ViewportKey,
sub_viewports: std.array_hash_map.Auto(ptypes.SubViewportID, ViewportKey),
refresh_cycle: u32,

surface: *cwl.Surface,
pointer: Pointer,
subsurface: Subsurface,
viewport: *wp.Viewport,
sync_surface: ?*wp.LinuxDrmSyncobjSurfaceV1,

pub fn init(
    wl: *Wayland,
    parent_surface: *cwl.Surface,
    key: ViewportKey,
    window_id: WindowID,
    clipping_rect: ptypes.Rect,
    render_size: ptypes.Size,
    parent: ?ViewportKey,
) !Viewport {
    const surface = try wl.compositor.createSurface();
    errdefer surface.destroy();

    if (parent) |p| {
        std.debug.assert(key.viewport_id.is_server_id());
        std.debug.assert(!std.meta.eql(p, key));
    }

    const subsurface = try wl.subcompositor.getSubsurface(surface, parent_surface);
    subsurface.setDesync();
    const viewport = try wl.viewporter.getViewport(surface);

    viewport.setSource(
        .fromInt(0),
        .fromInt(0),
        .fromInt(@intCast(@min(render_size.width, clipping_rect.width))),
        .fromInt(@intCast(@min(render_size.height, clipping_rect.height))),
    );

    subsurface.setPosition(
        @intCast(clipping_rect.x),
        @intCast(clipping_rect.y),
    );

    return .{
        .id = key.viewport_id,
        .window_id = window_id,
        .surface = surface,
        .pointer = .init,
        .subsurface = .init(subsurface),
        .sync_surface = null,
        .viewport = viewport,
        .parent_key = parent,
        .state = .shown,
        .refresh_cycle = 0,

        .clipping_rect = clipping_rect,
        .render_size = render_size,

        .sub_viewports = .empty,
    };
}

pub fn deinit(vp: *Viewport, gpa: std.mem.Allocator) void {
    // Sub-viewports should be closed before calling deinit
    std.debug.assert(vp.sub_viewports.count() == 0);
    // If the viewport is a sub-viewport we must inform the parent then set to null
    std.debug.assert(vp.parent_key == null);

    vp.sub_viewports.deinit(gpa);

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

pub fn min_source_size(vp: *const Viewport, window: *Window) ptypes.Size {
    const width = @min(
        vp.render_size.width,
        vp.clipping_rect.width,
        window.buffer.size.width,
    );

    const height = @min(
        vp.render_size.height,
        vp.clipping_rect.height,
        window.buffer.size.height,
    );

    return .{
        .width = @max(1, width),
        .height = @max(1, height),
    };
}

pub fn min_source_size_with_buffer(vp: *const Viewport, window: *Window, buffer: *Buffer) ptypes.Size {
    const size = vp.min_source_size(window);
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

    pub fn init(m: *wp.LinuxDrmSyncobjManagerV1, acquire: ptypes.AcquireTimelineFd) !AcquireTimeline {
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

    pub fn init(m: *wp.LinuxDrmSyncobjManagerV1, release: ptypes.ReleaseTimelineFd) !ReleaseTimeline {
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
            const serial = p.enter_serial orelse @panic("Must be set on Pointer.enter event");
            shaper.setShape(serial, shape);
        }
    }
};

pub const Subsurface = struct {
    subsurface: *cwl.Subsurface,
    placement: Placment,

    pub fn init(subsurface: *cwl.Subsurface) Subsurface {
        return .{
            .subsurface = subsurface,
            .placement = .above,
        };
    }

    pub fn set_position(s: *Subsurface, x: i32, y: i32) void {
        s.subsurface.setPosition(x, y);
    }

    pub fn place(s: *Subsurface, p: Placment, surface: *cwl.Surface) void {
        s.placement = p;
        switch (p) {
            .above => s.subsurface.placeAbove(surface),
            .below => s.subsurface.placeBelow(surface),
        }
    }

    const Placment = enum { below, above };
};

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
const SubViewport = @import("SubViewport.zig");
