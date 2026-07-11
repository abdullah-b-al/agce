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

    const id = bc.next_id;
    bc.next_id = @enumFromInt(@intFromEnum(bc.next_id) + 1);

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

const std = @import("std");
const cwl = @import("wayland").client.wl;
const xdg = @import("wayland").client.xdg;
const Wayland = @import("../Wayland.zig");
const BufferID = Wayland.BufferID;
const CpuBuffer = Wayland.CpuBuffer;
const GpuBuffer = Wayland.GpuBuffer;
