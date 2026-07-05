const Client = @This();

id: Clients.ClientID,
stream: net.Stream,

pub fn init(
    id: Clients.ClientID,
    stream: net.Stream,
) Client {
    return .{
        .id = id,
        .stream = stream,
    };
}

pub fn event_handle(client: *Client, server: *Server, event: events.Server) !void {
    switch (event) {
        .viewport_resize => |e| {
            std.debug.assert(e.client_id == client.id);

            try server_to_client.message_send_json(
                server.io,
                server.gpa,
                client.stream,
                .{
                    .viewport_resize = e.resize,
                },
            );
        },
    }
}

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const Clients = @import("Clients.zig");
const Server = @import("Server.zig");
const events = @import("../events.zig");
const server_to_client = @import("../protocol/server_to_client.zig");
