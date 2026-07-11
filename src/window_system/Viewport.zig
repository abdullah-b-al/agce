const Viewport = @This();

key: ViewportKey,
front_fd: c_int,
back_fd: c_int,

size: ViewportSize,

pub fn init(key: ViewportKey, size: ViewportSize, front_fd: c_int, back_fd: c_int) !Viewport {
    return .{
        .key = key,
        .front_fd = front_fd,
        .back_fd = back_fd,
        .size = size,
    };
}

pub fn deinit(viewport: *Viewport) void {
    _ = std.os.linux.close(viewport.back_fd);
    _ = std.os.linux.close(viewport.front_fd);
}

const std = @import("std");
const ViewportSize = @import("../protocol/types.zig").ViewportSize;
const ViewportKey = @import("WindowSystem.zig").ViewportKey;
