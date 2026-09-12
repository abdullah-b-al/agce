const ClientConnection = @This();

format: ptypes.MessageFormat,
stream: net.Stream,
closed: bool,

pub fn receive(c: *ClientConnection, io: Io, arena: std.mem.Allocator, timeout: Io.Timeout) !?client_to_server.MessagePayload {
    return switch (os) {
        .linux => try receive_linux(io, arena, c.stream, timeout),
        .windows => @panic("TODO"),
        else => comptime unreachable,
    };
}

pub fn send_registered(c: *ClientConnection, io: Io, gpa: std.mem.Allocator, payload: server_to_client.Void) !void {
    const message = try c.stringify(gpa, .{ .registered = payload });
    try c.send(io, gpa, message);
}

pub fn send_generated_client_full_id(c: *ClientConnection, io: Io, gpa: std.mem.Allocator, payload: server_to_client.GeneratedClientFullID) !void {
    const message = try c.stringify(gpa, .{ .generated_client_full_id = payload });
    try c.send(io, gpa, message);
}

pub fn send_viewport_create(c: *ClientConnection, io: Io, gpa: std.mem.Allocator, payload: server_to_client.ViewportCreate) !void {
    const message = try c.stringify(gpa, .{ .viewport_create = payload });
    try c.send(io, gpa, message);
}

pub fn send_viewport_created(c: *ClientConnection, io: Io, gpa: std.mem.Allocator, payload: server_to_client.ViewportCreated) !void {
    const message = try c.stringify(gpa, .{ .viewport_created = payload });
    try c.send(io, gpa, message);
}

pub fn send_viewport_resize(c: *ClientConnection, io: Io, gpa: std.mem.Allocator, payload: server_to_client.ViewportResize) !void {
    const message = try c.stringify(gpa, .{ .viewport_resize = payload });
    try c.send(io, gpa, message);
}

pub fn send_viewport_close(c: *ClientConnection, io: Io, gpa: std.mem.Allocator, payload: server_to_client.ViewportClose) !void {
    const message = try c.stringify(gpa, .{ .viewport_close = payload });
    try c.send(io, gpa, message);
}

pub fn send_viewport_display_state(c: *ClientConnection, io: Io, gpa: std.mem.Allocator, payload: server_to_client.ViewportDisplayState) !void {
    const message = try c.stringify(gpa, .{ .viewport_display_state = payload });
    try c.send(io, gpa, message);
}

pub fn send_sub_viewport_embeded(c: *ClientConnection, io: Io, gpa: std.mem.Allocator, payload: server_to_client.SubViewportEmbeded) !void {
    const message = try c.stringify(gpa, .{ .sub_viewport_embeded = payload });
    try c.send(io, gpa, message);
}

pub fn send_sub_viewport_display_state(c: *ClientConnection, io: Io, gpa: std.mem.Allocator, payload: server_to_client.SubViewportDisplayState) !void {
    const message = try c.stringify(gpa, .{ .sub_viewport_display_state = payload });
    try c.send(io, gpa, message);
}

pub fn send_sub_viewport_closed(c: *ClientConnection, io: Io, gpa: std.mem.Allocator, payload: server_to_client.SubviewportClosed) !void {
    const message = try c.stringify(gpa, .{ .sub_viewport_closed = payload });
    try c.send(io, gpa, message);
}

pub fn send_client_registered(c: *ClientConnection, io: Io, gpa: std.mem.Allocator, payload: server_to_client.ClientRegistered) !void {
    const message = try c.stringify(gpa, .{ .client_registered = payload });
    try c.send(io, gpa, message);
}
pub fn send_client_disconnected(c: *ClientConnection, io: Io, gpa: std.mem.Allocator, payload: server_to_client.ClientDisconnected) !void {
    const message = try c.stringify(gpa, .{ .client_disconnected = payload });
    try c.send(io, gpa, message);
}

pub fn send_buffer_released(c: *ClientConnection, io: Io, gpa: std.mem.Allocator, payload: server_to_client.BufferReleased) !void {
    const message = try c.stringify(gpa, .{ .buffer_released = payload });
    try c.send(io, gpa, message);
}

pub fn send_buffer_created_cpu(c: *ClientConnection, _: Io, gpa: std.mem.Allocator, payload: server_to_client.BufferCreatedCpu) !void {
    const message = try c.stringify(gpa, .{ .buffer_created_cpu = payload });

    switch (os) {
        .linux => {
            try c.send_with_fd(ptypes.CpuBufferHandle, payload.handle, gpa, message);
        },
        .windows => @panic("TODO"),
        else => comptime unreachable,
    }
}

pub fn send_buffer_created_gbm_bo(c: *ClientConnection, _: Io, gpa: std.mem.Allocator, payload: server_to_client.BufferCreatedGbmBo) !void {
    if (!constants.os_has_gbm) @compileError("OS does not support gbm");

    const message = try c.stringify(gpa, .{ .buffer_created_gbm_bo = payload });
    try c.send_with_fd(ptypes.BufferAndTimelineFds, payload.fds, gpa, message);
}

pub fn send_frame_render(c: *ClientConnection, io: Io, gpa: std.mem.Allocator, payload: server_to_client.FrameRender) !void {
    const message = try c.stringify(gpa, .{ .frame_render = payload });
    try c.send(io, gpa, message);
}

pub fn send_keyboard_char(c: *ClientConnection, io: Io, gpa: std.mem.Allocator, payload: server_to_client.KeyboardChar) !void {
    const message = try c.stringify(gpa, .{ .keyboard_char = payload });
    try c.send(io, gpa, message);
}

pub fn send_keyboard_key(c: *ClientConnection, io: Io, gpa: std.mem.Allocator, payload: server_to_client.KeyboardKey) !void {
    const message = try c.stringify(gpa, .{ .keyboard_key = payload });
    try c.send(io, gpa, message);
}

pub fn send_mouse_enter(c: *ClientConnection, io: Io, gpa: std.mem.Allocator, payload: server_to_client.MouseEnter) !void {
    const message = try c.stringify(gpa, .{ .mouse_enter = payload });
    try c.send(io, gpa, message);
}

pub fn send_mouse_leave(c: *ClientConnection, io: Io, gpa: std.mem.Allocator, payload: server_to_client.MouseLeave) !void {
    const message = try c.stringify(gpa, .{ .mouse_leave = payload });
    try c.send(io, gpa, message);
}

pub fn send_mouse_motion(c: *ClientConnection, io: Io, gpa: std.mem.Allocator, payload: server_to_client.MouseMotion) !void {
    const message = try c.stringify(gpa, .{ .mouse_motion = payload });
    try c.send(io, gpa, message);
}

pub fn send_mouse_button(c: *ClientConnection, io: Io, gpa: std.mem.Allocator, payload: server_to_client.MouseButton) !void {
    const message = try c.stringify(gpa, .{ .mouse_button = payload });
    try c.send(io, gpa, message);
}

pub fn send_mouse_scroll(c: *ClientConnection, io: Io, gpa: std.mem.Allocator, payload: server_to_client.MouseScroll) !void {
    const message = try c.stringify(gpa, .{ .mouse_scroll = payload });
    try c.send(io, gpa, message);
}

fn stringify(c: *ClientConnection, gpa: std.mem.Allocator, payload: server_to_client.MessagePayload) !server_to_client.Message {
    std.debug.assert(c.format == .json);

    const json = blk: switch (payload) {
        inline else => |_, tag| {
            var p = @field(payload, @tagName(tag));

            // The fd that's part of the json is wrong.
            // Set them to .invalid to invalidate their use
            const T = @TypeOf(p);
            if (comptime utils.contains_a_fd(T)) |name| {
                @field(p, name) = .invalid;
            }

            break :blk try std.json.Stringify.valueAlloc(gpa, p, .{});
        },
    };

    const header: server_to_client.MessageHeader = .{
        .payload_len = @intCast(json.len),
        .format = .json,
        .message_tag = payload,
    };

    return .{ .header = header, .data = json };
}

fn send(c: *ClientConnection, io: Io, gpa: std.mem.Allocator, message: server_to_client.Message) !void {
    defer gpa.free(message.data);

    var buf: [4096]u8 = undefined;
    var writer = c.stream.writer(io, &buf);

    const header_bytes = std.mem.toBytes(message.header);
    try writer.interface.writeAll(&header_bytes);
    try writer.interface.writeAll(message.data);
    try writer.interface.flush();
}

fn send_with_fd(c: *ClientConnection, comptime Fd: type, fd: Fd, gpa: std.mem.Allocator, message: server_to_client.Message) !void {
    if (!constants.os_supports_fd) @compileError("OS does not support function");
    defer gpa.free(message.data);

    const header_bytes = std.mem.toBytes(message.header);
    var buf: [4096]u8 = undefined;
    std.mem.copyForwards(u8, &buf, &header_bytes);
    std.mem.copyForwards(u8, buf[header_bytes.len..], message.data);

    const len = @sizeOf(server_to_client.MessageHeader) + message.data.len;

    const result = server_to_client.send_fd(c.stream.socket.handle, Fd, fd, buf[0..len]);
    if (result < 0) {
        return error.FailedToSendFds;
    }
}

fn receive_linux(io: Io, arena: std.mem.Allocator, stream: net.Stream, timeout: Io.Timeout) !?client_to_server.MessagePayload {
    const peek = try client_to_server.message_peek(io, stream, timeout) orelse return null;

    const header = try client_to_server.parse_message_header(peek.data);

    const message_buf = try arena.alloc(u8, header.payload_len + @sizeOf(client_to_server.MessageHeader));
    return try client_to_server.read_and_parse_data_json(io, arena, stream, header, message_buf);
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
