pub const MessageHeader = types.MessageHeaderGeneric(MessageTag);

pub const Message = struct {
    header: MessageHeader,
    data: []const u8,

    pub fn init(data: []const u8, format: types.MessageFormat, tag: MessageTag) Message {
        return .{
            .header = .{
                .len = @intCast(data.len + @sizeOf(MessageHeader)),
                .format = format,
                .message_tag = tag,
            },
            .data = data,
        };
    }
};

pub const MessageData = union(MessageTag) {
    viewport_resize: types.ViewportResize,
};

pub const MessageTag = enum(u32) {
    viewport_resize,
};

pub fn message_send_json(io: Io, gpa: std.mem.Allocator, stream: net.Stream, message: MessageData) !void {
    const payload = try std.json.Stringify.valueAlloc(gpa, message, .{});
    defer gpa.free(payload);

    const header: MessageHeader = .{
        .len = @intCast(@sizeOf(MessageHeader) + payload.len),
        .format = .json,
        .message_tag = message,
    };
    const header_bytes = std.mem.toBytes(header);

    var buf: [4096]u8 = undefined;
    var writer = stream.writer(io, &buf);

    try writer.interface.writeAll(&header_bytes);
    try writer.interface.writeAll(payload);
    try writer.interface.flush();
}

pub fn read_and_parse_data_json(io: Io, arena: std.mem.Allocator, stream: net.Stream, header: MessageHeader, receive_buf: []u8) !MessageData {
    return try common.read_and_parse_data_json(
        MessageHeader,
        MessageData,
        io,
        arena,
        stream,
        header,
        receive_buf,
    );
}

pub fn message_receive(io: Io, arena: std.mem.Allocator, stream: net.Stream, timeout: Io.Timeout) !?MessageData {
    var buf: [@sizeOf(MessageHeader)]u8 = undefined;
    const peek = common.operation_net_receive_peek(MessageHeader, io, stream, timeout, &buf) catch |err|
        switch (err) {
            error.Timeout => return null,
            else => |e| return e,
        };

    if (peek.data.len == 0) {
        return error.ConnectionClosed;
    }

    const header = try common.parse_message_header(MessageHeader, peek.data);

    const message_buf = try arena.alloc(u8, header.len);
    switch (header.format) {
        .json => {
            const message = try read_and_parse_data_json(io, arena, stream, header, message_buf);
            return message;
        },
    }
}

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const types = @import("types.zig");
const common = @import("common.zig");
const os_tag = @import("builtin").os.tag;
