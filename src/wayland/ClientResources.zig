const ClientResources = @This();

client_id: ClientID,
wl_buffers_pending: std.array_hash_map.Auto(BufferID, void),

buffers_commited: std.array_hash_map.Auto(BufferID, ViewportID),

buffers_cpu: std.array_hash_map.Auto(BufferID, CpuBuffer),
buffers_gpu: std.array_hash_map.Auto(BufferID, GpuBuffer),

viewports: std.array_hash_map.Auto(ViewportID, Viewport),

pub fn init(id: ClientID) ClientResources {
    return .{
        .client_id = id,
        .wl_buffers_pending = .empty,
        .buffers_commited = .empty,
        .buffers_cpu = .empty,
        .buffers_gpu = .empty,
        .viewports = .empty,
    };
}

pub fn deinit(rs: *ClientResources, gpa: std.mem.Allocator) void {
    rs.wl_buffers_pending.deinit(gpa);
    rs.buffers_commited.deinit(gpa);

    for (rs.buffers_cpu.values()) |cpu| {
        cpu.wl_buffer.destroy();
    }
    rs.buffers_cpu.deinit(gpa);

    for (rs.buffers_gpu.values()) |gpu| {
        gpu.wl_buffer.destroy();

        if (gpu.timeline_acquire) |t| t.acquire.destroy();
        if (gpu.timeline_release) |t| t.release.destroy();
    }

    rs.buffers_gpu.deinit(gpa);

    for (rs.viewports.values()) |*vp| {
        vp.deinit();
    }
    rs.viewports.deinit(gpa);
}

pub fn buffer_get(rs: *ClientResources, key: BufferID) ?Buffer {
    if (rs.buffers_gpu.get(key)) |gpu| return .{ .gpu = gpu };
    if (rs.buffers_cpu.get(key)) |cpu| return .{ .cpu = cpu };
    return null;
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
    dispatch: *Dispatch,
    id: BufferID,
    fd: CpuBufferFd,
    width: i32,
    height: i32,
    format: BufferFormat,
) !void {
    try rs.buffers_cpu.ensureUnusedCapacity(wl.gpa, 1);
    try rs.buffer_set_listener_prepare(wl);

    const cpu = try buffer_create_cpu(wl.shm, fd, width, height, format);
    rs.buffer_set_listener(wl, dispatch, cpu.wl_buffer, id);

    rs.buffers_cpu.putAssumeCapacityNoClobber(id, cpu);
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
    try rs.buffers_gpu.ensureUnusedCapacity(wl.gpa, rs.wl_buffers_pending.capacity());
    try rs.buffer_set_listener_prepare(wl);

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

    log.debug("GPU Buffer Requsted {} for {}", .{ data.buffer_id, data.client_id });
}

pub fn buffer_destroy(rs: *ClientResources, id: BufferID) void {
    if (rs.buffers_cpu.fetchOrderedRemove(id)) |cpu| {
        cpu.value.wl_buffer.destroy();
    }

    if (rs.buffers_gpu.fetchOrderedRemove(id)) |gpu| {
        gpu.value.wl_buffer.destroy();
    }
}

pub fn buffer_set_listener_prepare(
    rs: *ClientResources,
    wl: *Wayland,
) !void {
    const total =
        rs.wl_buffers_pending.count() +
        rs.buffers_cpu.count() +
        rs.buffers_gpu.count() +
        1;

    try wl.buffer_listeners.ensureTotalCapacity(wl.gpa, total);
    try wl.buffer_listeners_pool.addCapacity(wl.gpa, 1);
}

pub fn buffer_set_listener(rs: *ClientResources, wl: *Wayland, dispatch: *Dispatch, wl_buffer: *cwl.Buffer, buffer_id: BufferID) void {
    const data = wl.buffer_listeners_pool.create(wl.gpa) catch unreachable;

    data.* = .{
        .dispatch = dispatch,
        .wl = wl,
        .client_id = rs.client_id,
        .buffer_id = buffer_id,
    };

    wl_buffer.setListener(*BufferListener, BufferListener.callback, data);
    wl.buffer_listeners.putAssumeCapacityNoClobber(.{ .client_id = rs.client_id, .buffer_id = buffer_id }, data);

    log.debug("Set a listener for wl_buffer {} {}", .{ wl_buffer.getId(), buffer_id });
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
};

pub const CpuBuffer = struct {
    wl_buffer: *cwl.Buffer,
    width: i32,
    height: i32,
    format: BufferFormat,
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

                rs.buffer_set_listener(
                    data.wl,
                    data.dispatch,
                    result.buffer,
                    data.buffer_id,
                );
                rs.buffers_gpu.putAssumeCapacityNoClobber(
                    data.buffer_id,
                    .{
                        .wl_buffer = result.buffer,
                        .width = data.gpu.width,
                        .height = data.gpu.height,
                        .timeline_acquire = data.gpu.timeline_acquire,
                        .timeline_release = data.gpu.timeline_release,
                    },
                );

                log.debug("GPU buffer created {} for {}", .{ data.buffer_id, data.client_id });
            },
            .failed => @panic("TODO"),
        }

        p.destroy();
        data.wl.gpa.destroy(data);
    }
};

pub const BufferListener = struct {
    dispatch: *Dispatch,
    wl: *Wayland,
    client_id: ClientID,
    buffer_id: BufferID,

    pub fn callback(_: *cwl.Buffer, event: cwl.Buffer.Event, data: *BufferListener) void {
        switch (event) {
            .release => {
                // TODO: Figure out when to free memeory of this callback when the client disconnects
                const rs = data.wl.resources_get(data.client_id) catch {
                    return;
                };
                const entry = rs.buffers_commited.fetchSwapRemove(data.buffer_id) orelse return;

                log.debug("Received release event for wl_buffer {} {} {}", .{ data.client_id, data.buffer_id, entry.value });
                data.dispatch.server_put(
                    .{
                        .buffer_released = .{
                            .client_id = data.client_id,
                            .buffer_id = data.buffer_id,
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
