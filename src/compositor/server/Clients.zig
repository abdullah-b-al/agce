const Clients = @This();

known_pool: std.heap.MemoryPoolExtra(Client, .{ .growable = false }),
unknown_pool: std.heap.MemoryPoolExtra(UnknownClient, .{ .growable = false }),
local_pool: std.heap.MemoryPoolExtra(LocalClient, .{ .growable = false }),

known: std.array_hash_map.Auto(ptypes.ClientUUID, *Client),
unknown: std.ArrayList(*UnknownClient),
local: std.ArrayList(*LocalClient),

pub const init: Clients = .{
    .known_pool = .empty,
    .unknown_pool = .empty,
    .local_pool = .empty,

    .known = .empty,
    .unknown = .empty,
    .local = .empty,
};

pub fn deinit(clients: *Clients, _: Io, gpa: std.mem.Allocator) void {
    inline for (.{
        clients.known.values(),
        clients.unknown.items,
        clients.local.items,
    }) |slice| {
        for (slice) |client| {
            client.connection.close();
        }
    }

    inline for (.{
        &clients.known,
        &clients.unknown,
        &clients.local,
    }) |entry| {
        entry.deinit(gpa);
    }

    inline for (.{
        &clients.known_pool,
        &clients.unknown_pool,
        &clients.local_pool,
    }) |pool| {
        pool.deinit(gpa);
    }
}

pub fn count(clients: *const Clients) usize {
    return clients.known.count() +
        clients.unknown.items.len +
        clients.local.items.len;
}

pub fn prepare_for_new_client(clients: *Clients, gpa: std.mem.Allocator) !void {
    try clients.known.ensureUnusedCapacity(gpa, 1);
    try clients.unknown.ensureUnusedCapacity(gpa, 1);
    try clients.local.ensureUnusedCapacity(gpa, 1);

    const c = clients.count() + 1;

    inline for (.{
        &clients.known_pool,
        &clients.unknown_pool,
        &clients.local_pool,
    }) |pool| {
        while (pool.free_list.len() < c) {
            try pool.addCapacity(gpa, 1);
        }
    }
}

pub fn new_unknown(clients: *Clients, gpa: std.mem.Allocator, stream: zio.net.Stream) !void {
    const client = clients.unknown_pool.create(gpa) catch @panic("Must reserve objects first");

    client.* = .{
        .connection = .{
            .format = .json,
            .stream = stream,
            .closed = false,
            .pid = null,
            .close_with_error = null,

            .win32_event_handle = try .create(stream.socket, .client),
        },
        .promoted = false,
    };
    clients.unknown.appendAssumeCapacity(client);
}

pub fn promote_client_to_known(
    clients: *Clients,
    gpa: std.mem.Allocator,
    index: usize,
    id: ptypes.ClientUUID,
    pid: ?ptypes.PID,
) void {
    std.debug.assert(!clients.known.contains(id));

    const unknown = clients.unknown.items[index];
    std.debug.assert(!unknown.promoted);

    const client = clients.known_pool.create(gpa) catch @panic("Must reserve objects first");
    client.* = .{
        .id = id,
        .pid = pid,
        .connection = .{
            .format = unknown.connection.format,
            .stream = unknown.connection.stream,
            .closed = false,
            .pid = pid,
            .close_with_error = null,
            .win32_event_handle = unknown.connection.win32_event_handle,
        },
    };

    clients.known.putAssumeCapacityNoClobber(id, client);
    unknown.promoted = true;
}

pub fn promote_client_to_local(
    clients: *Clients,
    gpa: std.mem.Allocator,
    index: usize,
) void {
    const unknown = clients.unknown.items[index];
    std.debug.assert(!unknown.promoted);

    const client = clients.local_pool.create(gpa) catch @panic("Must reserve objects first");
    client.* = .{
        .connection = .{
            .format = unknown.connection.format,
            .stream = unknown.connection.stream,
            .closed = false,
            .pid = null,
            .close_with_error = null,
            .win32_event_handle = unknown.connection.win32_event_handle,
        },
    };

    clients.local.appendAssumeCapacity(client);
    unknown.promoted = true;
}

pub fn remove_closed_clients_known_or_local(clients: *Clients) void {
    {
        var i = clients.known.count();
        while (i > 0) {
            i -= 1;
            const client = clients.known.values()[i];
            if (client.connection.closed) {
                const id = client.id;
                log.debug("Removed closed client {f}", .{id});
                clients.known_pool.destroy(@alignCast(client));
                _ = clients.known.orderedRemove(id);
            }
        }
    }

    {
        var i = clients.local.items.len;
        while (i > 0) {
            i -= 1;
            const client = clients.local.items[i];
            if (client.connection.closed) {
                log.debug("Removed local client", .{});
                clients.local_pool.destroy(@alignCast(client));
                _ = clients.local.orderedRemove(i);
            }
        }
    }
}

pub fn remove_promoted_or_closed_unknown_clients(clients: *Clients) void {
    var i = clients.unknown.items.len;
    while (i > 0) {
        i -= 1;
        const client = clients.unknown.items[i];
        if (client.promoted or client.connection.closed) {
            clients.unknown_pool.destroy(@alignCast(client));
            _ = clients.unknown.orderedRemove(i);
        }
    }
}

pub const Client = struct {
    id: ptypes.ClientUUID,
    pid: ?ptypes.PID,
    connection: ClientConnection,
};

pub const LocalClient = struct {
    connection: ClientConnection,
};

pub const UnknownClient = struct {
    connection: ClientConnection,
    promoted: bool,
};

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const ClientConnection = @import("ClientConnection.zig");
const ptypes = @import("protocol").types;
const log = std.log.scoped(.Clients);
const zio = @import("zio");
