const LocalConnection = @This();

uuid: ptypes.ClientUUID,
format: ptypes.MessageFormat,
stream: zio.net.Stream,

pub fn receive_with_reader(_: *LocalConnection, arena: std.mem.Allocator, reader: *Io.Reader) !server_to_client.MessagePayload {
    const header_bytes = try reader.take(@sizeOf(client_to_server.MessageHeader));

    const header = try server_to_client.parse_message_header(header_bytes);
    const err_data = if (header.payload_len > reader.buffer.len)
        reader.readAlloc(arena, header.payload_len)
    else
        reader.take(header.payload_len);

    const data = err_data catch |err| return switch (err) {
        error.EndOfStream => error.HeaderWithoutPayload,
        error.ReadFailed, error.OutOfMemory => |e| e,
    };

    switch (header.message_tag) {
        inline else => |tag| {
            switch (header.format) {
                .json => {
                    @setEvalBranchQuota(2000);
                    const T = @FieldType(server_to_client.MessagePayload, @tagName(tag));
                    const parsed = try std.json.parseFromSliceLeaky(T, arena, data, .{
                        .allocate = .alloc_if_needed,
                    });

                    return @unionInit(server_to_client.MessagePayload, @tagName(tag), parsed);
                },
            }
        },
    }
}

pub fn send_register_local(c: *LocalConnection, io: Io, gpa: std.mem.Allocator) !void {
    const payload: client_to_server.Register = .{
        .uuid = c.uuid,
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
const server_to_client = @import("protocol").server_to_client;
const zio = @import("zio");
