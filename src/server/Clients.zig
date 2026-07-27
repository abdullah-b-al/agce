const Clients = @This();

mutex: Io.Mutex,
map: std.array_hash_map.Auto(ClientID, Client),
next_id: ClientID,

pub const init: Clients = .{
    .next_id = .first,
    .map = .empty,
    .mutex = .init,
};

pub fn lock(cs: *Clients, io: Io) void {
    cs.mutex.lockUncancelable(io);
}

pub fn unlock(cs: *Clients, io: Io) void {
    cs.mutex.unlock(io);
}

pub fn ensure_unused_capacity(cs: *Clients, io: Io, gpa: std.mem.Allocator, count: usize) !void {
    cs.lock(io);
    defer cs.unlock(io);

    try cs.map.ensureUnusedCapacity(gpa, count);
}

pub fn add_assume_capacity(cs: *Clients, io: Io, stream: net.Stream) ClientID {
    cs.lock(io);
    defer cs.unlock(io);

    const id = cs.new_id();
    cs.map.putAssumeCapacityNoClobber(id, .init(id, stream));

    return id;
}

fn new_id(cs: *Clients) ClientID {
    const id = cs.next_id;

    cs.next_id = @enumFromInt(@intFromEnum(cs.next_id) + 1);

    return id;
}

pub const ClientID = enum(u32) {
    pub const first: ClientID = @enumFromInt(1);
    _,
};

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const Client = @import("Client.zig");
