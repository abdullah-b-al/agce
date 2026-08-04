const ClientResources = @This();

client_id: ClientID,
wl_buffers_pending: std.array_hash_map.Auto(BufferID, void),

buffers_commited: std.array_hash_map.Auto(BufferID, ViewportID),

buffers: std.array_hash_map.Auto(BufferID, Buffer),

viewports: std.array_hash_map.Auto(ViewportID, Viewport),

pub fn init(id: ClientID) ClientResources {
    return .{
        .client_id = id,
        .wl_buffers_pending = .empty,
        .buffers_commited = .empty,
        .buffers = .empty,
        .viewports = .empty,
    };
}

pub fn deinit(rs: *ClientResources, wl: *Wayland) void {
    for (rs.buffers.values()) |*buffer| {
        _ = wl.wl_buffers.orderedRemove(.from_wl_buffer(buffer.wl_buffer()));
        buffer.destroy();
    }
    rs.buffers.deinit(wl.gpa);

    rs.wl_buffers_pending.deinit(wl.gpa);
    rs.buffers_commited.deinit(wl.gpa);

    for (rs.viewports.values()) |*vp| vp.deinit();
    rs.viewports.deinit(wl.gpa);
}

pub fn viewport_create(
    rs: *ClientResources,
    wl: *Wayland,
    parent_surface: *cwl.Surface,
    viewport_id: ViewportID,
    width: i32,
    height: i32,
    create_sync_timeline: bool,
) !void {
    try rs.viewports.ensureUnusedCapacity(wl.gpa, 1);
    var vp = try Viewport.init(
        wl,
        parent_surface,
        viewport_id,
    );
    vp.viewport.setSource(.fromInt(0), .fromInt(0), .fromInt(@intCast(width)), .fromInt(@intCast(height)));

    if (create_sync_timeline) {
        const sync_surface = try wl.sync_object_manager.getSurface(vp.surface);
        std.debug.assert(vp.sync_surface == null);
        vp.sync_surface = sync_surface;
    }

    rs.viewports.putAssumeCapacity(viewport_id, vp);
}

pub fn buffer_create_and_register_cpu(
    rs: *ClientResources,
    wl: *Wayland,
    id: BufferID,
    fd: CpuBufferFd,
    width: i32,
    height: i32,
    format: BufferFormat,
) !void {
    try rs.buffers.ensureUnusedCapacity(wl.gpa, 1);
    try wl.buffer_set_listener_prepare();

    const cpu = try buffer_create_cpu(wl.shm, fd, width, height, format);
    wl.buffer_set_listener(rs, cpu.wl_buffer, id);

    rs.buffers.putAssumeCapacityNoClobber(id, .{ .cpu = cpu });
}

pub fn buffer_create_cpu(
    shm: *cwl.Shm,
    fd: CpuBufferFd,
    width: i32,
    height: i32,
    format: BufferFormat,
) !CpuBuffer {
    const stride = width * format.bytes_per_pixel();
    const size = width * height * format.bytes_per_pixel();
    const pool = try shm.createPool(@intFromEnum(fd), size);
    defer pool.destroy();

    const wl_format: cwl.Shm.Format = switch (format) {
        .argb8888 => .argb8888,
    };

    const buffer = try pool.createBuffer(0, width, height, stride, wl_format);

    return .{
        .wl_buffer = buffer,
        .width = width,
        .height = height,
        .format = format,
    };
}

pub fn buffer_create_and_register_gpu_async(
    rs: *ClientResources,
    dispatch: *Dispatch,
    wl: *Wayland,
    id: BufferID,
    fds: BufferAndTimelineFds,
    width: i32,
    height: i32,
    b_format: BufferFormat,
    modifier: u64,
) !void {
    const mod_lo: u32 = @intCast(modifier & 0xFF_FF_FF_FF);
    const mod_hi: u32 = @intCast(modifier >> 32);
    const stride: u32 = @intCast(width * b_format.bytes_per_pixel());
    const format = switch (b_format) {
        .argb8888 => c_linux.DRM_FORMAT_ARGB8888,
    };

    const data = try wl.gpa.create(RegisterGpuBuffer);
    errdefer wl.gpa.destroy(data);

    try rs.wl_buffers_pending.ensureUnusedCapacity(wl.gpa, 1);
    try rs.buffers.ensureUnusedCapacity(wl.gpa, rs.wl_buffers_pending.capacity());
    try wl.buffer_set_listener_prepare();

    std.debug.assert(@intFromEnum(fds.acquire_timeline) != @intFromEnum(fds.release_timeline));
    const timeline_acquire: Viewport.AcquireTimeline =
        try .init(wl.sync_object_manager, fds.acquire_timeline);
    const timeline_release: Viewport.ReleaseTimeline =
        try .init(wl.sync_object_manager, fds.release_timeline);

    const params = try wl.dmabuf.createParams();

    errdefer comptime unreachable;

    rs.wl_buffers_pending.putAssumeCapacityNoClobber(id, {});

    const gpu: GpuBuffer = .{
        .wl_buffer = undefined,
        .timeline_acquire = timeline_acquire,
        .timeline_release = timeline_release,
        .width = width,
        .height = height,
    };

    data.* = .{ .buffer_id = id, .client_id = rs.client_id, .wl = wl, .dispatch = dispatch, .gpu = gpu };
    params.add(@intFromEnum(fds.buffer), 0, 0, stride, mod_hi, mod_lo);
    params.create(width, height, format, .{});
    params.setListener(*RegisterGpuBuffer, RegisterGpuBuffer.callback, data);

    log.debug("GPU Buffer Requsted {f} for {f}", .{ data.buffer_id, data.client_id });
}

pub fn buffer_destroy(rs: *ClientResources, wl: *Wayland, id: BufferID) void {
    const buffer = rs.buffers.getPtr(id) orelse return;

    _ = wl.wl_buffers.orderedRemove(.from_wl_buffer(buffer.wl_buffer()));
    buffer.destroy();
    _ = rs.buffers.orderedRemove(id);
}

pub fn viewport_mark_commit(rs: *ClientResources, gpa: std.mem.Allocator, buffer_id: BufferID, viewport_id: ViewportID) !void {
    try rs.buffers_commited.ensureUnusedCapacity(gpa, 1);

    errdefer comptime unreachable;

    const commited = rs.buffers_commited.getOrPutAssumeCapacity(buffer_id);
    commited.value_ptr.* = viewport_id;
}

const Buffer = union(enum) {
    gpu: GpuBuffer,
    cpu: CpuBuffer,

    pub fn destroy(b: *Buffer) void {
        switch (b.*) {
            inline else => |v| v.destroy(),
        }
    }

    pub fn wl_buffer(b: Buffer) *cwl.Buffer {
        return switch (b) {
            inline else => |v| v.wl_buffer,
        };
    }

    pub fn width(b: Buffer) i32 {
        return switch (b) {
            inline else => |v| v.width,
        };
    }

    pub fn height(b: Buffer) i32 {
        return switch (b) {
            inline else => |v| v.height,
        };
    }
};

pub const GpuBuffer = struct {
    wl_buffer: *cwl.Buffer,
    timeline_acquire: ?Viewport.AcquireTimeline,
    timeline_release: ?Viewport.ReleaseTimeline,
    width: i32,
    height: i32,

    pub fn destroy(gpu: GpuBuffer) void {
        gpu.wl_buffer.destroy();
        if (gpu.timeline_acquire) |tl| tl.acquire.destroy();
        if (gpu.timeline_release) |tl| tl.release.destroy();
    }
};

pub const CpuBuffer = struct {
    wl_buffer: *cwl.Buffer,
    width: i32,
    height: i32,
    format: BufferFormat,

    pub fn destroy(cpu: CpuBuffer) void {
        cpu.wl_buffer.destroy();
    }
};

pub const RegisterGpuBuffer = struct {
    wl: *Wayland,
    dispatch: *Dispatch,
    client_id: ClientID,
    buffer_id: BufferID,
    gpu: GpuBuffer,

    pub fn callback(
        p: *zwp.LinuxBufferParamsV1,
        event: zwp.LinuxBufferParamsV1.Event,
        data: *RegisterGpuBuffer,
    ) void {
        switch (event) {
            .created => |result| blk: {
                const rs = data.wl.resources_get(data.client_id) catch {
                    break :blk;
                };

                data.wl.buffer_set_listener(
                    rs,
                    result.buffer,
                    data.buffer_id,
                );
                rs.buffers.putAssumeCapacityNoClobber(
                    data.buffer_id,
                    .{
                        .gpu = .{
                            .wl_buffer = result.buffer,
                            .width = data.gpu.width,
                            .height = data.gpu.height,
                            .timeline_acquire = data.gpu.timeline_acquire,
                            .timeline_release = data.gpu.timeline_release,
                        },
                    },
                );

                log.debug("GPU buffer created {f} for {f}", .{ data.buffer_id, data.client_id });
            },
            .failed => @panic("TODO"),
        }

        p.destroy();
        data.wl.gpa.destroy(data);
    }
};

pub const BufferListener = struct {
    pub fn callback(wl_buffer: *cwl.Buffer, event: cwl.Buffer.Event, wl: *Wayland) void {
        switch (event) {
            .release => {
                const key = wl.wl_buffers.get(.from_wl_buffer(wl_buffer)) orelse {
                    return;
                };

                const rs = wl.resources_get(key.client_id) catch {
                    return;
                };
                const entry = rs.buffers_commited.fetchSwapRemove(key.buffer_id) orelse return;

                log.debug("Received release event for wl_buffer {f} {f} {f}", .{ key.client_id, key.buffer_id, entry.value });
                wl.dispatch.server_put(
                    @src(),
                    .{
                        .buffer_released = .{
                            .client_id = key.client_id,
                            .buffer_id = key.buffer_id,
                            .viewport_id = entry.value,
                        },
                    },
                ) catch {};
            },
        }
    }
};
const std = @import("std");
const cwl = @import("wayland").client.wl;
const xdg = @import("wayland").client.xdg;
const zwp = @import("wayland").client.zwp;
const wp = @import("wayland").client.wp;
const Wayland = @import("Wayland.zig");
const BufferFormat = @import("../protocol/types.zig").BufferFormat;
const BufferAndTimelineFds = @import("../protocol/types.zig").BufferAndTimelineFds;
const c_linux = @import("c_linux");
const log = std.log.scoped(.ClientResources);
const ViewportKey = @import("../WindowSystem.zig").ViewportKey;
const BufferKey = @import("../WindowSystem.zig").BufferKey;
const WindowSystem = @import("../WindowSystem.zig");
const BufferID = @import("../protocol/types.zig").BufferID;
const ViewportID = @import("../protocol/types.zig").ViewportID;
const CpuBufferFd = @import("../protocol/types.zig").CpuBufferFd;
const ClientID = @import("../server/Clients.zig").ClientID;
const Dispatch = @import("../Dispatch.zig");
const Viewport = @import("Viewport.zig");
