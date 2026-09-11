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
    viewport_close: ViewportClose,
    viewport_display_state: ViewportDisplayState,

    sub_viewport_embeded: SubViewportEmbeded,
    sub_viewport_display_state: SubViewportDisplayState,
    sub_viewport_closed: SubviewportClosed,

    client_registered: ClientRegistered,
    client_disconnected: ClientDisconnected,

    buffer_released: BufferReleased,
    buffer_created_cpu: BufferCreatedCpu,
    buffer_created_gbm_bo: BufferCreatedGbmBo,

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

    pub const Void = struct {};

    pub const BufferCreatedCpu = struct {
        viewport_id: types.ViewportID,
        buffer_id: types.BufferID,
        handle: types.CpuBufferHandle,
        size: types.Size,
        format: types.BufferFormat,
    };

    pub const BufferCreatedGbmBo = struct {
        viewport_id: types.ViewportID,
        buffer_id: types.BufferID,
        fds: types.BufferAndTimelineFds,
        size: types.Size,
        stride: u32,
        format: types.BufferFormat,
    };

    pub const ViewportResize = struct {
        viewport_id: types.ViewportID,
        size: types.Size,
    };

    pub const GeneratedClientFullID = struct {
        full_id: types.ClientFullID,
    };

    pub const SubViewportEmbeded = struct {
        sub_viewport_id: types.SubViewportID,
        status: types.Status,
        render_size: types.Size,
    };

    pub const SubviewportClosed = struct {
        sub_viewport_id: types.SubViewportID,
    };

    pub const ClientRegistered = struct {
        client_id: types.ClientID,
    };

    pub const ClientDisconnected = struct {
        client_id: types.ClientID,
    };

    pub const ViewportCreate = struct {
        viewport_id: types.ViewportID,
        size: types.Size,
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
        refresh_cycle: u32,
    };

    pub const ViewportClose = struct {
        viewport_id: types.ViewportID,
    };

    pub const ViewportDisplayState = struct {
        viewport_id: types.ViewportID,
        state: types.ViewportDisplayState,
    };

    pub const SubViewportDisplayState = struct {
        sub_viewport_id: types.SubViewportID,
        state: types.ViewportDisplayState,
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

pub fn message_send_json(io: Io, gpa: std.mem.Allocator, stream: net.Stream, comptime tag_name: []const u8, payload: MessagePayload) !void {
    const tag = comptime std.meta.stringToEnum(MessageTag, tag_name).?;
    std.debug.assert(payload == tag);

    const json = switch (tag) {
        .buffer_created_gbm_bo, .buffer_created_cpu => {
            try message_send_json_with_fd(gpa, stream, tag_name, payload);
            return;
        },
        inline else => blk: {
            const p = @field(payload, tag_name);
            break :blk try std.json.Stringify.valueAlloc(gpa, p, .{});
        },
    };
    defer gpa.free(json);

    const header: MessageHeader = .{
        .payload_len = @intCast(json.len),
        .format = .json,
        .message_tag = payload,
    };

    var buf: [4096]u8 = undefined;
    var writer = stream.writer(io, &buf);

    const header_bytes = std.mem.toBytes(header);
    try writer.interface.writeAll(&header_bytes);
    try writer.interface.writeAll(json);
    try writer.interface.flush();
}

pub fn message_receive_all(io: Io, arena: std.mem.Allocator, stream: net.Stream, timeout: Io.Timeout) ![]MessagePayload {
    var list: std.ArrayList(MessagePayload) = .empty;

    // Get one message at a time
    const first = try message_receive(io, arena, stream, timeout);
    try list.append(arena, first);

    // If there are any more messages get them
    const to: Io.Timeout = .{ .duration = .{ .raw = .fromNanoseconds(1), .clock = .awake } };
    while (true) {
        const message = message_receive(io, arena, stream, to) catch |err| switch (err) {
            error.Timeout => break,
            else => return err,
        };
        try list.append(arena, message);
    }

    return try list.toOwnedSlice(arena);
}

pub fn message_receive(io: Io, arena: std.mem.Allocator, stream: net.Stream, timeout: Io.Timeout) !MessagePayload {
    var buf: [@sizeOf(MessageHeader)]u8 = undefined;
    const peek = try common.operation_net_receive_peek(MessageHeader, io, stream, timeout, &buf);

    if (peek.data.len == 0) {
        return error.ConnectionClosed;
    }

    const header = try common.parse_message_header(MessageHeader, peek.data);

    const message_buf = try arena.alloc(u8, header.payload_len + @sizeOf(MessageHeader));
    switch (header.format) {
        .json => {
            return switch (os) {
                .linux => {
                    const message = try read_and_parse_data_json_linux(io, arena, stream, header, message_buf);
                    return message;
                },
                else => {
                    const message = try read_and_parse_data_json(io, arena, stream, header, message_buf);
                    return message;
                },
            };
        },
    }
}

fn read_and_parse_data_json(io: Io, arena: std.mem.Allocator, stream: net.Stream, header: MessageHeader, receive_buf: []u8) !MessagePayload {
    switch (header.message_tag) {
        inline else => |tag| {
            const T = utils.TypeOfField(MessagePayload, @tagName(tag));
            const parsed = try common.message_receive_and_parse_json(
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

fn message_send_json_with_fd(
    gpa: std.mem.Allocator,
    stream: net.Stream,
    comptime tag_name: []const u8,
    payload: MessagePayload,
) !void {
    if (!constants.os_supports_fd) {
        @compileError("OS does not support FD");
    }

    const tag = comptime std.meta.stringToEnum(MessageTag, tag_name).?;
    std.debug.assert(payload == tag);

    const json = blk: switch (tag) {
        .buffer_created_cpu,
        .buffer_created_gbm_bo,
        => |t| {
            var p = @field(payload, @tagName(t));

            // The fd that's part of the json is wrong.
            // Set them to .invalid to invalidate their use
            const T = @TypeOf(p);
            if (comptime common.contains_a_fd(T)) |name| {
                @field(p, name) = .invalid;
            }

            break :blk try std.json.Stringify.valueAlloc(gpa, p, .{});
        },
        inline else => @compileError("Invalid sender for message"),
    };
    defer gpa.free(json);

    const header: MessageHeader = .{
        .payload_len = @intCast(json.len),
        .format = .json,
        .message_tag = payload,
    };

    const header_bytes = std.mem.toBytes(header);
    var buf: [4096]u8 = undefined;
    std.mem.copyForwards(u8, &buf, &header_bytes);
    std.mem.copyForwards(u8, buf[header_bytes.len..], json);

    const len = @sizeOf(MessageHeader) + json.len;

    const fd, const Fd = switch (tag) {
        .buffer_created_cpu => .{ payload.buffer_created_cpu.handle, types.CpuBufferHandle },
        .buffer_created_gbm_bo => .{ payload.buffer_created_gbm_bo.fds, types.BufferAndTimelineFds },
        else => comptime unreachable,
    };

    const result = send_fd(stream.socket.handle, Fd, fd, buf[0..len]);
    if (result < 0) {
        return error.FailedToSendFds;
    }
}

fn send_fd(socket: c_int, comptime Fd: type, fd: Fd, data_to_send: []const u8) isize {
    var msg = std.mem.zeroes(c_linux.msghdr);

    var iov: c_linux.iovec = .{ .iov_base = @constCast(data_to_send.ptr), .iov_len = data_to_send.len };
    msg.msg_iov = @ptrCast(&iov);
    msg.msg_iovlen = 1;

    var buf: [c_linux.CMSG_SPACE(@sizeOf(Fd))]u8 = undefined;
    msg.msg_control = &buf;
    msg.msg_controllen = buf.len;

    const hdr = &c_linux.CMSG_FIRSTHDR(&msg)[0];
    hdr.cmsg_len = c_linux.CMSG_LEN(@sizeOf(Fd));
    hdr.cmsg_level = c_linux.SOL_SOCKET;
    hdr.cmsg_type = c_linux.SCM_RIGHTS;

    const ptr: [*]u8 = hdr.__cmsg_data();
    const data: *Fd = @ptrCast(@alignCast(ptr));
    data.* = fd;

    return c_linux.sendmsg(socket, &msg, 0);
}

fn read_and_parse_data_json_linux(
    io: Io,
    arena: std.mem.Allocator,
    stream: net.Stream,
    header: MessageHeader,
    receive_buf: []u8,
) !MessagePayload {
    std.debug.assert(header.format == .json);
    std.debug.assert(receive_buf.len == header.payload_len + @sizeOf(MessageHeader));

    switch (header.message_tag) {
        inline .buffer_created_gbm_bo,
        .buffer_created_cpu,
        => |tag| {
            const T = switch (tag) {
                .buffer_created_cpu => MessagePayload.BufferCreatedCpu,
                .buffer_created_gbm_bo => MessagePayload.BufferCreatedGbmBo,
                else => comptime unreachable,
            };
            const parsed = try parse_message_with_fd(T, io, arena, stream, receive_buf);
            return @unionInit(MessagePayload, @tagName(tag), parsed);
        },

        inline else => {
            return try read_and_parse_data_json(io, arena, stream, header, receive_buf);
        },
    }
}

fn parse_message_with_fd(comptime T: type, io: Io, arena: std.mem.Allocator, stream: net.Stream, receive_buf: []u8) !T {
    const Fd = switch (T) {
        MessagePayload.BufferCreatedCpu => types.CpuBufferHandle,
        MessagePayload.BufferCreatedGbmBo => types.BufferAndTimelineFds,
        else => comptime unreachable,
    };

    const fd = try recv_fd_peek(Fd, stream.socket.handle);

    const msg = try stream.socket.receive(io, receive_buf);
    const data = msg.data[@sizeOf(MessageHeader)..];

    var parsed = try std.json.parseFromSliceLeaky(T, arena, data, .{
        .allocate = .alloc_if_needed,
    });

    const name = comptime common.contains_a_fd(T).?;
    @field(parsed, name) = fd;

    return parsed;
}

fn recv_fd_peek(comptime Fd: type, socket: c_int) !Fd {
    var msg = std.mem.zeroes(c_linux.msghdr);

    var iov_base = "";
    var iov: c_linux.iovec = .{ .iov_base = @ptrCast(&iov_base), .iov_len = iov_base.len };
    msg.msg_iov = @ptrCast(&iov);
    msg.msg_iovlen = 1;

    var buf: [c_linux.CMSG_SPACE(@sizeOf(Fd))]u8 = undefined;
    msg.msg_control = &buf;
    msg.msg_controllen = buf.len;

    const bytes = c_linux.recvmsg(socket, &msg, c_linux.MSG_PEEK);
    if (bytes < 0) {
        return error.RecvMsgFailed;
    }

    const hdr = &c_linux.CMSG_FIRSTHDR(&msg)[0];
    if (@intFromPtr(hdr) == 0) {
        return error.CmsgNoHeader;
    }

    if (hdr.cmsg_level != c_linux.SOL_SOCKET) {
        return error.CmsgInvalidLevel;
    }

    if (hdr.cmsg_type != c_linux.SCM_RIGHTS) {
        return error.CmsgInvalidType;
    }

    const ptr: [*]u8 = hdr.__cmsg_data();
    const data: *Fd = @ptrCast(@alignCast(ptr));
    return data.*;
}

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const utils = @import("utils");
const types = @import("types.zig");
const common = @import("common.zig");
const os = @import("builtin").os.tag;
const input = @import("input.zig");
const constants = @import("constants");
const c_linux = @import("c_linux");
