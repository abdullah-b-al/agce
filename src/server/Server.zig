const Server = @This();

server: net.Server,
gpa: std.mem.Allocator,
io: Io,
dispatch: *Dispatch,

clients: Clients,

pub fn create(
    io: Io,
    environ: *const std.process.Environ.Map,
    gpa: std.mem.Allocator,
    dispatch: *Dispatch,
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
        .dispatch = dispatch,
    };
    return server;
}

pub fn destroy(server: *Server) void {
    server.server.deinit(server.io);
    server.gpa.destroy(server);
}

pub fn window_system_event_from_message(_: *Server, client: *Client, payload: MessagePayload) !Dispatch.WindowSystemEvent {
    switch (payload) {
        inline .buffer_create_cpu_with_fd,
        .buffer_create_gpu_with_fd,
        => |msg, tag| {
            if (os_tag != .linux) {
                return error.UnsupportedMessageOnOs;
            }

            const expr = switch (tag) {
                .buffer_create_cpu_with_fd => Dispatch.WindowSystemEvent.BufferCreateCpuWithFd{
                    .client_id = client.id,
                    .buffer_id = msg.id,
                    .fd = msg.fd,
                    .width = msg.width,
                    .height = msg.height,
                    .format = msg.format,
                },
                .buffer_create_gpu_with_fd => Dispatch.WindowSystemEvent.BufferCreateGpuWithFd{
                    .client_id = client.id,
                    .buffer_id = msg.id,
                    .fd = msg.fd,
                    .width = msg.width,
                    .height = msg.height,
                    .format = msg.format,
                    .gbm_bo_modifier = msg.gbm_bo_modifier,
                },
                else => comptime unreachable,
            };

            return @unionInit(Dispatch.WindowSystemEvent, @tagName(tag), expr);
        },

        .buffer_present => |msg| {
            return .{
                .buffer_present = .{
                    .client_id = client.id,
                    .viewport_id = msg.viewport_id,
                    .buffer_id = msg.buffer_id,
                },
            };
        },
        .buffer_destroy => |msg| {
            return .{
                .buffer_destroy = .{
                    .client_id = client.id,
                    .buffer_id = msg.buffer_id,
                },
            };
        },
        .window_create => |msg| {
            return .{
                .window_create = .{
                    .client_id = client.id,
                    .viewport_id = msg.viewport_id,
                    .width = msg.width,
                    .height = msg.height,
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
const MessagePayload = @import("../protocol/client_to_server.zig").MessagePayload;
const Dispatch = @import("../Dispatch.zig");
