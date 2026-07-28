const Clients = @This();

map: Map,
next_id: ClientID,

pub const init: Clients = .{
    .next_id = .first,
    .map = .empty,
};

pub fn map_clone(cs: *Clients, gpa: std.mem.Allocator) !MapClone {
    const map = try gpa.create(Map);
    errdefer gpa.destroy(map);
    map.* = try cs.map.clone(gpa);
    return .{
        .gpa = gpa,
        .map = map,
    };
}

pub fn new_id(cs: *Clients) ClientID {
    const id = cs.next_id;

    cs.next_id = @enumFromInt(@intFromEnum(cs.next_id) + 1);

    return id;
}

pub const Map = std.array_hash_map.Auto(ClientID, *Client);

pub const MapClone = struct {
    gpa: std.mem.Allocator,
    map: *Map,

    pub fn deinit(clone: *const MapClone) void {
        clone.map.deinit(clone.gpa);
        clone.gpa.destroy(clone.map);
    }
};

pub const ClientID = enum(u32) {
    pub const first: ClientID = @enumFromInt(1);
    _,
};

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const Client = @import("Client.zig");
