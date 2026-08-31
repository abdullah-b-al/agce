pub const MessageHeader = types.MessageHeaderGeneric(MessageTag);

pub const Message = struct {
    header: MessageHeader,
    payload: []const u8,
};

pub const MessageTag = std.meta.Tag(MessagePayload);
pub const MessagePayload = union(enum(u32)) {
    register: Register,
    generate_client_full_id: Void,

    buffer_create_cpu_with_fd: BufferCreateCpuWithFd,
    buffer_create_gpu_with_fds: BufferCreateGpuWithFds,

    buffer_destroy: BufferDestroy,

    buffer_present: BufferPresent,
    buffer_present_with_sync: BufferPresentWithSync,

    viewport_create: ViewportCreate,
    sub_viewport_embed: SubViewportEmbed,
    sub_viewport_rect_set: SubViewportRectSet,
    sub_viewport_display_state_set: SubViewportDisplayStateSet,

    cursor_shape_set: CursorShape,

    pub const Register = struct {
        full_id: ?types.ClientFullID,
        info: ?types.ClientInfoClone,
    };

    pub const Void = struct { void: u8 = 0 };

    pub const SubViewportDisplayStateSet = struct {
        sub_viewport_id: types.SubViewportID,
        state: types.ViewportDisplayState,
    };

    pub const ViewportCreate = struct {
        viewport_id: types.ViewportID,
        create_sync_timeline: bool,
        vsync: bool,

        size: types.Size,
    };

    pub const SubViewportEmbed = struct {
        client_id_to_embed: types.ClientID,
        sub_viewport_id: types.SubViewportID,
        rect: types.Rect,
        embeder_viewport_id: types.ViewportID,
    };

    pub const SubViewportRectSet = struct {
        sub_viewport_id: types.SubViewportID,
        rect: types.Rect,
    };

    pub const BufferCreateCpuWithFd = struct {
        buffer_id: types.BufferID,

        fd: types.CpuBufferFd,

        width: u32,
        height: u32,
        format: types.BufferFormat,
    };

    pub const BufferCreateGpuWithFds = struct {
        buffer_id: types.BufferID,

        fds: types.BufferAndTimelineFds,

        width: u32,
        height: u32,
        format: types.BufferFormat,

        gbm_bo_modifier: u64,
    };

    pub const BufferPresent = struct {
        buffer_id: types.BufferID,
        viewport_id: types.ViewportID,
        viewport_size: types.Size,
    };

    pub const BufferPresentWithSync = struct {
        buffer_id: types.BufferID,
        viewport_id: types.ViewportID,
        acquire_point: types.AcquireTimelinePoint,
        release_point: types.ReleaseTimelinePoint,
        viewport_size: types.Size,
    };

    pub const BufferDestroy = struct {
        buffer_id: types.BufferID,
    };

    pub const CursorShape = struct {
        viewport_id: types.ViewportID,
        shape: types.CursorShape,
    };
};

pub fn message_send_json(io: Io, gpa: std.mem.Allocator, stream: net.Stream, payload: MessagePayload) !void {
    const json = switch (payload) {
        inline else => |original| blk: {
            var p = original;

            // The fd that's part of the json is wrong.
            // Set them to .invalid_fd to invalidate their use
            const T = @TypeOf(p);
            if (comptime common.contains_a_fd(T)) |name| {
                @field(p, name) = .invalid_fd;
            }

            break :blk try std.json.Stringify.valueAlloc(gpa, p, .{});
        },
    };
    defer gpa.free(json);

    const header: MessageHeader = .{
        .len = @intCast(@sizeOf(MessageHeader) + json.len),
        .format = .json,
        .message_tag = payload,
    };

    switch (payload) {
        .buffer_create_cpu_with_fd,
        => |p| {
            try message_send_json_with_fd(stream, .{ .header = header, .payload = json }, types.CpuBufferFd, p.fd);
        },
        .buffer_create_gpu_with_fds,
        => |p| {
            try message_send_json_with_fd(
                stream,
                .{ .header = header, .payload = json },
                @TypeOf(p.fds),
                p.fds,
            );
        },

        .register,
        .sub_viewport_embed,
        .sub_viewport_rect_set,
        .cursor_shape_set,
        .buffer_present,
        .buffer_present_with_sync,
        .buffer_destroy,
        .viewport_create,
        .generate_client_full_id,
        .sub_viewport_display_state_set,
        => {
            var buf: [4096]u8 = undefined;
            var writer = stream.writer(io, &buf);

            const header_bytes = std.mem.toBytes(header);
            try writer.interface.writeAll(&header_bytes);
            try writer.interface.writeAll(json);
            try writer.interface.flush();
        },
    }
}

pub fn message_peek(io: Io, stream: net.Stream, timeout: Io.Timeout) !?net.IncomingMessage {
    var buf: [@sizeOf(MessageHeader)]u8 = undefined;
    const peek = common.operation_net_receive_peek(MessageHeader, io, stream, timeout, &buf) catch |err|
        switch (err) {
            error.Timeout => return null,
            else => |e| return e,
        };

    if (peek.data.len == 0) {
        return error.ConnectionClosed;
    }

    return peek;
}

pub fn message_receive(io: Io, arena: std.mem.Allocator, stream: net.Stream, timeout: Io.Timeout) !?MessagePayload {
    const peek = try message_peek(io, stream, timeout) orelse return null;

    const header = try common.parse_message_header(MessageHeader, peek.data);

    const message_buf = try arena.alloc(u8, header.len);
    switch (header.format) {
        .json => {
            return switch (os_tag) {
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

fn message_send_json_with_fd(stream: net.Stream, message: Message, comptime Fd: type, fd: Fd) !void {
    const total_len = message.payload.len + @sizeOf(MessageHeader);
    std.debug.assert(message.header.len == total_len);

    const header = std.mem.toBytes(message.header);

    var buf: [4096]u8 = undefined;
    std.mem.copyForwards(u8, &buf, &header);
    std.mem.copyForwards(u8, buf[header.len..], message.payload);

    const len = @sizeOf(MessageHeader) + message.payload.len;
    const result = send_fd(stream.socket.handle, Fd, fd, buf[0..len]);
    if (result < 0) {
        return error.FailedToSendFds;
    }
}

fn read_and_parse_data_json_linux(
    io: Io,
    arena: std.mem.Allocator,
    stream: net.Stream,
    header: MessageHeader,
    receive_buf: []u8,
) !MessagePayload {
    std.debug.assert(header.format == .json);
    std.debug.assert(receive_buf.len == header.len);

    switch (header.message_tag) {
        inline .buffer_create_cpu_with_fd,
        .buffer_create_gpu_with_fds,
        => |tag| {
            const T = switch (tag) {
                .buffer_create_cpu_with_fd => MessagePayload.BufferCreateCpuWithFd,
                .buffer_create_gpu_with_fds => MessagePayload.BufferCreateGpuWithFds,
                else => comptime unreachable,
            };
            const parsed = try parse_message_with_fd(T, io, arena, stream, receive_buf);
            return @unionInit(MessagePayload, @tagName(tag), parsed);
        },

        .register,
        .sub_viewport_embed,
        .sub_viewport_rect_set,
        .cursor_shape_set,
        .buffer_present,
        .buffer_present_with_sync,
        .buffer_destroy,
        .viewport_create,
        .generate_client_full_id,
        .sub_viewport_display_state_set,
        => {
            return try read_and_parse_data_json(io, arena, stream, header, receive_buf);
        },
    }
}

fn read_and_parse_data_json(
    io: Io,
    arena: std.mem.Allocator,
    stream: net.Stream,
    header: MessageHeader,
    receive_buf: []u8,
) !MessagePayload {
    switch (header.message_tag) {
        .buffer_create_gpu_with_fds,
        .buffer_create_cpu_with_fd,
        => return error.UnsupportedMessageOnOs,

        inline .buffer_present,
        .buffer_present_with_sync,
        .buffer_destroy,
        .cursor_shape_set,
        .sub_viewport_embed,
        .sub_viewport_rect_set,
        .viewport_create,
        .register,
        .generate_client_full_id,
        .sub_viewport_display_state_set,
        => |tag| {
            const T = utils.TypeOfField(MessagePayload, @tagName(tag));
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

fn parse_message_with_fd(comptime T: type, io: Io, arena: std.mem.Allocator, stream: net.Stream, receive_buf: []u8) !T {
    const Fd = switch (T) {
        MessagePayload.BufferCreateGpuWithFds => types.BufferAndTimelineFds,
        MessagePayload.BufferCreateCpuWithFd => types.CpuBufferFd,
        else => unreachable,
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

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const c_linux = @import("c_linux");
const os_tag = @import("builtin").os.tag;
const types = @import("types.zig");
const common = @import("common.zig");
const utils = @import("utils");
