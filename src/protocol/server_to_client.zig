pub const MessageHeader = types.MessageHeaderGeneric(MessageTag);

pub const Message = struct {
    header: MessageHeader,
    data: []const u8,
};

pub const MessageTag = std.meta.Tag(MessagePayload);
pub const MessagePayload = union(enum(u32)) {
    registered: Void,
    generated_client_full_id: GeneratedClientFullID,

    viewport_create: ViewportCreate,
    viewport_created: ViewportCreated,
    viewport_resize: ViewportResize,
    viewport_closed: ViewportClosed,

    sub_viewport_embeded: SubviewportCreated,
    sub_viewport_display_state: SubViewportDisplayState,
    sub_viewport_closed: SubviewportClosed,

    client_registered: ClientRegistered,
    client_disconnected: ClientDisconnected,

    buffer_released: BufferReleased,
    buffer_destroyed: BufferDestroyed,
    buffer_created: BufferCreated,

    frame_render: FrameRender,

    keyboard_char: KeyboardChar,
    keyboard_key: KeyboardKey,
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

    pub const Void = struct { void: u8 = 0 };

    pub const ViewportResize = struct {
        viewport_id: types.ViewportID,
        size: types.Size,
    };

    pub const GeneratedClientFullID = struct {
        full_id: types.ClientFullID,
    };

    pub const SubviewportCreated = struct {
        sub_viewport_id: types.SubViewportID,
        status: types.Status,
        render_size: types.Size,
    };

    pub const SubviewportClosed = struct {
        sub_viewport_id: types.SubViewportID,
    };

    pub const ClientRegistered = struct {
        client_id: types.ClientID,
        info: ?types.ClientInfo,
    };

    pub const ClientDisconnected = struct {
        client_id: types.ClientID,
    };

    pub const ViewportCreate = struct {
        viewport_id: types.ViewportID,
        width: u32,
        height: u32,
    };

    pub const ViewportCreated = struct {
        viewport_id: types.ViewportID,
        status: types.Status,
    };

    pub const BufferReleased = struct {
        viewport_id: types.ViewportID,
        buffer_id: types.BufferID,
    };

    pub const FrameRender = struct {
        viewport_id: types.ViewportID,
    };

    pub const ViewportClosed = struct {
        viewport_id: types.ViewportID,
    };

    pub const ViewportShown = struct {
        viewport_id: types.ViewportID,
    };

    pub const SubViewportDisplayState = struct {
        sub_viewport_id: types.SubViewportID,
        state: types.ViewportDisplayState,
    };

    pub const BufferDestroyed = struct {
        buffer_id: types.BufferID,
    };

    pub const BufferCreated = struct {
        buffer_id: types.BufferID,
        status: types.Status,
    };

    pub const KeyboardChar = struct {
        viewport_id: types.ViewportID,
        char: u32,
    };

    pub const KeyboardKey = struct {
        viewport_id: types.ViewportID,
        key: input.Key,
        state: input.KeyState,
        modifiers: input.Modifiers,
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
        button: input.MouseButton,
        state: input.MouseState,
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
        .payload_len = @intCast(json.len),
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

pub fn message_receive_all(io: Io, arena: std.mem.Allocator, stream: net.Stream, timeout: Io.Timeout) ![]MessagePayload {
    const buf = try arena.alloc(u8, 1024 * 1024); // 1MB

    var msg_buf: [128]net.IncomingMessage = undefined;

    const op: Io.Operation = .{
        .net_receive = .{
            .socket_handle = stream.socket.handle,
            .message_buffer = &msg_buf,
            .data_buffer = buf,
            .flags = .{},
        },
    };

    const err, const len = (try io.operateTimeout(op, timeout)).net_receive;
    if (err) |e| {
        return e;
    }

    var list: std.ArrayList(MessagePayload) = .empty;
    for (msg_buf[0..len]) |msg| {
        if (msg.data.len == 0) {
            return error.ConnectionClosed;
        }

        const header = try common.parse_message_header(MessageHeader, msg.data);
        switch (header.format) {
            .json => {
                const message = try parse_data_json(arena, msg.data, header);
                try list.append(arena, message);
            },
        }
    }

    return try list.toOwnedSlice(arena);
}

fn parse_data_json(arena: std.mem.Allocator, raw_data: []const u8, header: MessageHeader) !MessagePayload {
    if (header.payload_len + @sizeOf(MessageHeader) > raw_data.len) {
        return error.IncompleteMessage;
    }

    switch (header.message_tag) {
        inline else => |tag| {
            const T = utils.TypeOfField(MessagePayload, @tagName(tag));
            const data = raw_data[@sizeOf(MessageHeader)..][0..header.payload_len];
            const parsed = try std.json.parseFromSliceLeaky(T, arena, data, .{
                .allocate = .alloc_if_needed,
            });

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
const input = @import("input.zig");
