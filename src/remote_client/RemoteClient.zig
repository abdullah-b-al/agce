const RemoteClient = @This();

uuid: ptypes.ClientUUID,
status: Status,

pub fn init(io: Io) RemoteClient {
    return .{ .uuid = .new(io), .status = .pending };
}

pub fn connected(remote: *RemoteClient) void {
    std.debug.assert(remote.status == .pending);
    remote.status = .connected;
}

pub const Status = enum {
    connected,
    pending,
    disconnected,
};

const std = @import("std");
const Io = std.Io;
const ptypes = @import("protocol").types;
const Process = @import("Process.zig");
