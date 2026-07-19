pub const Buffers = @This();

pub const init: @This() = .{
    .wl_buffers_pending = .empty,
    .buffers_commited = .empty,
    .buffer_listeners = .empty,
    .buffer_listeners_pool = .empty,
    .buffers_cpu = .empty,
    .buffers_gpu = .empty,
};

wl_buffers_pending: std.array_hash_map.Auto(BufferKey, void),
buffer_listeners: std.array_hash_map.Auto(BufferKey, *callbacks.BufferListener),
buffer_listeners_pool: std.heap.MemoryPool(callbacks.BufferListener),

buffers_commited: std.array_hash_map.Auto(BufferKey, ViewportID),

buffers_cpu: std.array_hash_map.Auto(BufferKey, CpuBuffer),
buffers_gpu: std.array_hash_map.Auto(BufferKey, GpuBuffer),

pub fn buffer_get(b: *Buffers, key: BufferKey) ?Buffer {
    if (b.buffers_gpu.get(key)) |gpu| return .{ .gpu = gpu };
    if (b.buffers_cpu.get(key)) |cpu| return .{ .cpu = cpu };
    return null;
}

pub fn buffer_create_and_register_cpu(
    b: *Buffers,
    dispatch: *Dispatch,
    gpa: std.mem.Allocator,
    shm: *cwl.Shm,
    key: BufferKey,
    fd: c_int,
    width: i32,
    height: i32,
    format: BufferFormat,
) !void {
    try b.buffers_cpu.ensureUnusedCapacity(gpa, 1);
    try b.buffer_set_listener_prepare(gpa);

    const cpu = try b.buffer_create_cpu(shm, fd, width, height, format);
    b.buffer_set_listener(gpa, dispatch, cpu.wl_buffer, key);

    b.buffers_cpu.putAssumeCapacityNoClobber(key, cpu);
}

pub fn buffer_create_cpu(
    _: *Buffers,
    shm: *cwl.Shm,
    fd: c_int,
    width: i32,
    height: i32,
    format: BufferFormat,
) !CpuBuffer {
    const stride = width * format.bytes_per_pixel();
    const size = width * height * format.bytes_per_pixel();
    const pool = try shm.createPool(fd, size);
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
    b: *Buffers,
    dispatch: *Dispatch,
    wl: *Wayland,
    key: BufferKey,
    fd: c_int,
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

    const data = try wl.gpa.create(callbacks.RegisterGpuBuffer);
    errdefer wl.gpa.destroy(data);

    try b.wl_buffers_pending.ensureUnusedCapacity(wl.gpa, 1);
    try b.buffers_gpu.ensureUnusedCapacity(wl.gpa, b.wl_buffers_pending.capacity());
    try b.buffer_set_listener_prepare(wl.gpa);

    const params = try wl.dmabuf.createParams();

    errdefer comptime unreachable;

    b.wl_buffers_pending.putAssumeCapacityNoClobber(key, {});

    const gpu: GpuBuffer = .{
        .wl_buffer = undefined,
        .width = width,
        .height = height,
    };

    data.* = .{ .key = key, .wl = wl, .dispatch = dispatch, .gpu = gpu };
    params.add(fd, 0, 0, stride, mod_hi, mod_lo);
    params.create(width, height, format, .{});
    params.setListener(*callbacks.RegisterGpuBuffer, callbacks.register_gpu_buffer, data);

    log.debug("GPU Buffer Requsted {}", .{data.key});
}

pub fn buffer_destroy(b: *Buffers, key: BufferKey) void {
    // TODO: destroy other related data. such as the fd

    if (b.buffers_cpu.fetchOrderedRemove(key)) |cpu| {
        cpu.value.wl_buffer.destroy();
    }

    if (b.buffers_gpu.fetchOrderedRemove(key)) |gpu| {
        gpu.value.wl_buffer.destroy();
    }
}

pub fn buffer_set_listener_prepare(
    b: *Buffers,
    gpa: std.mem.Allocator,
) !void {
    const total = b.wl_buffers_pending.capacity() + b.wl_buffers_pending.count() + 1;

    try b.buffer_listeners.ensureTotalCapacity(gpa, total);
    try b.buffer_listeners_pool.addCapacity(gpa, 1);
}

pub fn buffer_set_listener(b: *Buffers, gpa: std.mem.Allocator, dispatch: *Dispatch, wl_buffer: *cwl.Buffer, buffer_key: BufferKey) void {
    const data = b.buffer_listeners_pool.create(gpa) catch unreachable;

    data.* = .{
        .dispatch = dispatch,
        .buffers = b,
        .client_id = buffer_key.client_id,
        .buffer_id = buffer_key.buffer_id,
    };

    wl_buffer.setListener(*callbacks.BufferListener, callbacks.buffer_present_listener, data);
    b.buffer_listeners.putAssumeCapacityNoClobber(buffer_key, data);

    log.debug("Set a listener for wl_buffer {} {}", .{ wl_buffer.getId(), buffer_key });
}

pub fn viewport_mark_commit(b: *Buffers, gpa: std.mem.Allocator, buffer_key: BufferKey, viewport_id: ViewportID) !void {
    try b.buffers_commited.ensureUnusedCapacity(gpa, 1);

    errdefer comptime unreachable;

    const commited = b.buffers_commited.getOrPutAssumeCapacity(buffer_key);
    if (commited.found_existing) {
        // TODO: Figure out a better way to handle this case
        @panic("The client tried to present the buffer before it was released");
    }

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

pub const callbacks = struct {
    const RegisterGpuBuffer = struct {
        wl: *Wayland,
        dispatch: *Dispatch,
        key: BufferKey,
        gpu: GpuBuffer,
    };

    fn register_gpu_buffer(
        p: *zwp.LinuxBufferParamsV1,
        event: zwp.LinuxBufferParamsV1.Event,
        data: *RegisterGpuBuffer,
    ) void {
        switch (event) {
            .created => |result| {
                data.wl.buffers.buffer_set_listener(
                    data.wl.gpa,
                    data.dispatch,
                    result.buffer,
                    data.key,
                );
                data.wl.buffers.buffers_gpu.putAssumeCapacityNoClobber(
                    data.key,
                    .{
                        .wl_buffer = result.buffer,
                        .width = data.gpu.width,
                        .height = data.gpu.height,
                    },
                );

                log.debug("GPU buffer created {}", .{data.key});
            },
            .failed => @panic("TODO"),
        }

        p.destroy();
        data.wl.gpa.destroy(data);
    }

    const BufferListener = struct {
        dispatch: *Dispatch,
        buffers: *Buffers,
        client_id: ClientID,
        buffer_id: BufferID,
    };

    fn buffer_present_listener(_: *cwl.Buffer, event: cwl.Buffer.Event, data: *BufferListener) void {
        switch (event) {
            .release => {
                const entry = data.buffers.buffers_commited.fetchSwapRemove(.{
                    .client_id = data.client_id,
                    .buffer_id = data.buffer_id,
                }).?;

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

pub const GpuBuffer = struct {
    wl_buffer: *cwl.Buffer,
    width: i32,
    height: i32,
};

pub const CpuBuffer = struct {
    wl_buffer: *cwl.Buffer,
    width: i32,
    height: i32,
    format: BufferFormat,
};

const std = @import("std");
const cwl = @import("wayland").client.wl;
const xdg = @import("wayland").client.xdg;
const zwp = @import("wayland").client.zwp;
const Wayland = @import("Wayland.zig");
const BufferFormat = @import("../protocol/types.zig").BufferFormat;
const c_linux = @import("c_linux");
const log = std.log.scoped(.Buffers);
const ViewportKey = @import("../WindowSystem.zig").ViewportKey;
const BufferKey = @import("../WindowSystem.zig").BufferKey;
const WindowSystem = @import("../WindowSystem.zig");
const BufferID = @import("../protocol/types.zig").BufferID;
const ViewportID = @import("../protocol/types.zig").ViewportID;
const ClientID = @import("../server/Clients.zig").ClientID;
const Dispatch = @import("../Dispatch.zig");
