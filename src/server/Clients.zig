const Clients = @This();

known_pool: std.heap.MemoryPoolExtra(Client, .{ .growable = false }),
unknown_pool: std.heap.MemoryPoolExtra(UnknownClient, .{ .growable = false }),
known: std.array_hash_map.Auto(ptypes.ClientID, *Client),
unknown: std.ArrayList(*UnknownClient),
next_id: ptypes.ClientID,

pub const init: Clients = .{
    .known_pool = .empty,
    .unknown_pool = .empty,
    .next_id = .first,
    .known = .empty,
    .unknown = .empty,
};

pub fn deinit(clients: *Clients, io: Io, gpa: std.mem.Allocator) void {
    for (clients.known.values()) |client| {
        client.close(io);
    }
    clients.known.deinit(gpa);
    clients.known_pool.deinit(gpa);

    for (clients.unknown.items) |client| {
        client.close(io);
    }
    clients.unknown.deinit(gpa);
    clients.unknown_pool.deinit(gpa);
}

pub fn count(clients: *const Clients) usize {
    return clients.known.count() + clients.unknown.items.len;
}

pub fn prepare_for_new_client(clients: *Clients, gpa: std.mem.Allocator) !void {
    const total = @max(
        clients.known.capacity(),
        clients.unknown.capacity,
    ) + 1;

    try clients.known.ensureTotalCapacity(gpa, total);
    try clients.unknown.ensureTotalCapacity(gpa, total);
    try clients.known_pool.addCapacity(gpa, 1);
    try clients.unknown_pool.addCapacity(gpa, 1);
}

pub fn new_unknown(clients: *Clients, gpa: std.mem.Allocator, stream: net.Stream) void {
    const client = clients.unknown_pool.create(gpa) catch @panic("Must reserve objects first");
    client.* = .{
        .stream = stream,
        .closed = false,
        .promoted_to_known = false,
    };
    clients.unknown.appendAssumeCapacity(client);
}

pub fn promote_client_to_known(clients: *Clients, gpa: std.mem.Allocator, index: usize, id: ptypes.ClientID) void {
    const unknown = clients.unknown.items[index];
    std.debug.assert(!unknown.promoted_to_known);

    const client = clients.known_pool.create(gpa) catch @panic("Must reserve objects first");
    client.* = .{
        .id = id,
        .stream = unknown.stream,
        .closed = false,
    };

    clients.known.putAssumeCapacityNoClobber(id, client);
    unknown.promoted_to_known = true;
}

pub fn remove_closed_known_clients(clients: *Clients) void {
    var i = clients.known.count();
    while (i > 0) {
        i -= 1;
        const client = clients.known.values()[i];
        if (client.closed) {
            const id = client.id;
            log.debug("Removed closed client {f}", .{id});
            clients.known_pool.destroy(@alignCast(client));
            _ = clients.known.orderedRemove(id);
        }
    }
}

pub fn remove_promoted_or_closed_unknown_clients(clients: *Clients) void {
    var i = clients.unknown.items.len;
    while (i > 0) {
        i -= 1;
        const client = clients.unknown.items[i];
        if (client.promoted_to_known or client.closed) {
            clients.unknown_pool.destroy(@alignCast(client));
            _ = clients.unknown.orderedRemove(i);
        }
    }
}

pub const Client = struct {
    id: ptypes.ClientID,
    stream: net.Stream,
    closed: bool,

    pub fn close(client: *Client, io: Io) void {
        std.debug.assert(!client.closed);
        client.stream.close(io);
        client.closed = true;
    }
};

pub const UnknownClient = struct {
    stream: net.Stream,
    closed: bool,
    promoted_to_known: bool,

    pub fn close(unknown: *UnknownClient, io: Io) void {
        std.debug.assert(!unknown.closed);
        unknown.stream.close(io);
        unknown.closed = true;
    }
};

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const ptypes = @import("protocol").types;
const log = std.log.scoped(.Clients);
