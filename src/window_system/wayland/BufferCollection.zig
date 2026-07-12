pub const BufferCollection = @This();
pub const init: @This() = .{
    .next_id = .first,
    .buffers = .empty,
    .pools = .empty,
};

buffers: std.array_hash_map.Auto(BufferID, *cwl.Buffer),
pools: std.array_hash_map.Auto(BufferID, *cwl.ShmPool),
next_id: BufferID,

pub fn buffer_create_cpu(
    bc: *BufferCollection,
    gpa: std.mem.Allocator,
    shm: *cwl.Shm,
    fd: c_int,
    width: i32,
    height: i32,
    bytes_per_pixel: u8,
    format: cwl.Shm.Format,
) !CpuBuffer {
    try bc.buffers.ensureUnusedCapacity(gpa, 1);
    try bc.pools.ensureUnusedCapacity(gpa, 1);

    const stride = width * bytes_per_pixel;
    const size = width * height * bytes_per_pixel;
    const pool = try shm.createPool(fd, size);
    const buffer = try pool.createBuffer(0, width, height, stride, format);

    const id = bc.next_id_increment();

    bc.buffers.putAssumeCapacityNoClobber(id, buffer);
    bc.pools.putAssumeCapacityNoClobber(id, pool);

    return .{
        .buffer_id = id,
        .width = width,
        .height = height,
        .bytes_per_pixel = bytes_per_pixel,
        .format = format,
    };
}

pub fn buffer_create_gpu_async(
    bc: *BufferCollection,
    wl: *Wayland,
    fd: c_int,
    width: i32,
    height: i32,
    vp_format: ViewportFormat,
    modifier: u64,
) !GpuBuffer {
    const mod_lo: u32 = @intCast(modifier & 0xFF_FF_FF_FF);
    const mod_hi: u32 = @intCast(modifier >> 32);
    const stride: u32 = @intCast(width * vp_format.bytes_per_pixel());
    const format = switch (vp_format) {
        .argb8888 => c_linux.DRM_FORMAT_ARGB8888,
    };

    const callback = struct {
        const Data = struct { wl: *Wayland, id: BufferID };

        fn func(
            p: *zwp.LinuxBufferParamsV1,
            event: zwp.LinuxBufferParamsV1.Event,
            data: *Data,
        ) void {
            switch (event) {
                .created => |result| {
                    data.wl.buffers.buffers.putNoClobber(
                        data.wl.gpa,
                        data.id,
                        result.buffer,
                    ) catch @panic("TODO");

                    log.debug("GPU Buffer Created {}", .{data.id});
                },
                .failed => @panic("TODO"),
            }

            p.destroy();
            data.wl.gpa.destroy(data);
        }
    };

    const data = try wl.gpa.create(callback.Data);
    errdefer wl.gpa.destroy(data);

    const id = bc.next_id_increment();
    data.* = .{ .id = id, .wl = wl };

    const params = try wl.dmabuf.createParams();
    params.add(fd, 0, 0, stride, mod_hi, mod_lo);
    params.create(width, height, format, .{});
    params.setListener(*callback.Data, callback.func, data);
    log.debug("GPU Buffer Requsted {}", .{data.id});

    return .{
        .buffer_id = id,
        .width = width,
        .height = height,
    };
}

pub fn buffer_down_size_cpu(bc: *BufferCollection, id: BufferID, width: i32, height: i32, bytes_per_pixel: u8, format: cwl.Shm.Format) !void {
    const buffer = bc.buffers.get(id).?;
    const pool = bc.pools.get(id).?;

    const stride = width * bytes_per_pixel;
    const new_buffer = try pool.createBuffer(0, width, height, stride, format);
    buffer.destroy();

    // overridde
    bc.buffers.putAssumeCapacity(id, new_buffer);
}

pub fn buffer_destroy(bc: *BufferCollection, id: BufferID) void {
    const buffer = bc.buffers.get(id) orelse return;
    buffer.destroy();
    const pool = bc.pools.get(id) orelse return;
    pool.destroy();
}

fn next_id_increment(bc: *BufferCollection) BufferID {
    const id = bc.next_id;
    bc.next_id = @enumFromInt(@intFromEnum(bc.next_id) + 1);
    return id;
}

const std = @import("std");
const cwl = @import("wayland").client.wl;
const xdg = @import("wayland").client.xdg;
const zwp = @import("wayland").client.zwp;
const Wayland = @import("../Wayland.zig");
const ViewportFormat = @import("../../protocol/types.zig").ViewportFormat;
const Viewport = @import("../Viewport.zig");
const BufferID = Wayland.BufferID;
const CpuBuffer = Wayland.CpuBuffer;
const GpuBuffer = Wayland.GpuBuffer;
const c_linux = @import("c_linux");
const log = std.log.scoped(.BufferCollection);
