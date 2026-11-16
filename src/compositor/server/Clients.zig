const Clients = @This();

list: std.ArrayList(*Client),

pub const init: Clients = .{
    .list = .empty,
};

pub fn deinit(clients: *Clients, _: Io, gpa: std.mem.Allocator) void {
    for (clients.list.items) |client| {
        client.connection.close(gpa);
        gpa.destroy(client);
    }
    clients.list.deinit(gpa);
}

pub fn count(clients: *const Clients) usize {
    return clients.list.items.len;
}

pub fn contains_remote(clients: *Clients, uuid: ptypes.ClientUUID) bool {
    return clients.get_remote(uuid) != null;
}

pub fn contains_local(clients: *Clients, uuid: ptypes.ClientUUID) bool {
    return clients.get_local(uuid) != null;
}

pub fn get_remote(clients: *Clients, uuid: ptypes.ClientUUID) ?*Client {
    for (clients.list.items) |client| {
        switch (client.kind) {
            .unknown, .local => {},
            .remote => |id| if (id == uuid) return client,
        }
    }

    return null;
}

pub fn get_local(clients: *Clients, uuid: ptypes.ClientUUID) ?*Client {
    for (clients.list.items) |client| {
        switch (client.kind) {
            .unknown, .remote => {},
            .local => |id| if (id == uuid) return client,
        }
    }

    return null;
}

pub fn contains(clients: *Clients, uuid: ptypes.ClientUUID) bool {
    for (clients.list.items) |client| {
        if (client.uuid() == uuid) return true;
    }

    return false;
}

pub fn new_unknown(clients: *Clients, gpa: std.mem.Allocator, stream: zio.net.Stream) !void {
    try clients.list.ensureUnusedCapacity(gpa, 1);

    const client = try gpa.create(Client);
    errdefer gpa.destroy(client);

    client.* = .{
        .connection = try .init(gpa, stream, null),
        .kind = .unknown,
    };
    clients.list.appendAssumeCapacity(client);
}

pub fn promote_client_to_remote(
    clients: *Clients,
    index: usize,
    id: ptypes.ClientUUID,
    pid: ?ptypes.PID,
) void {
    std.debug.assert(!clients.contains(id));

    const client = clients.list.items[index];
    std.debug.assert(client.kind == .unknown);
    client.kind = .{ .remote = id };

    client.connection.pid = pid;
}

pub fn promote_client_to_local(
    clients: *Clients,
    index: usize,
    id: ptypes.ClientUUID,
) void {
    std.debug.assert(!clients.contains(id));
    const client = clients.list.items[index];
    std.debug.assert(client.kind == .unknown);
    client.kind = .{ .local = id };
}

pub fn remove_closed_clients(clients: *Clients, gpa: std.mem.Allocator) void {
    var i = clients.list.items.len;
    while (i > 0) {
        i -= 1;
        const client = clients.list.items[i];
        if (!client.connection.closed) continue;

        if (client.uuid()) |uuid| {
            log.debug("Removed closed client {f}", .{uuid});
        }

        _ = clients.list.orderedRemove(i);
        gpa.destroy(client);
    }
}

pub const Client = struct {
    connection: ClientConnection,
    kind: Kind,

    pub fn uuid(client: *const Client) ?ptypes.ClientUUID {
        return switch (client.kind) {
            .unknown => null,
            inline else => |id| id,
        };
    }
};

pub const Kind = union(enum) {
    unknown,
    local: ptypes.ClientUUID,
    remote: ptypes.ClientUUID,
};

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const ClientConnection = @import("ClientConnection.zig");
const ptypes = @import("protocol").types;
const log = std.log.scoped(.Clients);
const zio = @import("zio");
