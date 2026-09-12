pub fn operation_net_receive_peek(comptime MessageHeader: type, io: Io, stream: net.Stream, timeout: Io.Timeout, buf: []u8) !net.IncomingMessage {
    std.debug.assert(buf.len >= @sizeOf(MessageHeader));

    // len must be one inorder for recv_fd to work
    var msg_buf: [1]net.IncomingMessage = undefined;

    const op: Io.Operation = .{
        .net_receive = .{
            .socket_handle = stream.socket.handle,
            .message_buffer = &msg_buf,
            .data_buffer = buf,
            .flags = .{ .peek = true },
        },
    };

    const err, const len = (try io.operateTimeout(op, timeout)).net_receive;
    if (err) |e| {
        return e;
    }

    std.debug.assert(len == 1);

    return msg_buf[0];
}

pub fn message_receive_and_parse_json(
    comptime MessageHeader: type,
    comptime Message: type,
    io: Io,
    arena: std.mem.Allocator,
    stream: net.Stream,
    header: MessageHeader,
    receive_buf: []u8,
) !Message {
    std.debug.assert(header.format == .json);
    std.debug.assert(receive_buf.len == header.payload_len + @sizeOf(MessageHeader));

    const msg = try stream.socket.receive(io, receive_buf);
    const data = msg.data[@sizeOf(MessageHeader)..][0..header.payload_len];
    const parsed = try std.json.parseFromSliceLeaky(Message, arena, data, .{
        .allocate = .alloc_if_needed,
    });
    return parsed;
}

pub fn parse_message_header(comptime Header: type, data: []const u8) !Header {
    std.debug.assert(data.len > 0);

    const len = @sizeOf(Header);
    if (len > data.len) {
        return error.HeaderInvalidLen;
    }
    const data_header = data[0..len];
    const header: Header = try .parse(data_header);
    return header;
}

const std = @import("std");
const os = @import("builtin").os.tag;
const Io = std.Io;
const net = Io.net;
