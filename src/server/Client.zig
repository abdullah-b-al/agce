const Client = @This();

id: Clients.ClientID,
stream: net.Stream,
closed: bool,

pub fn create(
    gpa: std.mem.Allocator,
    id: Clients.ClientID,
    stream: net.Stream,
) !*Client {
    const client = try gpa.create(Client);
    client.* = .{
        .id = id,
        .stream = stream,
        .closed = false,
    };
    return client;
}

pub fn destroy(client: *Client, gpa: std.mem.Allocator) void {
    std.debug.assert(client.closed);
    gpa.destroy(client);
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
