pub const MessageHeader = common.MessageHeaderGeneric(MessageTag);
pub const WithClientUUID = common.WithClientUUID;

pub const Message = struct {
    header: MessageHeader,
    data: []const u8,
};

pub const MessageTag = std.meta.Tag(MessagePayload);
pub const MessagePayload = union(enum(u32)) {
    registered: Void,

    viewport_create: ViewportCreate,
    viewport_created: ViewportCreated,
    viewport_resize: ViewportResize,
    viewport_close: ViewportClose,
    viewport_display_state: ViewportDisplayState,

    remote_viewport_created: RemoteViewportCreated,
    remote_viewport_display_state: RemoteViewportDisplayState,
    remote_viewport_render_size: RemoteViewportRenderSize,
    remote_viewport_closed: RemoteViewportClosed,

    client_registered: ClientRegistered,
    client_disconnected: ClientDisconnected,

    buffer_released: BufferReleased,
    buffer_created_cpu: BufferCreatedCpu,
    buffer_created_gbm_bo: BufferCreatedGbmBo,

    texture_created_d3d: TextureCreatedD3D,

    frame_render: FrameRender,

    keyboard_enter: KeyboardEnter,
    keyboard_leave: KeyboardLeave,
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

pub fn MayFail(comptime T: type, comptime R: type) type {
    std.debug.assert(@typeInfo(R) == .@"enum");
    return union(enum) {
        pub const Success = T;
        pub const FailureReason = R;

        success: T,
        failure: struct {
            request_id: types.RequestID,
            reason: FailureReason,
        },

        pub fn ok(v: Success) @This() {
            return .{ .success = v };
        }

        pub fn failed(rid: types.RequestID, v: FailureReason) @This() {
            return .{ .failure = .{ .request_id = rid, .reason = v } };
        }

        pub fn request_id(self: @This()) types.RequestID {
            return switch (self) {
                inline else => |v| v.request_id,
            };
        }
    };
}

pub const RequestFailed = struct {
    request_id: types.RequestID,
    reason: types.RequestFailureReason,
};

pub const BufferCreatedCpu = MayFail(struct {
    request_id: types.RequestID,
    buffer_id: types.BufferID,
    handle: types.CpuBufferHandle,
    size: types.Size,
    format: types.BufferFormat,
}, enum { failed_to_create_system_resources });

pub const BufferCreatedGbmBo = MayFail(struct {
    request_id: types.RequestID,
    buffer_id: types.BufferID,
    fds: types.BufferAndTimelineFds,
    size: types.Size,
    stride: u32,
    format: types.BufferFormat,
}, enum {
    invalid_size,
    failed_to_create_system_resources,
});

pub const TextureCreatedD3D = MayFail(struct {
    request_id: types.RequestID,
    buffer_id: types.BufferID,
    texture_handle: types.D3DTextureSharedHandle,
    acquire_fence_handle: types.D3DAcquireFenceSharedHandle,
    release_fence_handle: types.D3DReleaseFenceSharedHandle,
    size: types.Size,
    format: types.BufferFormat,
    version: types.D3DVersion,
}, enum {
    invalid_size,
    failed_to_create_system_resources,
});

pub const ViewportResize = struct {
    viewport_id: types.ViewportID,
    size: types.Size,
};

pub const RemoteViewportCreated = struct {
    remote_viewport_id: types.RemoteViewportID,
    status: types.Status,
    render_size: types.Size,
    viewport_key: types.ViewportKey,
};

pub const RemoteViewportClosed = struct {
    viewport_key: types.ViewportKey,
};

pub const ClientRegistered = struct {
    client_uuid: types.ClientUUID,
};

pub const ClientDisconnected = struct {
    client_uuid: types.ClientUUID,
};

pub const ViewportCreate = struct {
    viewport_id: types.ViewportID,
    size: types.Size,
};

pub const ViewportCreated = MayFail(struct {
    request_id: types.RequestID,
    viewport_id: types.ViewportID,
}, enum {
    parent_viewport_does_not_exist,
    invalid_viewport_id,
    failed_to_create_window,
    failed_to_create_system_resources,
    invalid_size,
});

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

pub const RemoteViewportDisplayState = struct {
    viewport_key: types.ViewportKey,
    state: types.ViewportDisplayState,
};

pub const RemoteViewportRenderSize = struct {
    viewport_key: types.ViewportKey,
    size: types.Size,
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

pub const KeyboardEnter = struct {
    viewport_id: types.ViewportID,
};

pub const KeyboardLeave = struct {
    viewport_id: types.ViewportID,
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
            const T = @FieldType(MessagePayload, @tagName(tag));
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

    if (parsed == .success) {
        switch (T) {
            BufferCreatedCpu => parsed.success.handle = fd,
            BufferCreatedGbmBo => parsed.success.fds = fd,
            else => comptime unreachable,
        }
    }

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
