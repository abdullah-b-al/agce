const Server = @This();

server: net.Server,
gpa: std.mem.Allocator,
io: Io,

clients: Clients,
ws_event_queue: *event.EventQueue,

pub fn create(io: Io, environ: *const std.process.Environ.Map, gpa: std.mem.Allocator, ws_event_queue: *event.EventQueue) !*Server {
    const server = try gpa.create(Server);
    errdefer gpa.destroy(server);

    var path_buf: [constants.socket_max_path]u8 = undefined;
    const path = utils.unix_address_path(environ, &path_buf);
    const address = net.UnixAddress.init(path) catch |err| switch (err) {
        error.NameTooLong => unreachable,
    };
    const net_server = try address.listen(io, .{});

    server.* = .{
        .server = net_server,
        .gpa = gpa,
        .io = io,
        .clients = .init,
        .ws_event_queue = ws_event_queue,
    };
    return server;
}

pub fn destroy(server: *Server) void {
    server.server.deinit(server.io);
    server.gpa.destroy(server);
}

pub fn message_handle(server: *Server, client: *Client, message: protocol.MessageFromClient) !void {
    switch (message) {
        .viewport_create_with_fds => |msg| {
            const size = msg.size.width * msg.size.height * msg.size.bpp;
            const front_buffer = try std.posix.mmap(
                null,
                size,
                .{ .READ = true, .WRITE = false },
                .{ .TYPE = .SHARED },
                msg.fds.front,
                0,
            );
            errdefer std.posix.munmap(front_buffer);

            const back_buffer = try std.posix.mmap(
                null,
                size,
                .{ .READ = true, .WRITE = false },
                .{ .TYPE = .SHARED },
                msg.fds.back,
                0,
            );
            errdefer std.posix.munmap(back_buffer);

            server.ws_event_queue.put(.{
                .viewport_create_with_fds = .{
                    .client_id = client.id,
                    .viewport_id = msg.id,
                    .viewport = .{
                        .front_fd = msg.fds.front,
                        .front_buffer = front_buffer,

                        .back_fd = msg.fds.back,
                        .back_buffer = back_buffer,
                        .size = msg.size,
                    },
                },
            });
        },

        .viewport_buffers_swap => |msg| {
            server.ws_event_queue.put(.{
                .viewport_buffers_swap = .{
                    .client_id = client.id,
                    .viewport_id = msg.viewport_id,
                },
            });
        },

        .window_create => |msg| {
            server.ws_event_queue.put(.{
                .window_create = .{
                    .client_id = client.id,
                    .viewport_id = msg.viewport_id,
                },
            });
        },
    }
}

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const constants = @import("../constants.zig");
const messaging = @import("messaging.zig");
const protocol = @import("protocol.zig");
const utils = @import("utils.zig");
const Clients = @import("Clients.zig");
const Client = @import("Client.zig");
const event = @import("../window_system/event.zig");
