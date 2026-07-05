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

pub const MessageTag = enum(u32) {
    viewport_create_with_fds,
    viewport_buffers_swap,
    viewport_resize,

    window_create,
};

pub const MessageFromClient = union(MessageTag) {
    viewport_create_with_fds: ViewportCreateWithSharedFd,
    viewport_buffers_swap: types.ViewportBuffersSwap,
    viewport_resize: struct {
        resize: types.ViewportResize,
    },

    window_create: types.WindowCreate,

    pub const ViewportCreateWithSharedFd = struct {
        id: types.ViewportID,
        size: types.ViewportSize,
        fds: types.ViewportFds,
    };
};

pub const MessageToServer = union(MessageTag) {
    viewport_create_with_fds: ViewportCreateWithSharedFd,
    viewport_buffers_swap: types.ViewportBuffersSwap,
    viewport_resize: types.ViewportResize,

    window_create: types.WindowCreate,

    pub const ViewportCreateWithSharedFd = struct {
        id: types.ViewportID,
        size: types.ViewportSize,
    };
};

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

pub fn message_send_with_fds_json(stream: net.Stream, message: Message, fds: types.ViewportFds) !void {
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
    id: types.ViewportID,
    size: types.ViewportSize,
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

pub fn read_and_parse_data_json_linux(
    io: Io,
    arena: std.mem.Allocator,
    client: *Client,
    header: MessageHeader,
    receive_buf: []u8,
) !MessageFromClient {
    std.debug.assert(header.format == .json);
    std.debug.assert(receive_buf.len == header.len);
    const stream = client.stream;

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
            return try read_and_parse_data_json(io, arena, client, header, receive_buf);
        },
    }
}

pub fn read_and_parse_data_json(
    io: Io,
    arena: std.mem.Allocator,
    client: *Client,
    header: MessageHeader,
    receive_buf: []u8,
) !MessageFromClient {
    switch (header.message_tag) {
        .viewport_create_with_fds => return error.UnsupportedMessageOnOs,
        .viewport_resize => {
            const msg = try common.read_and_parse_data_json(
                MessageHeader,
                MessageToServer,
                io,
                arena,
                client.stream,
                header,
                receive_buf,
            );

            return .{
                .viewport_resize = .{
                    .resize = msg.viewport_resize,
                },
            };
        },
        else => {
            return try common.read_and_parse_data_json(
                MessageHeader,
                MessageFromClient,
                io,
                arena,
                client.stream,
                header,
                receive_buf,
            );
        },
    }
}

pub fn send_fds(socket: c_int, fds: types.ViewportFds, data_to_send: []const u8) isize {
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

pub fn recv_fds_peek(socket: c_int) !types.ViewportFds {
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

pub fn message_receive(io: Io, arena: std.mem.Allocator, client: *Client, timeout: Io.Timeout) !?MessageFromClient {
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
