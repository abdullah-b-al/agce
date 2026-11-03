const LocalConnection = @This();

format: ptypes.MessageFormat,
stream: zio.net.Stream,

pub fn send_register_local(c: *LocalConnection, io: Io, gpa: std.mem.Allocator) !void {
    const payload: client_to_server.Register = .{
        .uuid = null,
        .pid = null,
        .is_local = true,
    };
    const message = try c.stringify(gpa, .{ .register = payload });
    try c.send(io, gpa, message);
}

pub fn send_wake_up(c: *LocalConnection, io: Io, gpa: std.mem.Allocator) !void {
    const message = try c.stringify(gpa, .{ .wake_up = .{} });
    try c.send(io, gpa, message);
}

pub fn send_queue_pop(c: *LocalConnection, io: Io, gpa: std.mem.Allocator) !void {
    const message = try c.stringify(gpa, .{ .queue_pop = .{} });
    try c.send(io, gpa, message);
}

fn stringify(c: *LocalConnection, gpa: std.mem.Allocator, payload: client_to_server.MessagePayload) !client_to_server.Message {
    std.debug.assert(c.format == .json);

    const json = switch (payload) {
        inline else => |p| try std.json.Stringify.valueAlloc(gpa, p, .{}),
    };

    const header: client_to_server.MessageHeader = .{
        .payload_len = @intCast(json.len),
        .format = .json,
        .message_tag = payload,
    };

    return .{ .header = header, .payload = json };
}

fn send(c: *LocalConnection, _: Io, gpa: std.mem.Allocator, message: client_to_server.Message) !void {
    defer gpa.free(message.payload);

    var buf: [4096]u8 = undefined;
    var writer = c.stream.writer(&buf);

    const header_bytes = std.mem.toBytes(message.header);
    try writer.interface.writeAll(&header_bytes);
    try writer.interface.writeAll(message.payload);
    try writer.interface.flush();
}

const std = @import("std");
const Io = std.Io;
const ptypes = @import("protocol").types;
const client_to_server = @import("protocol").client_to_server;
const zio = @import("zio");
