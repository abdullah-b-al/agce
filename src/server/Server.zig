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
    const net_server = address.listen(io, .{}) catch |err| {
        log.err("Failed to listen to socket {s} {}", .{ path, err });
        return err;
    };
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

pub fn window_system_event_from_message(_: *Server, client: *Client, payload: MessagePayload) !events.WindowSystem {
    switch (payload) {
        inline .viewport_create_with_fds_cpu,
        => |msg, tag| {
            if (os_tag != .linux) {
                return error.UnsupportedMessageOnOs;
            }

            const expr = switch (tag) {
                .viewport_create_with_fds_cpu => events.WindowSystem.ViewportCreateWithFdsCpu{
                    .client_id = client.id,
                    .viewport_id = msg.id,
                    .size = msg.size,
                    .fds = msg.fds,
                },
                else => comptime unreachable,
            };

            return @unionInit(events.WindowSystem, @tagName(tag), expr);
        },
        inline .viewport_create_with_fds_gpu,
        => |msg, tag| {
            const expr = switch (tag) {
                .viewport_create_with_fds_gpu => events.WindowSystem.ViewportCreateWithFdsGpu{
                    .client_id = client.id,
                    .viewport_id = msg.id,
                    .fds = msg.fds,

                    .width = msg.width,
                    .height = msg.height,

                    .format = msg.format,
                    .gbm_bo_modifier = msg.gbm_bo_modifier,
                },
                else => comptime unreachable,
            };
            return @unionInit(events.WindowSystem, @tagName(tag), expr);
        },

        .viewport_buffers_swap => |msg| {
            return .{
                .viewport_buffers_swap = .{
                    .client_id = client.id,
                    .viewport_id = msg.viewport_id,
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
const MessagePayload = @import("../protocol/client_to_server.zig").MessagePayload;
const Viewport = @import("../window_system/Viewport.zig");
