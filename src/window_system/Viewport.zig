const Viewport = @This();

front_fd: c_int,
front_buffer: []const u8,

back_fd: c_int,
back_buffer: []const u8,

size: ViewportSize,

pub fn swap(viewport: *Viewport) void {
    std.mem.swap(c_int, &viewport.front_fd, &viewport.back_fd);
    std.mem.swap([]const u8, &viewport.front_buffer, &viewport.back_buffer);
}

pub fn init(size: ViewportSize, front_fd: c_int, back_fd: c_int) !Viewport {
    const bytes = size.width * size.height * size.bpp;
    const front_buffer = try std.posix.mmap(
        null,
        bytes,
        .{ .READ = true, .WRITE = false },
        .{ .TYPE = .SHARED },
        front_fd,
        0,
    );
    errdefer std.posix.munmap(front_buffer);

    const back_buffer = try std.posix.mmap(
        null,
        bytes,
        .{ .READ = true, .WRITE = false },
        .{ .TYPE = .SHARED },
        back_fd,
        0,
    );
    errdefer std.posix.munmap(back_buffer);

    return .{
        .front_fd = front_fd,
        .front_buffer = front_buffer,

        .back_fd = back_fd,
        .back_buffer = back_buffer,
        .size = size,
    };
}

pub fn deinit(viewport: *Viewport) void {
    std.posix.munmap(@alignCast(viewport.back_buffer));
    std.posix.munmap(@alignCast(viewport.front_buffer));
    _ = std.os.linux.close(viewport.back_fd);
    _ = std.os.linux.close(viewport.front_fd);
}

const std = @import("std");
const ViewportSize = @import("../protocol/types.zig").ViewportSize;
