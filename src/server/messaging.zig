pub fn message_send_json(io: Io, gpa: std.mem.Allocator, stream: net.Stream, message: MessageToServer) !void {
    switch (message) {
        .viewport_create_with_fds,
        => @panic("Call message_send_viewport_create_with_shared_fds instead"),
        else => {},
    }
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

pub fn message_send_with_fds_json(stream: net.Stream, message: Message, fds: protocol.ViewportFds) !void {
    const total_len = message.data.len + @sizeOf(MessageHeader);
    std.debug.assert(message.header.len == total_len);

    const header = std.mem.toBytes(message.header);

    var buf: [4096]u8 = undefined;
    std.mem.copyForwards(u8, &buf, &header);
    std.mem.copyForwards(u8, buf[header.len..], message.data);

    const len = @sizeOf(MessageHeader) + message.data.len;
    const result = send_fds(stream.socket.handle, fds, buf[0..len]);
    if (result < 0) {
        return error.FailedToSendFds;
    }
}

pub fn message_send_viewport_create_with_fds(
    gpa: std.mem.Allocator,
    stream: net.Stream,
    id: protocol.ViewportID,
    size: protocol.ViewportSize,
    front_fd: c_int,
    back_fd: c_int,
) !void {
    std.debug.assert(front_fd != back_fd);

    const msg: MessageToServer = .{
        .viewport_create_with_fds = .{
            .id = id,
            .size = size,
        },
    };
    const data = try std.json.Stringify.valueAlloc(gpa, msg, .{});
    defer gpa.free(data);

    const message: Message = .init(data, .json, .viewport_create_with_fds);
    try message_send_with_fds_json(stream, message, .{
        .front = front_fd,
        .back = back_fd,
    });
}

pub fn parse_message_header(data: []const u8) !MessageHeader {
    std.debug.assert(data.len > 0);

    const len = @sizeOf(MessageHeader);
    if (len > data.len) {
        return error.InvalidLen;
    }
    const data_header = data[0..len];
    const header: MessageHeader = try .parse(data_header);
    return header;
}

pub fn read_and_parse_data_json_linux(io: Io, arena: std.mem.Allocator, stream: net.Stream, header: MessageHeader, receive_buf: []u8) !MessageFromClient {
    std.debug.assert(header.format == .json);
    std.debug.assert(receive_buf.len == header.len);

    switch (header.message_tag) {
        .viewport_create_with_fds => {
            const result = try recv_fds_peek(stream.socket.handle);

            const msg = try stream.socket.receive(io, receive_buf);
            const data = msg.data[@sizeOf(MessageHeader)..];

            const parsed = try std.json.parseFromSliceLeaky(MessageToServer, arena, data, .{
                .allocate = .alloc_if_needed,
            });

            if (parsed != .viewport_create_with_fds) {
                return error.MessageTagFromHeaderDoesNotMatchData;
            }
            const value = parsed.viewport_create_with_fds;

            return .{
                .viewport_create_with_fds = .{
                    .fds = result,
                    .id = value.id,
                    .size = value.size,
                },
            };
        },
        else => {
            return try read_and_parse_data_json(io, arena, stream, header, receive_buf);
        },
    }
}

pub fn read_and_parse_data_json(io: Io, arena: std.mem.Allocator, stream: net.Stream, header: MessageHeader, receive_buf: []u8) !MessageFromClient {
    std.debug.assert(header.format == .json);
    std.debug.assert(receive_buf.len == header.len);

    switch (header.message_tag) {
        .viewport_create_with_fds => return error.UnsupportedMessageOnOs,
        else => {},
    }

    const msg = try stream.socket.receive(io, receive_buf);
    const data = msg.data[@sizeOf(MessageHeader)..];
    const parsed = try std.json.parseFromSliceLeaky(MessageFromClient, arena, data, .{
        .allocate = .alloc_if_needed,
    });
    if (parsed != header.message_tag) {
        return error.MessageTagFromHeaderDoesNotMatchData;
    }
    return parsed;
}

pub fn send_fds(socket: c_int, fds: protocol.ViewportFds, data_to_send: []const u8) isize {
    var msg = std.mem.zeroes(c_linux.msghdr);

    var iov: c_linux.iovec = .{ .iov_base = @constCast(data_to_send.ptr), .iov_len = data_to_send.len };
    msg.msg_iov = @ptrCast(&iov);
    msg.msg_iovlen = 1;

    var buf: [c_linux.CMSG_SPACE(@sizeOf(protocol.ViewportFds))]u8 = undefined;
    msg.msg_control = &buf;
    msg.msg_controllen = buf.len;

    const hdr = &c_linux.CMSG_FIRSTHDR(&msg)[0];
    hdr.cmsg_len = c_linux.CMSG_LEN(@sizeOf(protocol.ViewportFds));
    hdr.cmsg_level = c_linux.SOL_SOCKET;
    hdr.cmsg_type = c_linux.SCM_RIGHTS;

    const ptr: [*]u8 = hdr.__cmsg_data();
    const data: *protocol.ViewportFds = @ptrCast(@alignCast(ptr));
    data.* = fds;

    return c_linux.sendmsg(socket, &msg, 0);
}

pub fn recv_fds_peek(socket: c_int) !protocol.ViewportFds {
    var msg = std.mem.zeroes(c_linux.msghdr);

    var iov_base = "";
    var iov: c_linux.iovec = .{ .iov_base = @ptrCast(&iov_base), .iov_len = iov_base.len };
    msg.msg_iov = @ptrCast(&iov);
    msg.msg_iovlen = 1;

    var buf: [c_linux.CMSG_SPACE(@sizeOf(protocol.ViewportFds))]u8 = undefined;
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
    const data: *protocol.ViewportFds = @ptrCast(@alignCast(ptr));
    return data.*;
}

pub fn operation_net_receive_peek(io: Io, stream: net.Stream, timeout: Io.Timeout, buf: []u8) !net.IncomingMessage {
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

pub fn message_receive(io: Io, arena: std.mem.Allocator, stream: net.Stream, timeout: Io.Timeout) !?MessageFromClient {
    var buf: [@sizeOf(MessageHeader)]u8 = undefined;
    const peek = operation_net_receive_peek(io, stream, timeout, &buf) catch |err|
        switch (err) {
            error.Timeout => return null,
            else => |e| return e,
        };

    if (peek.data.len == 0) {
        return error.ConnectionClosed;
    }

    const header = try parse_message_header(peek.data);

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

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const constants = @import("../constants.zig");
const c_linux = @import("c_linux");
const protocol = @import("protocol.zig");
const os_tag = @import("builtin").os.tag;
const Message = protocol.Message;
const MessageTag = protocol.MessageTag;
const MessageHeader = protocol.MessageHeader;
const MessageFromClient = protocol.MessageFromClient;
const MessageToServer = protocol.MessageToServer;
