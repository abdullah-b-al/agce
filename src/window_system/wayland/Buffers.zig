pub const Buffers = @This();

pub const init: @This() = .{
    .double_buffers = .empty,
    .wl_buffers = .empty,
    .wl_buffers_pending = .empty,
    .buffer_next_id = .first,
    .double_buffer_next_id = .first,
};

double_buffers: std.array_hash_map.Auto(DoubleBufferID, DoubleBuffer),

wl_buffers: std.array_hash_map.Auto(BufferID, *cwl.Buffer),
wl_buffers_pending: std.array_hash_map.Auto(BufferID, OnReceive),

buffer_next_id: BufferID,
double_buffer_next_id: DoubleBufferID,

pub fn double_buffer_create_cpu(b: *Buffers, wl: *Wayland, vp: Viewport) !DoubleBufferID {
    try b.double_buffers.ensureUnusedCapacity(wl.gpa, 1);

    const w = vp.width;
    const h = vp.height;
    const f: cwl.Shm.Format = .argb8888;
    const bpp = vp.format.bytes_per_pixel();
    const back = try wl.buffers.buffer_create_cpu(wl.gpa, wl.shm, vp.back_fd, w, h, bpp, f);
    const front = try wl.buffers.buffer_create_cpu(wl.gpa, wl.shm, vp.front_fd, w, h, bpp, f);

    const buffer: DoubleBuffer = .{
        .viewport_key = vp.key,
        .back = .{ .cpu = back },
        .front = .{ .cpu = front },
    };

    const id = b.double_buffer_next_id;
    b.double_buffer_next_id.increment();

    b.double_buffers.putAssumeCapacityNoClobber(id, buffer);

    return id;
}

pub fn double_buffer_create_gpu(b: *Buffers, wl: *Wayland, vp: Viewport) !DoubleBufferID {
    try b.double_buffers.ensureUnusedCapacity(wl.gpa, 1);

    const w = vp.width;
    const h = vp.height;
    const f = vp.format;
    const m = vp.modifier;
    const back = try wl.buffers.buffer_create_gpu_async(wl, vp.back_fd, w, h, f, m);
    const front = try wl.buffers.buffer_create_gpu_async(wl, vp.front_fd, w, h, f, m);

    const buffer: DoubleBuffer = .{
        .viewport_key = vp.key,
        .back = .{ .gpu = back },
        .front = .{ .gpu = front },
    };

    const id = b.double_buffer_next_id;
    b.double_buffer_next_id.increment();

    b.double_buffers.putAssumeCapacityNoClobber(id, buffer);

    return id;
}

pub fn double_buffer_destroy(b: *Buffers, id: DoubleBufferID) void {
    const entry = b.double_buffers.fetchOrderedRemove(id) orelse return;
    const buffer = entry.value;
    const front, const back = switch (buffer.front) {
        .cpu => .{ buffer.front.cpu.id, buffer.back.cpu.id },
        .gpu => .{ buffer.front.gpu.id, buffer.back.gpu.id },
    };

    b.buffer_destroy(front);
    b.buffer_destroy(back);
}

pub fn double_buffer_swap(b: *Buffers, id: DoubleBufferID) void {
    const buffer = b.double_buffers.getPtr(id) orelse return;
    std.mem.swap(BufferSource, &buffer.back, &buffer.front);
}

pub fn double_buffer_resize(
    b: *Buffers,
    id: DoubleBufferID,
    wl: *Wayland,
    viewport: Viewport,
) !void {
    const buffer = b.double_buffers.getPtr(id) orelse return;

    switch (buffer.front) {
        .cpu => {
            const new_front = try b.buffer_create_cpu(
                wl.gpa,
                wl.shm,
                viewport.front_fd,
                viewport.width,
                viewport.height,
                viewport.format.bytes_per_pixel(),
                buffer.front.cpu.format,
            );

            const new_back = try b.buffer_create_cpu(
                wl.gpa,
                wl.shm,
                viewport.back_fd,
                viewport.width,
                viewport.height,
                viewport.format.bytes_per_pixel(),
                buffer.back.cpu.format,
            );

            errdefer comptime unreachable;

            b.buffer_destroy(buffer.front.cpu.id);
            b.buffer_destroy(buffer.back.cpu.id);

            buffer.* = .{
                .viewport_key = viewport.key,
                .front = .{ .cpu = new_front },
                .back = .{ .cpu = new_back },
            };
        },
        .gpu => @panic("TODO"),
    }
}

pub fn double_buffer_wl_buffer(
    b: *Buffers,
    id: DoubleBufferID,
) ?*cwl.Buffer {
    const buffer = b.double_buffers.getPtr(id) orelse return null;
    return b.wl_buffers.get(buffer.front_id());
}

pub fn double_buffer_viewport_key(
    b: *Buffers,
    id: DoubleBufferID,
) ?ViewportKey {
    const buffer = b.double_buffers.getPtr(id) orelse return null;
    return buffer.viewport_key;
}

pub fn buffer_create_cpu(
    b: *Buffers,
    gpa: std.mem.Allocator,
    shm: *cwl.Shm,
    fd: c_int,
    width: i32,
    height: i32,
    bytes_per_pixel: u8,
    format: cwl.Shm.Format,
) !CpuBuffer {
    try b.wl_buffers.ensureUnusedCapacity(gpa, 1);

    const stride = width * bytes_per_pixel;
    const size = width * height * bytes_per_pixel;
    const pool = try shm.createPool(fd, size);
    defer pool.destroy();

    const buffer = try pool.createBuffer(0, width, height, stride, format);

    const id = b.buffer_next_id;
    b.buffer_next_id.increment();

    b.wl_buffers.putAssumeCapacityNoClobber(id, buffer);

    return .{
        .id = id,
        .width = width,
        .height = height,
        .bytes_per_pixel = bytes_per_pixel,
        .format = format,
    };
}

pub fn buffer_create_gpu_async(
    b: *Buffers,
    wl: *Wayland,
    fd: c_int,
    width: i32,
    height: i32,
    vp_format: ViewportFormat,
    modifier: u64,
) !GpuBuffer {
    const callback = struct {
        const Data = struct { wl: *Wayland, id: BufferID };

        fn func(
            p: *zwp.LinuxBufferParamsV1,
            event: zwp.LinuxBufferParamsV1.Event,
            data: *Data,
        ) void {
            switch (event) {
                .created => |result| {
                    const on_receive = data.wl.buffers.wl_buffers_pending.get(data.id).?;

                    switch (on_receive) {
                        .register => {
                            data.wl.buffers.wl_buffers.putAssumeCapacityNoClobber(
                                data.id,
                                result.buffer,
                            );
                            log.debug("GPU buffer created {}", .{data.id});
                        },
                        .destroy => {
                            result.buffer.destroy();
                            log.debug("GPU buffer created and destroyed {}", .{data.id});
                        },
                    }
                },
                .failed => @panic("TODO"),
            }

            p.destroy();
            data.wl.gpa.destroy(data);
        }
    };

    const mod_lo: u32 = @intCast(modifier & 0xFF_FF_FF_FF);
    const mod_hi: u32 = @intCast(modifier >> 32);
    const stride: u32 = @intCast(width * vp_format.bytes_per_pixel());
    const format = switch (vp_format) {
        .argb8888 => c_linux.DRM_FORMAT_ARGB8888,
    };

    const data = try wl.gpa.create(callback.Data);
    errdefer wl.gpa.destroy(data);

    try b.wl_buffers_pending.ensureUnusedCapacity(wl.gpa, 1);
    try b.wl_buffers.ensureUnusedCapacity(wl.gpa, b.wl_buffers_pending.capacity());

    const params = try wl.dmabuf.createParams();

    errdefer comptime unreachable;

    const id = b.buffer_next_id;
    b.buffer_next_id.increment();

    b.wl_buffers_pending.putAssumeCapacityNoClobber(id, .register);

    data.* = .{ .id = id, .wl = wl };
    params.add(fd, 0, 0, stride, mod_hi, mod_lo);
    params.create(width, height, format, .{});
    params.setListener(*callback.Data, callback.func, data);
    log.debug("GPU Buffer Requsted {}", .{data.id});

    return .{
        .id = id,
        .width = width,
        .height = height,
    };
}

pub fn buffer_destroy(b: *Buffers, id: BufferID) void {
    const entry = b.wl_buffers.fetchSwapRemove(id) orelse {
        if (b.wl_buffers_pending.contains(id)) {
            b.wl_buffers_pending.putAssumeCapacity(id, .destroy);
        }

        return;
    };
    const buffer: *cwl.Buffer = entry.value;
    buffer.destroy();
}

pub const BufferID = enum(u32) {
    const first: @This() = @enumFromInt(1);
    _,

    pub fn increment(this: *@This()) void {
        const int = @intFromEnum(this.*);
        this.* = @enumFromInt(int + 1);
    }
};

pub const DoubleBufferID = enum(u32) {
    const first: @This() = @enumFromInt(1);
    _,

    pub fn increment(this: *@This()) void {
        const int = @intFromEnum(this.*);
        this.* = @enumFromInt(int + 1);
    }
};

pub const DoubleBuffer = struct {
    viewport_key: ViewportKey,
    front: BufferSource,
    back: BufferSource,

    fn front_id(buffer: DoubleBuffer) BufferID {
        return switch (buffer.front) {
            inline else => |v| v.id,
        };
    }

    pub fn width(b: DoubleBuffer) i32 {
        return switch (b.front) {
            inline else => |v| v.width,
        };
    }

    pub fn height(b: DoubleBuffer) i32 {
        return switch (b.front) {
            inline else => |v| v.height,
        };
    }
};

const BufferSource = union(enum) {
    gpu: GpuBuffer,
    cpu: CpuBuffer,
};

pub const GpuBuffer = struct {
    id: BufferID,
    width: i32,
    height: i32,
};

pub const CpuBuffer = struct {
    id: BufferID,
    width: i32,
    height: i32,
    bytes_per_pixel: u8,
    format: cwl.Shm.Format,
};

const OnReceive = enum {
    register,
    destroy,
};

const std = @import("std");
const cwl = @import("wayland").client.wl;
const xdg = @import("wayland").client.xdg;
const zwp = @import("wayland").client.zwp;
const Wayland = @import("../Wayland.zig");
const ViewportFormat = @import("../../protocol/types.zig").ViewportFormat;
const Viewport = @import("../Viewport.zig");
const c_linux = @import("c_linux");
const log = std.log.scoped(.BufferCollection);
const ViewportKey = @import("../WindowSystem.zig").ViewportKey;
