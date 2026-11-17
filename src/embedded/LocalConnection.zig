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

pub fn send_register_local(c: *LocalConnection, io: Io) !void {
    const payload: client_to_server.Register = .{
        .uuid = c.uuid,
        .pid = null,
        .is_local = true,
    };
    var buf: [constants.payload_max_size]u8 = undefined;
    const message = c.stringify(&buf, .{ .register = payload });
    try c.send(io, message);
}

pub fn send_wake_up(c: *LocalConnection, io: Io) !void {
    var buf: [constants.payload_max_size]u8 = undefined;
    const message = c.stringify(&buf, .{ .wake_up = .{} });
    try c.send(io, message);
}

pub fn send_queue_pop(c: *LocalConnection, io: Io) !void {
    var buf: [constants.payload_max_size]u8 = undefined;
    const message = c.stringify(&buf, .{ .queue_pop = .{} });
    try c.send(io, message);
}

pub fn send_viewport_pos_set(c: *LocalConnection, io: Io, payload: client_to_server.ViewportPosSet) !void {
    var buf: [constants.payload_max_size]u8 = undefined;
    const message = c.stringify(&buf, .{ .viewport_pos_set = payload });
    try c.send(io, message);
}

pub fn send_viewport_size_set(c: *LocalConnection, io: Io, payload: client_to_server.ViewportSizeSet) !void {
    var buf: [constants.payload_max_size]u8 = undefined;
    const message = c.stringify(&buf, .{ .viewport_size_set = payload });
    try c.send(io, message);
}

pub fn send_viewport_display_state_set(c: *LocalConnection, io: Io, payload: client_to_server.ViewportDisplayStateSet) !void {
    var buf: [constants.payload_max_size]u8 = undefined;
    const message = c.stringify(&buf, .{ .viewport_display_state_set = payload });
    try c.send(io, message);
}

pub fn send_viewport_close(c: *LocalConnection, io: Io, payload: client_to_server.RemoteViewportClose) !void {
    var buf: [constants.payload_max_size]u8 = undefined;
    const message = c.stringify(&buf, .{ .viewport_close = payload });
    try c.send(io, message);
}

fn stringify(c: *LocalConnection, buf: []u8, payload: client_to_server.MessagePayload) client_to_server.Message {
    std.debug.assert(c.format == .json);
    std.debug.assert(buf.len == constants.payload_max_size);

    var writer: Io.Writer = .fixed(buf);
    switch (payload) {
        inline else => |p| std.json.Stringify.value(p, .{}, &writer) catch unreachable,
    }
    const json = writer.buffered();

    const header: client_to_server.MessageHeader = .{
        .payload_len = @intCast(json.len),
        .format = .json,
        .message_tag = payload,
    };

    return .{ .header = header, .payload = json };
}

fn send(c: *LocalConnection, _: Io, message: client_to_server.Message) !void {
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
const constants = @import("constants");
