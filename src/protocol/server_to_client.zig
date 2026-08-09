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
    buffer_created: BufferCreated,

    mouse_enter: MouseEnter,
    mouse_leave: MouseLeave,
    mouse_motion: MouseMotion,
    mouse_button: MouseButton,
    mouse_scroll: MouseScroll,

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        switch (self) {
            inline else => |v, tag| {
                try utils.format_active_union_field(v, @tagName(tag), writer);
            },
        }
    }

    pub const BufferReleased = struct {
        viewport_id: types.ViewportID,
        buffer_id: types.BufferID,
    };

    pub const BufferDestroyed = struct {
        buffer_id: types.BufferID,
    };

    pub const BufferCreated = struct {
        buffer_id: types.BufferID,
        status: types.Status,
    };

    pub const MouseEnter = struct {
        viewport_id: types.ViewportID,
    };

    pub const MouseLeave = struct {
        viewport_id: types.ViewportID,
    };

    pub const MouseMotion = struct {
        viewport_id: types.ViewportID,
        x: f32,
        y: f32,
    };

    pub const MouseButton = struct {
        viewport_id: types.ViewportID,
        button: types.MouseButton,
        state: types.MouseButtonState,
    };

    pub const MouseScroll = struct {
        viewport_id: types.ViewportID,
        axis: types.ScrollAxis,
        value: f32,
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

pub fn message_receive(io: Io, arena: std.mem.Allocator, stream: net.Stream, timeout: Io.Timeout) !MessagePayload {
    var buf: [@sizeOf(MessageHeader)]u8 = undefined;
    const peek = try common.operation_net_receive_peek(MessageHeader, io, stream, timeout, &buf);

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
const utils = @import("utils");
const types = @import("types.zig");
const common = @import("common.zig");
const os_tag = @import("builtin").os.tag;
