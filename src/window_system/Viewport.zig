const Viewport = @This();

front_fd: c_int,
front_buffer: []const u8,

back_fd: c_int,
back_buffer: []const u8,

size: protocol.ViewportSize,

pub fn swap(viewport: *Viewport) void {
    std.mem.swap(c_int, &viewport.front_fd, &viewport.back_fd);
    std.mem.swap([]const u8, &viewport.front_buffer, &viewport.back_buffer);
}

const std = @import("std");
const protocol = @import("../server/protocol.zig");
