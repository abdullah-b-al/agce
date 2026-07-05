pub fn main(init: std.process.Init) !void {
    if (@import("builtin").os.tag == .windows) {
        // silence compile errors for now
        return;
    }

    var path_buf: [constants.socket_max_path]u8 = undefined;
    const path = utils.unix_address_path(init.environ_map, &path_buf);
    const address = try net.UnixAddress.init(path);

    const stream = try address.connect(init.io);
    defer stream.close(init.io);

    var viewport: Viewport = try .init(1280, 720);
    const size: protocol_types.ViewportSize = .{
        .width = viewport.width,
        .height = viewport.height,
        .bpp = viewport.bpp,
    };

    try client_to_server.message_send_viewport_create_with_fds(
        init.gpa,
        stream,
        @enumFromInt(1),
        size,
        viewport.front_fd,
        viewport.back_fd,
    );

    try client_to_server.message_send_json(
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
    while (true) {
        const r: u8 = random.int(u8);
        const g: u8 = random.int(u8);
        const b: u8 = random.int(u8);
        const a: u8 = 0xFF;

        var i: usize = 0;
        while (i < viewport.back_buffer.len) : (i += 4) {
            viewport.back_buffer[i + 0] = @intCast(b); // B
            viewport.back_buffer[i + 1] = @intCast(g); // G
            viewport.back_buffer[i + 2] = @intCast(r); // R
            viewport.back_buffer[i + 3] = @intCast(a); // A
        }

        std.log.info("Sent {x} {x} {x} {x}", .{ r, g, b, a });
        try client_to_server.message_send_json(
            init.io,
            init.gpa,
            stream,
            .{
                .viewport_buffers_swap = .{
                    .viewport_id = @enumFromInt(1),
                },
            },
        );
        viewport.swap();

        const timeout: Io.Timeout =
            .{ .duration = .{ .raw = .fromNanoseconds(1), .clock = .awake } };
        try handle_server_message_all(
            init.gpa,
            init.io,
            init.arena.allocator(),
            stream,
            timeout,
            &viewport,
        );

        try init.io.sleep(.fromSeconds(1), .awake);
    }
}

fn handle_server_message_all(
    gpa: std.mem.Allocator,
    io: Io,
    arena: std.mem.Allocator,
    stream: net.Stream,
    timeout: Io.Timeout,
    viewport: *Viewport,
) !void {
    while (true) {
        handle_server_message(
            gpa,
            io,
            arena,
            stream,
            timeout,
            viewport,
        ) catch |err| switch (err) {
            error.Timeout => return,
            else => |e| return e,
        };
    }
}
fn handle_server_message(
    gpa: std.mem.Allocator,
    io: Io,
    arena: std.mem.Allocator,
    stream: net.Stream,
    timeout: Io.Timeout,
    viewport: *Viewport,
) !void {
    const message = try server_to_client.message_receive(
        io,
        arena,
        stream,
        timeout,
    ) orelse return error.Timeout;

    switch (message) {
        .viewport_resize => |resize| {
            std.debug.print("got msg {}\n", .{resize});

            const new_size = resize.width * resize.height * viewport.bpp;

            if (new_size <= viewport.back_buffer.len) {
                viewport.width = resize.width;
                viewport.height = resize.height;

                try client_to_server.message_send_json(
                    io,
                    gpa,
                    stream,
                    .{
                        .viewport_resize = .{
                            .viewport_id = resize.viewport_id,
                            .width = resize.width,
                            .height = resize.height,
                        },
                    },
                );
            } else {
                const new_viewport: Viewport = try .init(resize.width, resize.height);
                viewport.* = new_viewport;

                try client_to_server.message_send_viewport_create_with_fds(
                    gpa,
                    stream,
                    @enumFromInt(1),
                    .{
                        .width = viewport.width,
                        .height = viewport.height,
                        .bpp = viewport.bpp,
                    },
                    viewport.front_fd,
                    viewport.back_fd,
                );
            }
        },
    }
}

const Viewport = struct {
    width: u32,
    height: u32,
    bpp: u8,

    front_fd: c_int,
    back_fd: c_int,
    front_buffer: []u8,
    back_buffer: []u8,

    pub fn init(width: u32, height: u32) !Viewport {
        const size: protocol_types.ViewportSize = .{
            .width = width,
            .height = height,
            .bpp = 4,
        };
        const s = size.width * size.height * size.bpp;
        const front_fd, const front_buffer = try create_fd(s);
        const back_fd, const back_buffer = try create_fd(s);

        return .{
            .width = size.width,
            .height = size.height,
            .bpp = size.bpp,

            .front_fd = front_fd,
            .back_fd = back_fd,

            .front_buffer = front_buffer,
            .back_buffer = back_buffer,
        };
    }

    fn swap(vp: *Viewport) void {
        std.mem.swap([]u8, &vp.front_buffer, &vp.back_buffer);
        std.mem.swap(c_int, &vp.front_fd, &vp.back_fd);
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
const client_to_server = @import("protocol/client_to_server.zig");
const server_to_client = @import("protocol/server_to_client.zig");
const common = @import("protocol/common.zig");
const protocol_types = @import("protocol/types.zig");
const c_linux = @import("c_linux");
