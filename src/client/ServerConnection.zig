const ServerConnection = @This();

format: ptypes.MessageFormat,
stream: net.Stream,

pub fn receive_with_reader(_: Io, arena: std.mem.Allocator, reader: *net.Stream.Reader) !server_to_client.MessagePayload {
    const header_bytes = try reader.interface.take(@sizeOf(client_to_server.MessageHeader));

    const header = try server_to_client.parse_message_header(header_bytes);
    const err_data = if (header.payload_len > reader.interface.buffer.len)
        reader.interface.readAlloc(arena, header.payload_len)
    else
        reader.interface.take(header.payload_len);

    const data = err_data catch |err| return switch (err) {
        error.EndOfStream => error.HeaderWithoutPayload,
        error.ReadFailed, error.OutOfMemory => |e| e,
    };

    switch (header.message_tag) {
        inline else => |tag| {
            switch (header.format) {
                .json => {
                    @setEvalBranchQuota(2000);
                    const T = @FieldType(server_to_client.MessagePayload, @tagName(tag));
                    var parsed = std.json.parseFromSliceLeaky(T, arena, data, .{
                        .allocate = .alloc_if_needed,
                    }) catch |err| {
                        log.err("ParseFailed: {}", .{err});
                        return error.ParseFailed;
                    };

                    if (constants.os_supports_fd) {
                        set_correct_fds(tag, &parsed, reader);
                    }

                    return @unionInit(server_to_client.MessagePayload, @tagName(tag), parsed);
                },
            }
        },
    }
}

fn set_correct_fds(comptime tag: server_to_client.MessageTag, parsed: anytype, reader: *net.Stream.Reader) void {
    comptime std.debug.assert(constants.os_supports_fd);

    switch (tag) {
        .buffer_created_cpu => {
            switch (parsed.*) {
                .success => |*s| {
                    var iter = reader.controlIterator();
                    const data = iter.next().?.data;
                    std.debug.assert(@sizeOf(ptypes.CpuBufferHandle) == data.len);
                    const ptr: *ptypes.CpuBufferHandle = @ptrCast(@alignCast(data.ptr));
                    s.handle = ptr.*;
                    reader.clearControl();
                },

                .failure => {},
            }
        },
        .buffer_created_gbm_bo => {
            switch (parsed.*) {
                .success => |*s| {
                    var iter = reader.controlIterator();
                    const data = iter.next().?.data;
                    std.debug.assert(@sizeOf(ptypes.BufferAndTimelineFds) == data.len);
                    const ptr: *ptypes.BufferAndTimelineFds = @ptrCast(@alignCast(data.ptr));
                    s.fds = ptr.*;
                    reader.clearControl();
                },
                .failure => {},
            }
        },

        // zig fmt: off
        .registered, .viewport_create, .viewport_created, .viewport_resize, .viewport_close,
        .viewport_display_state, .remote_viewport_created, .remote_viewport_display_state,
        .remote_viewport_render_size, .remote_viewport_closed, .client_registered,
        .client_disconnected, .buffer_released, .texture_created_d3d, .frame_render,
        .keyboard_enter, .keyboard_leave, .keyboard_char, .keyboard_key,
        .mouse_enter, .mouse_leave, .mouse_motion, .mouse_button, .mouse_scroll,
        // zig fmt: on
        => {},
    }
}

pub fn send_register(
    c: *ServerConnection,
    io: Io,
    uuid: ptypes.ClientUUID,
    pid: ?ptypes.PID,
) !void {
    var buf: [constants.payload_max_size]u8 = undefined;
    const message = c.stringify(&buf, .{
        .register = .{
            .uuid = uuid,
            .pid = pid,
            .is_local = false,
        },
    });

    try c.send(io, message);
}

pub fn send_buffer_create_cpu(c: *ServerConnection, io: Io, payload: client_to_server.BufferCreateCpu) !void {
    var buf: [constants.payload_max_size]u8 = undefined;
    const message = c.stringify(&buf, .{ .buffer_create_cpu = payload });
    try c.send(io, message);
}

pub fn send_buffer_create_gbm_bo(c: *ServerConnection, io: Io, payload: client_to_server.BufferCreateGbmBo) !void {
    if (!constants.os_has_gbm) @compileError("OS does not support gbm");
    var buf: [constants.payload_max_size]u8 = undefined;
    const message = c.stringify(&buf, .{ .buffer_create_gbm_bo = payload });
    try c.send(io, message);
}

pub fn send_texture_create_d3d(c: *ServerConnection, io: Io, payload: client_to_server.TextureCreateD3D) !void {
    if (!constants.os_has_d3d) @compileError("OS does not support d3d");
    var buf: [constants.payload_max_size]u8 = undefined;
    const message = c.stringify(&buf, .{ .texture_create_d3d = payload });
    try c.send(io, message);
}

pub fn send_buffer_destroy(c: *ServerConnection, io: Io, payload: client_to_server.BufferDestroy) !void {
    var buf: [constants.payload_max_size]u8 = undefined;
    const message = c.stringify(&buf, .{ .buffer_destroy = payload });
    try c.send(io, message);
}

pub fn send_buffer_present(c: *ServerConnection, io: Io, payload: client_to_server.BufferPresent) !void {
    var buf: [constants.payload_max_size]u8 = undefined;
    const message = c.stringify(&buf, .{ .buffer_present = payload });
    try c.send(io, message);
}

pub fn send_buffer_present_with_sync(c: *ServerConnection, io: Io, payload: client_to_server.BufferPresentWithSync) !void {
    var buf: [constants.payload_max_size]u8 = undefined;
    const message = c.stringify(&buf, .{ .buffer_present_with_sync = payload });
    try c.send(io, message);
}

pub fn send_viewport_create(c: *ServerConnection, io: Io, payload: client_to_server.ViewportCreate) !void {
    var buf: [constants.payload_max_size]u8 = undefined;
    const message = c.stringify(&buf, .{ .viewport_create = payload });
    try c.send(io, message);
}

pub fn send_viewport_destroy(c: *ServerConnection, io: Io, payload: client_to_server.ViewportDestroy) !void {
    var buf: [constants.payload_max_size]u8 = undefined;
    const message = c.stringify(&buf, .{ .viewport_destroy = payload });
    try c.send(io, message);
}

pub fn send_remote_viewport_create(c: *ServerConnection, io: Io, payload: client_to_server.RemoteViewportCreate) !void {
    var buf: [constants.payload_max_size]u8 = undefined;
    const message = c.stringify(&buf, .{ .remote_viewport_create = payload });
    try c.send(io, message);
}

pub fn send_viewport_pos_set(c: *ServerConnection, io: Io, payload: client_to_server.ViewportPosSet) !void {
    var buf: [constants.payload_max_size]u8 = undefined;
    const message = c.stringify(&buf, .{ .viewport_pos_set = payload });
    try c.send(io, message);
}

pub fn send_viewport_size_set(c: *ServerConnection, io: Io, payload: client_to_server.ViewportSizeSet) !void {
    var buf: [constants.payload_max_size]u8 = undefined;
    const message = c.stringify(&buf, .{ .viewport_size_set = payload });
    try c.send(io, message);
}

pub fn send_viewport_display_state_set(c: *ServerConnection, io: Io, payload: client_to_server.ViewportDisplayStateSet) !void {
    var buf: [constants.payload_max_size]u8 = undefined;
    const message = c.stringify(&buf, .{ .viewport_display_state_set = payload });
    try c.send(io, message);
}

pub fn send_viewport_close(c: *ServerConnection, io: Io, payload: client_to_server.RemoteViewportClose) !void {
    var buf: [constants.payload_max_size]u8 = undefined;
    const message = c.stringify(&buf, .{ .viewport_close = payload });
    try c.send(io, message);
}

pub fn send_cursor_shape_set(c: *ServerConnection, io: Io, payload: client_to_server.CursorShape) !void {
    var buf: [constants.payload_max_size]u8 = undefined;
    const message = c.stringify(&buf, .{ .cursor_shape_set = payload });
    try c.send(io, message);
}

fn stringify(c: *ServerConnection, buf: []u8, payload: client_to_server.MessagePayload) client_to_server.Message {
    std.debug.assert(c.format == .json);
    std.debug.assert(buf.len == constants.payload_max_size);

    var writer: Io.Writer = .fixed(buf);
    switch (payload) {
        inline else => |p| std.json.Stringify.value(p, .{}, &writer) catch unreachable,
    }
    const json = writer.buffered();

    const header: client_to_server.MessageHeader = .{
        .payload_len = @intCast(json.len),
        .format = .json,
        .message_tag = payload,
    };

    return .{ .header = header, .payload = json };
}

fn send(c: *ServerConnection, io: Io, message: client_to_server.Message) !void {
    var buf: [4096]u8 = undefined;
    var writer = c.stream.writer(io, &buf);

    const header_bytes = std.mem.toBytes(message.header);
    try writer.interface.writeAll(&header_bytes);
    try writer.interface.writeAll(message.payload);
    try writer.interface.flush();
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
const log = std.log.scoped(.Client);
