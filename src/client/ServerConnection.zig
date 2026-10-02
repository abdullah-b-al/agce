const ServerConnection = @This();

format: ptypes.MessageFormat,
stream: net.Stream,

pub fn receive_with_reader(_: Io, arena: std.mem.Allocator, reader: *Io.Reader) !server_to_client.MessagePayload {
    const header_bytes = try reader.take(@sizeOf(client_to_server.MessageHeader));

    const header = try server_to_client.parse_message_header(header_bytes);
    const err_data = if (header.payload_len > reader.buffer.len)
        reader.readAlloc(arena, header.payload_len)
    else
        reader.take(header.payload_len);

    const data = err_data catch |err| return switch (err) {
        error.EndOfStream => error.HeaderWithoutPayload,
        error.ReadFailed, error.OutOfMemory => |e| e,
    };

    switch (header.message_tag) {
        inline else => |tag| {
            switch (header.format) {
                .json => {
                    const T = utils.TypeOfField(server_to_client.MessagePayload, @tagName(tag));
                    const parsed = try std.json.parseFromSliceLeaky(T, arena, data, .{
                        .allocate = .alloc_if_needed,
                    });

                    return @unionInit(server_to_client.MessagePayload, @tagName(tag), parsed);
                },
            }
        },
    }
}

pub fn send_register(c: *ServerConnection, io: Io, gpa: std.mem.Allocator, payload: client_to_server.Register) !void {
    const message = try c.stringify(gpa, .{ .register = payload });
    try c.send(io, gpa, message);
}

pub fn send_generate_client_full_id(c: *ServerConnection, io: Io, gpa: std.mem.Allocator, payload: client_to_server.Void) !void {
    const message = try c.stringify(gpa, .{ .generate_client_full_id = payload });
    try c.send(io, gpa, message);
}

pub fn send_buffer_create_cpu(c: *ServerConnection, io: Io, gpa: std.mem.Allocator, payload: client_to_server.BufferCreateCpu) !void {
    const message = try c.stringify(gpa, .{ .buffer_create_cpu = payload });
    try c.send(io, gpa, message);
}

pub fn send_buffer_create_gbm_bo(c: *ServerConnection, io: Io, gpa: std.mem.Allocator, payload: client_to_server.BufferCreateGbmBo) !void {
    if (!constants.os_has_gbm) @compileError("OS does not support gbm");
    const message = try c.stringify(gpa, .{ .buffer_create_gbm_bo = payload });
    try c.send(io, gpa, message);
}

pub fn send_buffer_destroy(c: *ServerConnection, io: Io, gpa: std.mem.Allocator, payload: client_to_server.BufferDestroy) !void {
    const message = try c.stringify(gpa, .{ .buffer_destroy = payload });
    try c.send(io, gpa, message);
}

pub fn send_buffer_present(c: *ServerConnection, io: Io, gpa: std.mem.Allocator, payload: client_to_server.BufferPresent) !void {
    const message = try c.stringify(gpa, .{ .buffer_present = payload });
    try c.send(io, gpa, message);
}

pub fn send_buffer_present_with_sync(c: *ServerConnection, io: Io, gpa: std.mem.Allocator, payload: client_to_server.BufferPresentWithSync) !void {
    const message = try c.stringify(gpa, .{ .buffer_present_with_sync = payload });
    try c.send(io, gpa, message);
}

pub fn send_viewport_create(c: *ServerConnection, io: Io, gpa: std.mem.Allocator, payload: client_to_server.ViewportCreate) !void {
    const message = try c.stringify(gpa, .{ .viewport_create = payload });
    try c.send(io, gpa, message);
}

pub fn send_viewport_destroy(c: *ServerConnection, io: Io, gpa: std.mem.Allocator, payload: client_to_server.ViewportDestroy) !void {
    const message = try c.stringify(gpa, .{ .viewport_destroy = payload });
    try c.send(io, gpa, message);
}

pub fn send_sub_viewport_embed(c: *ServerConnection, io: Io, gpa: std.mem.Allocator, payload: client_to_server.SubViewportEmbed) !void {
    const message = try c.stringify(gpa, .{ .sub_viewport_embed = payload });
    try c.send(io, gpa, message);
}

pub fn send_sub_viewport_pos_set(c: *ServerConnection, io: Io, gpa: std.mem.Allocator, payload: client_to_server.SubViewportPosSet) !void {
    const message = try c.stringify(gpa, .{ .sub_viewport_pos_set = payload });
    try c.send(io, gpa, message);
}

pub fn send_sub_viewport_size_set(c: *ServerConnection, io: Io, gpa: std.mem.Allocator, payload: client_to_server.SubViewportSizeSet) !void {
    const message = try c.stringify(gpa, .{ .sub_viewport_size_set = payload });
    try c.send(io, gpa, message);
}

pub fn send_sub_viewport_display_state_set(c: *ServerConnection, io: Io, gpa: std.mem.Allocator, payload: client_to_server.SubViewportDisplayStateSet) !void {
    const message = try c.stringify(gpa, .{ .sub_viewport_display_state_set = payload });
    try c.send(io, gpa, message);
}

pub fn send_cursor_shape_set(c: *ServerConnection, io: Io, gpa: std.mem.Allocator, payload: client_to_server.CursorShape) !void {
    const message = try c.stringify(gpa, .{ .cursor_shape_set = payload });
    try c.send(io, gpa, message);
}

fn stringify(c: *ServerConnection, gpa: std.mem.Allocator, payload: client_to_server.MessagePayload) !client_to_server.Message {
    std.debug.assert(c.format == .json);

    const json = switch (payload) {
        inline else => |p| try std.json.Stringify.valueAlloc(gpa, p, .{}),
    };

    const header: client_to_server.MessageHeader = .{
        .payload_len = @intCast(json.len),
        .format = .json,
        .message_tag = payload,
    };

    return .{ .header = header, .payload = json };
}

fn send(c: *ServerConnection, io: Io, gpa: std.mem.Allocator, message: client_to_server.Message) !void {
    defer gpa.free(message.payload);

    var buf: [4096]u8 = undefined;
    var writer = c.stream.writer(io, &buf);

    const header_bytes = std.mem.toBytes(message.header);
    try writer.interface.writeAll(&header_bytes);
    try writer.interface.writeAll(message.payload);
    try writer.interface.flush();
}

pub fn receive_linux(io: Io, arena: std.mem.Allocator, stream: net.Stream) !server_to_client.MessagePayload {
    if (os != .linux) @compileError("Linux only function");
    var buf: [@sizeOf(server_to_client.MessageHeader)]u8 = undefined;
    const peek = try server_to_client.operation_net_receive_peek(io, stream, .none, &buf);

    if (peek.data.len == 0) {
        return error.ConnectionClosed;
    }

    const header = try server_to_client.parse_message_header(peek.data);

    const message_buf = try arena.alloc(u8, header.payload_len + @sizeOf(server_to_client.MessageHeader));
    const message = try server_to_client.read_and_parse_data_json_linux(io, arena, stream, header, message_buf);
    return message;
}

pub fn receive_windows(
    io: Io,
    arena: std.mem.Allocator,
    stream: net.Stream,
) !server_to_client.MessagePayload {
    var buf: [4096]u8 = undefined;
    var reader = stream.reader(io, &buf);

    const header_bytes = reader.interface.take(@sizeOf(server_to_client.MessageHeader)) catch |err|
        return switch (err) {
            error.EndOfStream => error.ConnectionClosed,
            error.ReadFailed => switch (reader.err.?) {
                error.Timeout => unreachable,

                error.Canceled,
                error.SystemResources,
                error.ConnectionResetByPeer,
                error.SocketUnconnected,
                error.AccessDenied,
                error.Unexpected,
                error.NetworkDown,
                => |e| e,
            },
        };

    const header = try server_to_client.parse_message_header(header_bytes);
    const err_data = if (header.payload_len > buf.len)
        reader.interface.readAlloc(arena, header.payload_len)
    else
        reader.interface.take(header.payload_len);

    const data = err_data catch |err| return switch (err) {
        error.EndOfStream => error.HeaderWithoutPayload,
        error.OutOfMemory => |e| e,
        error.ReadFailed => switch (reader.err.?) {
            error.Timeout => unreachable,

            error.Canceled,
            error.SystemResources,
            error.ConnectionResetByPeer,
            error.SocketUnconnected,
            error.AccessDenied,
            error.Unexpected,
            error.NetworkDown,
            => |e| e,
        },
    };

    switch (header.message_tag) {
        inline else => |tag| {
            switch (header.format) {
                .json => {
                    const T = utils.TypeOfField(server_to_client.MessagePayload, @tagName(tag));
                    const parsed = try std.json.parseFromSliceLeaky(T, arena, data, .{
                        .allocate = .alloc_if_needed,
                    });

                    return @unionInit(server_to_client.MessagePayload, @tagName(tag), parsed);
                },
            }
        },
    }
}

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const ptypes = @import("protocol").types;
const client_to_server = @import("protocol").client_to_server;
const server_to_client = @import("protocol").server_to_client;
const constants = @import("constants");
const os = @import("builtin").os.tag;
const utils = @import("utils");
const win32 = @import("win32");
const win32_threading = win32.system.threading;
const win_sock = win32.networking.win_sock;
const Client = @import("Client.zig");
