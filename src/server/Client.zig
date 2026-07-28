const Client = @This();

id: Clients.ClientID,
stream: net.Stream,
closed: bool,

pub fn init(
    id: Clients.ClientID,
    stream: net.Stream,
) Client {
    return .{
        .id = id,
        .stream = stream,
        .closed = false,
    };
}

pub fn close(client: *Client, io: Io) void {
    client.stream.close(io);
    client.closed = true;
}

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const Clients = @import("Clients.zig");
const Server = @import("Server.zig");
const Dispatch = @import("../Dispatch.zig");
const server_to_client = @import("../protocol/server_to_client.zig");
