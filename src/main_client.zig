pub fn main(init: std.process.Init) !void {
    var path_buf: [constants.socket_max_path]u8 = undefined;
    const path = utils.unix_address_path(init.environ_map, &path_buf);
    const address = try net.UnixAddress.init(path);

    const stream = try address.connect(init.io);

    const size: protocol.ViewportSize = .{
        .width = 1280,
        .height = 720,
        .bpp = 4,
    };
    const s = size.width * size.height * size.bpp;
    const first_fd, _ = try create_fd(s);
    const second_fd, const back_buffer = try create_fd(s);

    const red_row = try init.gpa.alloc(u8, size.width * size.bpp);
    defer init.gpa.free(red_row);
    const white_row = try init.gpa.alloc(u8, size.width * size.bpp);
    defer init.gpa.free(white_row);

    {
        var i: usize = 0;
        while (i < red_row.len) : (i += 4) {
            red_row[i + 0] = 0;
            red_row[i + 1] = 0;
            red_row[i + 2] = 0xFF;
            red_row[i + 3] = 0xFF;
        }
    }
    {
        var i: usize = 0;
        while (i < white_row.len) : (i += 4) {
            white_row[i + 0] = 0xFF;
            white_row[i + 1] = 0xFF;
            white_row[i + 2] = 0xFF;
            white_row[i + 3] = 0xFF;
        }
    }

    for (0..size.height) |row| {
        const red = if (row % 2 == 0) true else false;
        const i = row * size.width * size.bpp;

        if (red) {
            std.mem.copyForwards(u8, back_buffer[i..], red_row);
        } else {
            std.mem.copyForwards(u8, back_buffer[i..], white_row);
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
const protocol = @import("server/protocol.zig");
const MessageFromClient = messaging.MessageFromClient;
const c_linux = @import("c_linux");
