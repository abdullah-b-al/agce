pub const MessageHeader = types.MessageHeaderGeneric(MessageTag);

pub const Message = struct {
    header: MessageHeader,
    payload: []const u8,
};

pub const MessageTag = std.meta.Tag(MessagePayload);
pub const MessagePayload = union(enum(u32)) {
    buffer_create_cpu_with_fd: BufferCreateCpuWithFd,
    buffer_create_gpu_with_fd: BufferCreateGpuWithFd,
    buffer_present: BufferPresent,
    buffer_destroy: BufferDestroy,

    window_create: types.WindowCreate,

    pub const BufferCreateCpuWithFd = struct {
        id: types.BufferID,

        fd: c_int,

        width: u32,
        height: u32,
        format: types.BufferFormat,
    };

    pub const BufferCreateGpuWithFd = struct {
        id: types.BufferID,

        fd: c_int,

        width: u32,
        height: u32,
        format: types.BufferFormat,

        gbm_bo_modifier: u64,
    };

    pub const BufferPresent = struct {
        buffer_id: types.BufferID,
        viewport_id: types.ViewportID,
    };
    pub const BufferDestroy = struct {
        buffer_id: types.BufferID,
    };
};

pub fn message_send_json(io: Io, gpa: std.mem.Allocator, stream: net.Stream, payload: MessagePayload) !void {
    const json = switch (payload) {
        inline .buffer_create_gpu_with_fd,
        .buffer_create_cpu_with_fd,
        => |original| blk: {
            // The fd that's part of the json is wrong.
            // Set them to 0 to invalidate their use
            var p = original;
            p.fd = 0;
            break :blk try std.json.Stringify.valueAlloc(gpa, p, .{});
        },

        inline .buffer_present,
        .buffer_destroy,
        .window_create,
        => |p| try std.json.Stringify.valueAlloc(gpa, p, .{}),
    };
    defer gpa.free(json);

    const header: MessageHeader = .{
        .len = @intCast(@sizeOf(MessageHeader) + json.len),
        .format = .json,
        .message_tag = payload,
    };

    switch (payload) {
        inline .buffer_create_gpu_with_fd,
        .buffer_create_cpu_with_fd,
        => |p| {
            try message_send_json_with_fd(stream, .{ .header = header, .payload = json }, p.fd);
        },
        .buffer_present,
        .buffer_destroy,
        .window_create,
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

pub fn message_receive(io: Io, arena: std.mem.Allocator, client: *Client, timeout: Io.Timeout) !?MessagePayload {
    var buf: [@sizeOf(MessageHeader)]u8 = undefined;
    const peek = common.operation_net_receive_peek(MessageHeader, io, client.stream, timeout, &buf) catch |err|
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
            return switch (os_tag) {
                .linux => {
                    const message = try read_and_parse_data_json_linux(io, arena, client, header, message_buf);
                    return message;
                },
                else => {
                    const message = try read_and_parse_data_json(io, arena, client, header, message_buf);
                    return message;
                },
            };
        },
    }
}

fn message_send_json_with_fds(stream: net.Stream, message: Message, fds: types.ViewportFds) !void {
    const total_len = message.payload.len + @sizeOf(MessageHeader);
    std.debug.assert(message.header.len == total_len);

    const header = std.mem.toBytes(message.header);

    var buf: [4096]u8 = undefined;
    std.mem.copyForwards(u8, &buf, &header);
    std.mem.copyForwards(u8, buf[header.len..], message.payload);

    const len = @sizeOf(MessageHeader) + message.payload.len;
    const result = send_fds(stream.socket.handle, fds, buf[0..len]);
    if (result < 0) {
        return error.FailedToSendFds;
    }
}

fn message_send_json_with_fd(stream: net.Stream, message: Message, fd: c_int) !void {
    const total_len = message.payload.len + @sizeOf(MessageHeader);
    std.debug.assert(message.header.len == total_len);

    const header = std.mem.toBytes(message.header);

    var buf: [4096]u8 = undefined;
    std.mem.copyForwards(u8, &buf, &header);
    std.mem.copyForwards(u8, buf[header.len..], message.payload);

    const len = @sizeOf(MessageHeader) + message.payload.len;
    const result = send_fd(stream.socket.handle, fd, buf[0..len]);
    if (result < 0) {
        return error.FailedToSendFds;
    }
}

fn read_and_parse_data_json_linux(
    io: Io,
    arena: std.mem.Allocator,
    client: *Client,
    header: MessageHeader,
    receive_buf: []u8,
) !MessagePayload {
    std.debug.assert(header.format == .json);
    std.debug.assert(receive_buf.len == header.len);
    const stream = client.stream;

    switch (header.message_tag) {
        inline .buffer_create_cpu_with_fd,
        .buffer_create_gpu_with_fd,
        => |tag| {
            const T = switch (tag) {
                .buffer_create_cpu_with_fd => MessagePayload.BufferCreateCpuWithFd,
                .buffer_create_gpu_with_fd => MessagePayload.BufferCreateGpuWithFd,
                else => comptime unreachable,
            };
            const parsed = try parse_message_with_fd(T, io, arena, stream, receive_buf);
            return @unionInit(MessagePayload, @tagName(tag), parsed);
        },

        .buffer_present,
        .buffer_destroy,
        .window_create,
        => {
            return try read_and_parse_data_json(io, arena, client, header, receive_buf);
        },
    }
}

fn read_and_parse_data_json(
    io: Io,
    arena: std.mem.Allocator,
    client: *Client,
    header: MessageHeader,
    receive_buf: []u8,
) !MessagePayload {
    switch (header.message_tag) {
        .buffer_create_gpu_with_fd,
        .buffer_create_cpu_with_fd,
        => return error.UnsupportedMessageOnOs,

        inline .buffer_present,
        .buffer_destroy,
        .window_create,
        => |tag| {
            const T = common.TypeOfUnionField(MessagePayload, @tagName(tag));
            const parsed = try common.read_and_parse_data_json(
                MessageHeader,
                T,
                io,
                arena,
                client.stream,
                header,
                receive_buf,
            );

            return @unionInit(MessagePayload, @tagName(tag), parsed);
        },
    }
}

fn send_fds(socket: c_int, fds: types.ViewportFds, data_to_send: []const u8) isize {
    var msg = std.mem.zeroes(c_linux.msghdr);

    var iov: c_linux.iovec = .{ .iov_base = @constCast(data_to_send.ptr), .iov_len = data_to_send.len };
    msg.msg_iov = @ptrCast(&iov);
    msg.msg_iovlen = 1;

    var buf: [c_linux.CMSG_SPACE(@sizeOf(types.ViewportFds))]u8 = undefined;
    msg.msg_control = &buf;
    msg.msg_controllen = buf.len;

    const hdr = &c_linux.CMSG_FIRSTHDR(&msg)[0];
    hdr.cmsg_len = c_linux.CMSG_LEN(@sizeOf(types.ViewportFds));
    hdr.cmsg_level = c_linux.SOL_SOCKET;
    hdr.cmsg_type = c_linux.SCM_RIGHTS;

    const ptr: [*]u8 = hdr.__cmsg_data();
    const data: *types.ViewportFds = @ptrCast(@alignCast(ptr));
    data.* = fds;

    return c_linux.sendmsg(socket, &msg, 0);
}

fn send_fd(socket: c_int, fd: c_int, data_to_send: []const u8) isize {
    var msg = std.mem.zeroes(c_linux.msghdr);

    var iov: c_linux.iovec = .{ .iov_base = @constCast(data_to_send.ptr), .iov_len = data_to_send.len };
    msg.msg_iov = @ptrCast(&iov);
    msg.msg_iovlen = 1;

    const Fd = c_int;
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

fn recv_fds_peek(socket: c_int) !types.ViewportFds {
    var msg = std.mem.zeroes(c_linux.msghdr);

    var iov_base = "";
    var iov: c_linux.iovec = .{ .iov_base = @ptrCast(&iov_base), .iov_len = iov_base.len };
    msg.msg_iov = @ptrCast(&iov);
    msg.msg_iovlen = 1;

    var buf: [c_linux.CMSG_SPACE(@sizeOf(types.ViewportFds))]u8 = undefined;
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
    const data: *types.ViewportFds = @ptrCast(@alignCast(ptr));
    return data.*;
}

fn recv_fd_peek(socket: c_int) !c_int {
    var msg = std.mem.zeroes(c_linux.msghdr);

    var iov_base = "";
    var iov: c_linux.iovec = .{ .iov_base = @ptrCast(&iov_base), .iov_len = iov_base.len };
    msg.msg_iov = @ptrCast(&iov);
    msg.msg_iovlen = 1;

    const Fd = c_int;
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

fn parse_message_with_fds(comptime T: type, io: Io, arena: std.mem.Allocator, stream: net.Stream, receive_buf: []u8) !T {
    const fds = try recv_fds_peek(stream.socket.handle);

    const msg = try stream.socket.receive(io, receive_buf);
    const data = msg.data[@sizeOf(MessageHeader)..];

    var parsed = try std.json.parseFromSliceLeaky(T, arena, data, .{
        .allocate = .alloc_if_needed,
    });

    parsed.fds = fds;
    return parsed;
}

fn parse_message_with_fd(comptime T: type, io: Io, arena: std.mem.Allocator, stream: net.Stream, receive_buf: []u8) !T {
    const fd = try recv_fd_peek(stream.socket.handle);

    const msg = try stream.socket.receive(io, receive_buf);
    const data = msg.data[@sizeOf(MessageHeader)..];

    var parsed = try std.json.parseFromSliceLeaky(T, arena, data, .{
        .allocate = .alloc_if_needed,
    });

    parsed.fd = fd;
    return parsed;
}

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const constants = @import("../constants.zig");
const c_linux = @import("c_linux");
const os_tag = @import("builtin").os.tag;
const types = @import("types.zig");
const common = @import("common.zig");
const ClientID = @import("../server/Clients.zig").ClientID;
const Client = @import("../server/Client.zig");
