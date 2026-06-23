pub fn main(init: std.process.Init) !void {
    var path_buf: [constants.socket_max_path]u8 = undefined;
    const path = utils.unix_address_path(init.environ_map, &path_buf);
    const address = try net.UnixAddress.init(path);

    const stream = try address.connect(init.io);

    const size = 1280 * 720;
    const first_fd, const first_buffer = try create_fd(size);
    const second_fd, const second_buffer = try create_fd(size);

    {
        var i: usize = 0;
        while (i < first_buffer.len) {
            defer i += 4;
            first_buffer[i + 0] = 0xFF;
            first_buffer[i + 1] = 0xFF;
            first_buffer[i + 2] = 0xFF;
            first_buffer[i + 3] = 0xFF;
        }
    }

    {
        var i: usize = 0;
        while (i < second_buffer.len) {
            defer i += 4;
            second_buffer[i + 0] = 0xFF;
            second_buffer[i + 1] = 0xFF;
            second_buffer[i + 2] = 0xFF;
            second_buffer[i + 3] = 0xFF;
        }
    }

    try messaging.message_send_viewport_create_with_fds(
        init.gpa,
        stream,
        @enumFromInt(1),
        size,
        first_fd,
        second_fd,
    );

    try messaging.message_send_json(
        init.io,
        init.gpa,
        stream,
        .{
            .window_create = .{
                .viewport_id = @enumFromInt(1),
            },
        },
    );

    try messaging.message_send_json(
        init.io,
        init.gpa,
        stream,
        .{
            .viewport_buffers_swap = .{
                .viewport_id = @enumFromInt(1),
            },
        },
    );

    stream.close(init.io);
}

fn create_fd(size: usize) !struct { c_int, []u8 } {
    const fd = try std.posix.memfd_create("agce-buffer", 0);
    if (std.posix.errno(std.posix.system.ftruncate(fd, @intCast(size))) != .SUCCESS) return error.FtruncateFailed;
    const buffer: []u8 = try std.posix.mmap(
        null,
        size,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .SHARED },
        fd,
        0,
    );

    return .{ fd, buffer };
}

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const constants = @import("constants.zig");
const utils = @import("server/utils.zig");
const messaging = @import("server/messaging.zig");
const MessageFromClient = messaging.MessageFromClient;
const c_linux = @import("c_linux");
