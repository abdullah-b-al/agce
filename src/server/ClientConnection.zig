const ClientConnection = @This();

format: ptypes.MessageFormat,
stream: zio.net.Stream,
closed: bool,
pid: ?ptypes.PID,

close_with_error: ?CloseError,

win32_event_handle: Win32EventHandle,

pub fn close(c: *ClientConnection) void {
    std.debug.assert(!c.closed);
    c.win32_event_handle.close();
    c.stream.close();
    c.closed = true;
}

pub const ReceiveError =
    error{ConnectionClosed} ||
    zio.ev.NetRecv.Error ||
    utils.ErrorSetOf(receive_with_reader);

pub fn receive_with_reader(
    _: *ClientConnection,
    _: Io,
    arena: std.mem.Allocator,
    reader: *Io.Reader,
) error{ ReadFailed, OutOfMemory, EndOfStream, InvalidHeader, HeaderWithoutPayload, ParseFailed }!client_to_server.MessagePayload {
    const header_bytes = try reader.take(@sizeOf(client_to_server.MessageHeader));

    const header = client_to_server.parse_message_header(header_bytes) catch |err| switch (err) {
        error.HeaderInvalidLen, error.HeaderInvalidFormat, error.HeaderInvalidMessageTag => {
            log.err("{}", .{err});
            return error.InvalidHeader;
        },
    };
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
                    const T = utils.TypeOfField(client_to_server.MessagePayload, @tagName(tag));
                    const parsed = std.json.parseFromSliceLeaky(T, arena, data, .{
                        .allocate = .alloc_if_needed,
                    }) catch |err| {
                        log.err("{}", .{err});
                        return error.ParseFailed;
                    };

                    return @unionInit(client_to_server.MessagePayload, @tagName(tag), parsed);
                },
            }
        },
    }
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

pub fn send_buffer_created_cpu(c: *ClientConnection, io: Io, gpa: std.mem.Allocator, const_payload: server_to_client.BufferCreatedCpu) !void {
    switch (os) {
        .linux => {
            const message = try c.stringify(gpa, .{ .buffer_created_cpu = const_payload });
            try c.send_with_fd(ptypes.CpuBufferHandle, const_payload.handle, gpa, message);
        },
        .windows => {
            const duplicate = try c.duplicate_handle(@ptrFromInt(@intFromEnum(const_payload.handle)));
            errdefer _ = win32.foundation.CloseHandle(duplicate);

            var payload = const_payload;
            payload.handle = .from_HANDLE(duplicate);
            const message = try c.stringify(gpa, .{ .buffer_created_cpu = payload });
            try c.send(io, gpa, message);
        },
        else => comptime unreachable,
    }
}

pub fn send_buffer_created_gbm_bo(c: *ClientConnection, _: Io, gpa: std.mem.Allocator, payload: server_to_client.BufferCreatedGbmBo) !void {
    if (!constants.os_has_gbm) @compileError("OS does not support gbm");

    const message = try c.stringify(gpa, .{ .buffer_created_gbm_bo = payload });
    try c.send_with_fd(ptypes.BufferAndTimelineFds, payload.fds, gpa, message);
}

pub fn send_texture_created_d3d(
    c: *ClientConnection,
    io: Io,
    gpa: std.mem.Allocator,
    const_payload: server_to_client.TextureCreatedD3D,
) !void {
    if (!constants.os_has_d3d) @compileError("OS does not support d3d");

    const duplicate_texture = try c.duplicate_handle(@ptrFromInt(@intFromEnum(const_payload.texture_handle)));
    errdefer _ = win32.foundation.CloseHandle(duplicate_texture);

    const duplicate_acquire = try c.duplicate_handle(@ptrFromInt(@intFromEnum(const_payload.acquire_fence_handle)));
    errdefer _ = win32.foundation.CloseHandle(duplicate_acquire);

    const duplicate_release = try c.duplicate_handle(@ptrFromInt(@intFromEnum(const_payload.release_fence_handle)));
    errdefer _ = win32.foundation.CloseHandle(duplicate_release);

    var payload = const_payload;
    payload.texture_handle = .from_HANDLE(duplicate_texture);
    payload.acquire_fence_handle = .from_HANDLE(duplicate_acquire);
    payload.release_fence_handle = .from_HANDLE(duplicate_release);
    const message = try c.stringify(gpa, .{ .texture_created_d3d = payload });
    try c.send(io, gpa, message);
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

fn send(c: *ClientConnection, _: Io, gpa: std.mem.Allocator, message: server_to_client.Message) !void {
    defer gpa.free(message.data);

    var buf: [4096]u8 = undefined;
    var writer = c.stream.writer(&buf);

    const header_bytes = std.mem.toBytes(message.header);
    writer.interface.writeAll(&header_bytes) catch |err| switch (err) {
        error.WriteFailed => return writer.err.?,
    };
    writer.interface.writeAll(message.data) catch |err| switch (err) {
        error.WriteFailed => return writer.err.?,
    };
    writer.interface.flush() catch |err| switch (err) {
        error.WriteFailed => return writer.err.?,
    };
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

fn duplicate_handle(c: *ClientConnection, handle: *anyopaque) !*anyopaque {
    const client_pid = c.pid orelse @panic("Must be provided in windows");
    // TODO: Do not recreate the hande everytime
    const client_handle = win32.system.threading.OpenProcess(
        win32.system.threading.PROCESS_DUP_HANDLE,
        @intFromEnum(std.os.windows.BOOL.FALSE),
        @intFromEnum(client_pid),
    ) orelse return error.Win32OpenProcessFailed;
    defer _ = win32.foundation.CloseHandle(client_handle);

    var duplicated: ?*anyopaque = null;
    const result = win32.foundation.DuplicateHandle(
        win32.system.threading.GetCurrentProcess(),
        handle,
        client_handle,
        &duplicated,
        0,
        @intFromEnum(std.os.windows.BOOL.FALSE),
        win32.foundation.DUPLICATE_SAME_ACCESS,
    );

    if (result == 0) {
        return error.DuplicateHandleFailed;
    }

    return duplicated.?;
}

pub const CloseError =
    ReceiveError ||
    Server.HandleMessageFromUnknownError ||
    error{ FailedToSendHandle, FailedToSendFds, FailedToCreateWin32EventHandle };

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const ptypes = @import("protocol").types;
const client_to_server = @import("protocol").client_to_server;
const server_to_client = @import("protocol").server_to_client;
const constants = @import("constants");
const os = @import("builtin").os.tag;
const utils = @import("utils");
const zio = @import("zio");
const win32 = @import("win32");
const win_sock = @import("win32").networking.win_sock;
const Win32EventHandle = @import("Win32EventHandle.zig");
const Server = @import("Server.zig");
const log = std.log.scoped(.Server);
