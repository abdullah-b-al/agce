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

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const Clients = @import("Clients.zig");
const protocol = @import("protocol.zig");
const MessageFromClient = protocol.MessageFromClient;
