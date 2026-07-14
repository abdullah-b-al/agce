const Viewport = @This();

key: ViewportKey,
kind: Kind,

front_fd: c_int,
back_fd: c_int,

width: i32,
height: i32,
stride: i32,
format: ViewportFormat,
modifier: u64,

pub fn init_cpu(
    key: ViewportKey,
    front_fd: c_int,
    back_fd: c_int,
    width: i32,
    height: i32,
    format: ViewportFormat,
) Viewport {
    return .{
        .key = key,
        .front_fd = front_fd,
        .back_fd = back_fd,
        .width = width,
        .height = height,
        .format = format,
        .stride = width * format.bytes_per_pixel(),
        .modifier = 0,
        .kind = .cpu,
    };
}

pub fn init_gpu(
    key: ViewportKey,
    front_fd: c_int,
    back_fd: c_int,
    width: i32,
    height: i32,
    format: ViewportFormat,
    modifier: u64,
) Viewport {
    return .{
        .key = key,
        .front_fd = front_fd,
        .back_fd = back_fd,
        .width = width,
        .height = height,
        .format = format,
        .stride = width * format.bytes_per_pixel(),
        .modifier = modifier,
        .kind = .gpu,
    };
}

pub fn deinit(viewport: *Viewport) void {
    _ = std.os.linux.close(viewport.back_fd);
    _ = std.os.linux.close(viewport.front_fd);
}

pub const Kind = enum { cpu, gpu };

const std = @import("std");
const ViewportKey = @import("WindowSystem.zig").ViewportKey;
const ViewportFormat = @import("../protocol/types.zig").ViewportFormat;
