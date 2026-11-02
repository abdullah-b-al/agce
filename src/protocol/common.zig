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

pub fn MessageHeaderGeneric(comptime MessageTag: type) type {
    return extern struct {
        const Header = @This();

        payload_len: u32,
        format: types.MessageFormat,
        message_tag: MessageTag,

        comptime {
            if (@sizeOf(Header) != 12) {
                @compileError("Header size changed. It must always be 12 bytes long");
            }
        }

        pub fn parse(data: []const u8) !Header {
            std.debug.assert(@sizeOf(Header) == data.len);

            const head_payload_len = parse_len(data);
            const header_format = try parse_format(data);
            const header_message_tag = try parse_message_tag(data);

            return .{
                .payload_len = head_payload_len,
                .format = header_format,
                .message_tag = header_message_tag,
            };
        }

        fn parse_len(data: []const u8) @FieldType(Header, "payload_len") {
            return parse_int_of("payload_len", data);
        }

        fn parse_format(data: []const u8) error{HeaderInvalidFormat}!@FieldType(Header, "format") {
            const int = parse_int_of("format", data);
            return std.enums.fromInt(types.MessageFormat, int) orelse error.HeaderInvalidFormat;
        }

        fn parse_message_tag(data: []const u8) error{HeaderInvalidMessageTag}!@FieldType(Header, "message_tag") {
            const int = parse_int_of("message_tag", data);
            return std.enums.fromInt(MessageTag, int) orelse error.HeaderInvalidMessageTag;
        }

        fn parse_int_of(comptime name: []const u8, data: []const u8) u32 {
            std.debug.assert(data.len >= @sizeOf(Header));

            const F = @FieldType(Header, name);
            const offset = @offsetOf(Header, name);
            const len = @sizeOf(F);

            const slice = data[offset..][0..len];
            const int = std.mem.bytesToValue(u32, slice);
            return int;
        }
    };
}

pub fn WithClientUUID(comptime T: type) type {
    return struct {
        client_uuid: types.ClientUUID,
        payload: T,
    };
}

const std = @import("std");
const os = @import("builtin").os.tag;
const types = @import("types.zig");
const Io = std.Io;
const net = Io.net;
