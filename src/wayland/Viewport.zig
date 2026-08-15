const Viewport = @This();

id: ViewportID,
surface: *cwl.Surface,
pointer: Pointer,
subsurface: *cwl.Subsurface,
viewport: *wp.Viewport,
sync_surface: ?*wp.LinuxDrmSyncobjSurfaceV1,
vsync: bool,

width: i32,
height: i32,

pub fn init(
    wl: *Wayland,
    parent_surface: *cwl.Surface,
    id: ViewportID,
    width: i32,
    height: i32,
    vsync: bool,
) !Viewport {
    const surface = try wl.compositor.createSurface();
    errdefer surface.destroy();

    const subsurface = try wl.subcompositor.getSubsurface(surface, parent_surface);
    subsurface.setDesync();
    const viewport = try wl.viewporter.getViewport(surface);
    viewport.setSource(
        .fromInt(0),
        .fromInt(0),
        .fromInt(@intCast(width)),
        .fromInt(@intCast(height)),
    );

    return .{
        .id = id,
        .surface = surface,
        .pointer = .init,
        .subsurface = subsurface,
        .sync_surface = null,
        .viewport = viewport,
        .vsync = vsync,

        .width = width,
        .height = height,
    };
}

pub fn deinit(vp: *Viewport) void {
    if (vp.sync_surface) |sync| {
        sync.destroy();
    }
    vp.viewport.destroy();
    vp.subsurface.destroy();
    vp.surface.destroy();
}

pub fn set_source(vp: *Viewport, width: i32, height: i32) void {
    vp.width = width;
    vp.height = height;

    vp.viewport.setSource(
        .fromInt(0),
        .fromInt(0),
        .fromInt(@intCast(vp.width)),
        .fromInt(@intCast(vp.height)),
    );
}

pub fn set_source_min(vp: *Viewport, window: *Window, buffer: *Buffer) void {
    const width = @min(
        vp.width,
        buffer.width(),
        window.buffer.width,
    );

    const height = @min(
        vp.height,
        buffer.height(),
        window.buffer.height,
    );

    vp.viewport.setSource(
        .fromInt(0),
        .fromInt(0),
        .fromInt(@intCast(width)),
        .fromInt(@intCast(height)),
    );
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
