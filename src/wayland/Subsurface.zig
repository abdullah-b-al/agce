const Subsurface = @This();

subsurface: *cwl.Subsurface,
surface: *cwl.Surface,
viewport: *wp.Viewport,
sync_surface: ?*wp.LinuxDrmSyncobjSurfaceV1,
viewport_key: ViewportKey,

pub fn init(wl: *Wayland, parent_surface: *cwl.Surface, key: ViewportKey) !Subsurface {
    const surface = try wl.compositor.createSurface();
    errdefer surface.destroy();

    const subsurface = try wl.subcompositor.getSubsurface(surface, parent_surface);
    const viewport = try wl.viewporter.getViewport(surface);

    return .{
        .surface = surface,
        .subsurface = subsurface,
        .sync_surface = null,
        .viewport = viewport,
        .viewport_key = key,
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

const std = @import("std");
const cwl = @import("wayland").client.wl;
const xdg = @import("wayland").client.xdg;
const zwp = @import("wayland").client.zwp;
const wp = @import("wayland").client.wp;
const ClientID = @import("../server/Clients.zig").ClientID;
const WindowSystem = @import("../WindowSystem.zig");
const ViewportKey = WindowSystem.ViewportKey;
const WindowID = WindowSystem.WindowID;
const log = std.log.scoped(.Wayland);
const utils = @import("../server/utils.zig");
const ptypes = @import("../protocol/types.zig");
const Buffers = @import("Buffers.zig");
const c_linux = @import("c_linux");
const DoubleBuffer = Buffers.DoubleBuffer;
const BufferID = Buffers.BufferID;
const Wayland = @import("Wayland.zig");
