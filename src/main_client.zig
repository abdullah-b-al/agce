pub fn main(init: std.process.Init) !void {
    if (true) return;
    var path_buf: [constants.socket_max_path]u8 = undefined;
    const path = utils.unix_address_path(init.environ_map, &path_buf);
    const address = try net.UnixAddress.init(path);

    const stream = try address.connect(init.io);
    defer stream.close(init.io);

    const size: protocol.ViewportSize = .{
        .width = 1280,
        .height = 720,
        .bpp = 4,
    };
    const s = size.width * size.height * size.bpp;
    const front_fd, const front_buffer = try create_fd(s);
    const back_fd, const back_buffer = try create_fd(s);

    try messaging.message_send_viewport_create_with_fds(
        init.gpa,
        stream,
        @enumFromInt(1),
        size,
        front_fd,
        back_fd,
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

    var rand: std.Random.DefaultPrng = .init(0);
    var random = rand.random();
    var buffers: Buffers = .{ .back = back_buffer, .front = front_buffer };
    while (true) {
        const r: u8 = random.int(u8);
        const g: u8 = random.int(u8);
        const b: u8 = random.int(u8);
        const a: u8 = 0xFF;

        var i: usize = 0;
        while (i < back_buffer.len) : (i += 4) {
            buffers.back[i + 0] = @intCast(b); // B
            buffers.back[i + 1] = @intCast(g); // G
            buffers.back[i + 2] = @intCast(r); // R
            buffers.back[i + 3] = @intCast(a); // A
        }

        std.log.info("Sent {x} {x} {x} {x}\n", .{ r, g, b, a });
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
        buffers.swap();

        try init.io.sleep(.fromSeconds(1), .awake);
    }
}

const Buffers = struct {
    front: []u8,
    back: []u8,

    fn swap(b: *Buffers) void {
        std.mem.swap([]u8, &b.front, &b.back);
    }
};

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
