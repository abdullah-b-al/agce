pub const MessageHeader = types.MessageHeaderGeneric(MessageTag);

pub const Message = struct {
    header: MessageHeader,
    data: []const u8,
};

pub const MessageTag = std.meta.Tag(MessagePayload);
pub const MessagePayload = union(enum(u32)) {
    viewport_resize: types.ViewportResize,
    buffer_released: BufferReleased,
    buffer_destroyed: BufferDestroyed,

    pub const BufferReleased = struct {
        viewport_id: types.ViewportID,
        buffer_id: types.BufferID,
    };
    pub const BufferDestroyed = struct {
        buffer_id: types.BufferID,
    };
};

pub fn message_send_json(io: Io, gpa: std.mem.Allocator, stream: net.Stream, payload: MessagePayload) !void {
    const json = switch (payload) {
        inline else => |p| try std.json.Stringify.valueAlloc(gpa, p, .{}),
    };
    defer gpa.free(json);

    const header: MessageHeader = .{
        .len = @intCast(@sizeOf(MessageHeader) + json.len),
        .format = .json,
        .message_tag = payload,
    };
    const header_bytes = std.mem.toBytes(header);

    var buf: [4096]u8 = undefined;
    var writer = stream.writer(io, &buf);

    try writer.interface.writeAll(&header_bytes);
    try writer.interface.writeAll(json);
    try writer.interface.flush();
}

pub fn message_receive(io: Io, arena: std.mem.Allocator, stream: net.Stream, timeout: Io.Timeout) !?MessagePayload {
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

fn read_and_parse_data_json(io: Io, arena: std.mem.Allocator, stream: net.Stream, header: MessageHeader, receive_buf: []u8) !MessagePayload {
    switch (header.message_tag) {
        inline else => |tag| {
            const T = common.TypeOfUnionField(MessagePayload, @tagName(tag));
            const parsed = try common.read_and_parse_data_json(
                MessageHeader,
                T,
                io,
                arena,
                stream,
                header,
                receive_buf,
            );

            return @unionInit(MessagePayload, @tagName(tag), parsed);
        },
    }
}

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const types = @import("types.zig");
const common = @import("common.zig");
const os_tag = @import("builtin").os.tag;
