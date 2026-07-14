pub const MessageHeader = types.MessageHeaderGeneric(MessageTag);

pub const Message = struct {
    header: MessageHeader,
    payload: []const u8,

    pub fn init(payload: []const u8, format: types.MessageFormat, tag: MessageTag) Message {
        return .{
            .header = .{
                .len = @intCast(payload.len + @sizeOf(MessageHeader)),
                .format = format,
                .message_tag = tag,
            },
            .payload = payload,
        };
    }
};

pub const MessageTag = std.meta.Tag(MessagePayload);
pub const MessagePayload = union(enum(u32)) {
    viewport_create_with_fds_cpu: ViewportCreateWithFdsCpu,
    viewport_create_with_fds_gpu: ViewportCreateWithFdsGpu,

    viewport_buffers_swap: types.ViewportBuffersSwap,

    window_create: types.WindowCreate,

    pub const ViewportCreateWithFdsCpu = struct {
        id: types.ViewportID,
        size: types.ViewportSize,
        fds: types.ViewportFds,
    };

    pub const ViewportCreateWithFdsGpu = struct {
        id: types.ViewportID,
        fds: types.ViewportFds,

        width: u32,
        height: u32,
        format: types.ViewportFormat,
        gbm_bo_modifier: u64,
    };
};

pub fn message_send_json(io: Io, gpa: std.mem.Allocator, stream: net.Stream, payload: MessagePayload) !void {
    const json = switch (payload) {
        inline .viewport_create_with_fds_gpu,
        .viewport_create_with_fds_cpu,
        => |original| blk: {
            var p = original;
            // The fds that are part of the json are wrong.
            // Set them to 0 to invalidate their use
            p.fds.back = 0;
            p.fds.front = 0;
            break :blk try std.json.Stringify.valueAlloc(gpa, p, .{});
        },

        inline .viewport_buffers_swap,
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
        inline .viewport_create_with_fds_gpu,
        .viewport_create_with_fds_cpu,
        => |p| {
            try message_send_json_with_fds(stream, .{ .header = header, .payload = json }, p.fds);
        },
        .viewport_buffers_swap,
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
        inline .viewport_create_with_fds_cpu,
        .viewport_create_with_fds_gpu,
        => |tag| {
            const T = switch (tag) {
                .viewport_create_with_fds_cpu => MessagePayload.ViewportCreateWithFdsCpu,
                .viewport_create_with_fds_gpu => MessagePayload.ViewportCreateWithFdsGpu,
                else => comptime unreachable,
            };
            const parsed = try parse_message_with_fds(T, io, arena, stream, receive_buf);
            return @unionInit(MessagePayload, @tagName(tag), parsed);
        },

        .viewport_buffers_swap,
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
        .viewport_create_with_fds_gpu,
        .viewport_create_with_fds_cpu,
        => return error.UnsupportedMessageOnOs,

        inline .viewport_buffers_swap,
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
