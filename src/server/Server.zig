const Server = @This();

server: net.Server,
gpa: std.mem.Allocator,
io: Io,

clients: Clients,
ws_event_queue: *events.WindowSystemQueue,
event_queue: *events.ServerQueue,

pub fn create(
    io: Io,
    environ: *const std.process.Environ.Map,
    gpa: std.mem.Allocator,
    ws_event_queue: *events.WindowSystemQueue,
    event_queue: *events.ServerQueue,
) !*Server {
    const server = try gpa.create(Server);
    errdefer gpa.destroy(server);

    var path_buf: [constants.socket_max_path]u8 = undefined;
    const path = utils.unix_address_path(environ, &path_buf);
    const address = net.UnixAddress.init(path) catch |err| switch (err) {
        error.NameTooLong => unreachable,
    };
    const net_server = try address.listen(io, .{});
    log.info("Created server on {s}", .{address.path});

    server.* = .{
        .server = net_server,
        .gpa = gpa,
        .io = io,
        .clients = .init,
        .ws_event_queue = ws_event_queue,
        .event_queue = event_queue,
    };
    return server;
}

pub fn destroy(server: *Server) void {
    server.server.deinit(server.io);
    server.gpa.destroy(server);
}

pub fn window_system_event_from_message(_: *Server, client: *Client, message: MessageFromClient) !events.WindowSystem {
    switch (message) {
        .viewport_create_with_fds => |msg| {
            if (os_tag != .linux) {
                return error.UnsupportedMessageOnOs;
            }

            return .{
                .viewport_create_with_fds = .{
                    .client_id = client.id,
                    .viewport_id = msg.id,
                    .size = msg.size,
                    .fds = msg.fds,
                },
            };
        },

        .viewport_buffers_swap => |msg| {
            return .{
                .viewport_buffers_swap = .{
                    .client_id = client.id,
                    .viewport_id = msg.viewport_id,
                },
            };
        },
        .viewport_resize => |msg| {
            return .{
                .viewport_resize = .{
                    .client_id = client.id,
                    .resize = msg.resize,
                },
            };
        },

        .window_create => |msg| {
            return .{
                .window_create = .{
                    .client_id = client.id,
                    .viewport_id = msg.viewport_id,
                },
            };
        },
    }
}

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const constants = @import("../constants.zig");
const utils = @import("utils.zig");
const Clients = @import("Clients.zig");
const Client = @import("Client.zig");
const log = std.log.scoped(.Server);
const os_tag = @import("builtin").os.tag;
const events = @import("../events.zig");
const MessageFromClient = @import("../protocol/client_to_server.zig").MessageFromClient;
const MessageToServer = @import("../protocol/client_to_server.zig").MessageToServer;
const Viewport = @import("../window_system/Viewport.zig");
