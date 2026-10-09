pub fn parse_message_header(data: []const u8) !MessageHeader {
    return try common.parse_message_header(MessageHeader, data);
}

pub fn operation_net_receive_peek(io: Io, stream: net.Stream, timeout: Io.Timeout, buf: []u8) !net.IncomingMessage {
    return try common.operation_net_receive_peek(MessageHeader, io, stream, timeout, buf);
}

pub fn send_fd(socket: c_int, comptime Fd: type, fd: Fd, data_to_send: []const u8) isize {
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

pub fn read_and_parse_data_json_linux(
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
                .buffer_created_cpu => BufferCreatedCpu,
                .buffer_created_gbm_bo => BufferCreatedGbmBo,
                else => comptime unreachable,
            };
            const parsed = try parse_message_with_fd(T, io, arena, stream, receive_buf);
            return @unionInit(MessagePayload, @tagName(tag), parsed);
        },

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

fn parse_message_with_fd(comptime T: type, io: Io, arena: std.mem.Allocator, stream: net.Stream, receive_buf: []u8) !T {
    const Fd = switch (T) {
        BufferCreatedCpu => types.CpuBufferHandle,
        BufferCreatedGbmBo => types.BufferAndTimelineFds,
        else => comptime unreachable,
    };

    const fd = try recv_fd_peek(Fd, stream.socket.handle);

    const msg = try stream.socket.receive(io, receive_buf);
    const data = msg.data[@sizeOf(MessageHeader)..];

    var parsed = try std.json.parseFromSliceLeaky(T, arena, data, .{
        .allocate = .alloc_if_needed,
    });

    const name = comptime utils.contains_a_fd(T).?;
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

    texture_created_d3d: TextureCreatedD3D,

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
};

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

pub const TextureCreatedD3D = struct {
    viewport_id: types.ViewportID,
    buffer_id: types.BufferID,
    handle: types.D3DTextureHandle,
    size: types.Size,
    format: types.BufferFormat,
    version: types.D3DVersion,
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
