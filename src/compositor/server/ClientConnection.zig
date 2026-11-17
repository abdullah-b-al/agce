const ClientConnection = @This();

format: ptypes.MessageFormat,
stream: zio.net.Stream,
closed: bool,
pid: ?ptypes.PID,

close_with_error: ?CloseError,

win32_socket_event: Win32SocketEvent,

reader_buffer: []u8,
reader: zio.net.Stream.Reader,
messages_parsed: std.ArrayList(Server.ParsedMessage),

pub fn init(gpa: std.mem.Allocator, stream: zio.net.Stream, pid: ?ptypes.PID) !ClientConnection {
    const reader_buffer = try gpa.alloc(u8, 1024);
    errdefer gpa.free(reader_buffer);

    return .{
        .format = .json,
        .stream = stream,
        .closed = false,
        .pid = pid,
        .close_with_error = null,
        .messages_parsed = .empty,

        .win32_socket_event = try .create(stream.socket, .client),
        .reader_buffer = reader_buffer,
        .reader = stream.reader(reader_buffer),
    };
}

pub fn close(c: *ClientConnection, gpa: std.mem.Allocator) void {
    std.debug.assert(!c.closed);
    c.win32_socket_event.close();
    c.stream.close();

    for (c.messages_parsed.items) |*item| item.deinit(gpa);
    c.messages_parsed.deinit(gpa);

    gpa.free(c.reader_buffer);

    c.closed = true;
}

pub fn read_and_parse_all(
    c: *ClientConnection,
    io: Io,
    gpa: std.mem.Allocator,
    source: Server.MessageSource,
) error{OutOfMemory}!void {
    std.debug.assert(!c.closed);
    std.debug.assert(c.close_with_error == null);

    c.reader.setTimeout(.fromNanoseconds(0));

    var added_from_this_client: usize = 0;
    while (true) {
        try maybe_oom();
        try c.messages_parsed.ensureUnusedCapacity(gpa, 1);
        const parsed = c.receive_raw_with_reader_and_parse(
            io,
            gpa,
            source,
            &c.reader.interface,
        ) catch |err|
            switch (err) {
                error.OutOfMemory => |e| return e,

                error.EndOfStream => {
                    if (added_from_this_client == 0) {
                        c.close_with_error = error.ConnectionClosed;
                    }
                    return;
                },
                error.ReadFailed => switch (c.reader.err.?) {
                    error.Timeout => break,
                    else => |e| {
                        c.close_with_error = e;
                        return;
                    },
                },

                error.PayloadExceedsMaxSize,
                error.ParseFailed,
                error.InvalidHeader,
                error.HeaderWithoutPayload,
                => |e| {
                    log.err("{}", .{e});
                    continue;
                },
            };

        c.messages_parsed.insertAssumeCapacity(0, parsed);
        added_from_this_client += 1;
    }
}

pub fn receive_raw_with_reader_and_parse(
    _: *ClientConnection,
    _: Io,
    gpa: std.mem.Allocator,
    source: Server.MessageSource,
    reader: *Io.Reader,
) error{
    ReadFailed,
    ParseFailed,
    OutOfMemory,
    EndOfStream,
    InvalidHeader,
    HeaderWithoutPayload,
    PayloadExceedsMaxSize,
}!Server.ParsedMessage {
    var arena = try gpa.create(std.heap.ArenaAllocator);
    arena.* = .init(gpa);
    errdefer {
        arena.deinit();
        gpa.destroy(arena);
    }

    const header_bytes = try reader.take(@sizeOf(client_to_server.MessageHeader));

    const header = client_to_server.parse_message_header(header_bytes) catch |err| switch (err) {
        error.HeaderInvalidLen, error.HeaderInvalidFormat, error.HeaderInvalidMessageTag => {
            log.err("{}", .{err});
            return error.InvalidHeader;
        },
    };

    var buf: [constants.payload_max_size]u8 = undefined;

    if (header.payload_len > buf.len) {
        try reader.discardAll(header.payload_len);
        return error.PayloadExceedsMaxSize;
    }

    reader.readSliceAll(buf[0..header.payload_len]) catch |err| return switch (err) {
        error.EndOfStream => error.HeaderWithoutPayload,
        error.ReadFailed => |e| e,
    };

    const payload = try Server.ParsedMessage.parse(
        header,
        buf[0..header.payload_len],
        arena.allocator(),
    );

    return .{
        .arena = arena,
        .header = header,
        .payload = payload,
        .from = source,
    };
}

pub fn send_registered(c: *ClientConnection, io: Io, payload: server_to_client.Void) !void {
    var buf: [constants.payload_max_size]u8 = undefined;
    const message = c.stringify(&buf, .{ .registered = payload });
    try c.send(io, message);
}

pub fn send_viewport_create(c: *ClientConnection, io: Io, payload: server_to_client.ViewportCreate) !void {
    var buf: [constants.payload_max_size]u8 = undefined;
    const message = c.stringify(&buf, .{ .viewport_create = payload });
    try c.send(io, message);
}

pub fn send_viewport_created(c: *ClientConnection, io: Io, payload: server_to_client.ViewportCreated) !void {
    var buf: [constants.payload_max_size]u8 = undefined;
    const message = c.stringify(&buf, .{ .viewport_created = payload });
    try c.send(io, message);
}

pub fn send_viewport_resize(c: *ClientConnection, io: Io, payload: server_to_client.ViewportResize) !void {
    var buf: [constants.payload_max_size]u8 = undefined;
    const message = c.stringify(&buf, .{ .viewport_resize = payload });
    try c.send(io, message);
}

pub fn send_viewport_close(c: *ClientConnection, io: Io, payload: server_to_client.ViewportClose) !void {
    var buf: [constants.payload_max_size]u8 = undefined;
    const message = c.stringify(&buf, .{ .viewport_close = payload });
    try c.send(io, message);
}

pub fn send_viewport_display_state(c: *ClientConnection, io: Io, payload: server_to_client.ViewportDisplayState) !void {
    var buf: [constants.payload_max_size]u8 = undefined;
    const message = c.stringify(&buf, .{ .viewport_display_state = payload });
    try c.send(io, message);
}

pub fn send_remote_viewport_created(c: *ClientConnection, io: Io, payload: server_to_client.RemoteViewportCreated) !void {
    var buf: [constants.payload_max_size]u8 = undefined;
    const message = c.stringify(&buf, .{ .remote_viewport_created = payload });
    try c.send(io, message);
}

pub fn send_remote_viewport_display_state(c: *ClientConnection, io: Io, payload: server_to_client.RemoteViewportDisplayState) !void {
    var buf: [constants.payload_max_size]u8 = undefined;
    const message = c.stringify(&buf, .{ .remote_viewport_display_state = payload });
    try c.send(io, message);
}

pub fn send_remote_viewport_render_size(c: *ClientConnection, io: Io, payload: server_to_client.RemoteViewportRenderSize) !void {
    var buf: [constants.payload_max_size]u8 = undefined;
    const message = c.stringify(&buf, .{ .remote_viewport_render_size = payload });
    try c.send(io, message);
}

pub fn send_remote_viewport_closed(c: *ClientConnection, io: Io, payload: server_to_client.RemoteViewportClosed) !void {
    var buf: [constants.payload_max_size]u8 = undefined;
    const message = c.stringify(&buf, .{ .remote_viewport_closed = payload });
    try c.send(io, message);
}

pub fn send_client_registered(c: *ClientConnection, io: Io, payload: server_to_client.ClientRegistered) !void {
    var buf: [constants.payload_max_size]u8 = undefined;
    const message = c.stringify(&buf, .{ .client_registered = payload });
    try c.send(io, message);
}

pub fn send_client_disconnected(c: *ClientConnection, io: Io, payload: server_to_client.ClientDisconnected) !void {
    var buf: [constants.payload_max_size]u8 = undefined;
    const message = c.stringify(&buf, .{ .client_disconnected = payload });
    try c.send(io, message);
}

pub fn send_buffer_released(c: *ClientConnection, io: Io, payload: server_to_client.BufferReleased) !void {
    var buf: [constants.payload_max_size]u8 = undefined;
    const message = c.stringify(&buf, .{ .buffer_released = payload });
    try c.send(io, message);
}

pub fn send_buffer_created_cpu(c: *ClientConnection, io: Io, const_payload: server_to_client.BufferCreatedCpu) !void {
    switch (os) {
        .linux => {
            var buf: [constants.payload_max_size]u8 = undefined;
            const message = c.stringify(&buf, .{ .buffer_created_cpu = const_payload });
            switch (const_payload) {
                .success => |s| {
                    try c.send_with_fd(ptypes.CpuBufferHandle, s.handle, message);
                },
                .failure => {
                    try c.send(io, message);
                },
            }
        },
        .windows => {
            var payload = const_payload;
            switch (payload) {
                .success => |s| {
                    const duplicate = try c.duplicate_handle(s.handle.to_HANDLE());
                    errdefer _ = win32.foundation.CloseHandle(duplicate);

                    payload.success.handle = .from_HANDLE(duplicate);
                    var buf: [constants.payload_max_size]u8 = undefined;
                    const message = c.stringify(&buf, .{ .buffer_created_cpu = payload });
                    try c.send(io, message);
                },
                .failure => {
                    var buf: [constants.payload_max_size]u8 = undefined;
                    const message = c.stringify(&buf, .{ .buffer_created_cpu = payload });
                    try c.send(io, message);
                },
            }
        },
        else => comptime unreachable,
    }
}

pub fn send_buffer_created_gbm_bo(c: *ClientConnection, io: Io, payload: server_to_client.BufferCreatedGbmBo) !void {
    if (!constants.os_has_gbm) @compileError("OS does not support gbm");

    var buf: [constants.payload_max_size]u8 = undefined;
    const message = c.stringify(&buf, .{ .buffer_created_gbm_bo = payload });
    switch (payload) {
        .success => |s| {
            try c.send_with_fd(ptypes.BufferAndTimelineFds, s.fds, message);
        },
        .failure => {
            try c.send(io, message);
        },
    }
}

pub fn send_texture_created_d3d(
    c: *ClientConnection,
    io: Io,
    const_payload: server_to_client.TextureCreatedD3D,
) !void {
    if (!constants.os_has_d3d) @compileError("OS does not support d3d");

    var payload = const_payload;
    switch (payload) {
        .success => |s| {
            const duplicate_texture = try c.duplicate_handle(s.texture_handle.to_HANDLE());
            errdefer _ = win32.foundation.CloseHandle(duplicate_texture);

            const duplicate_acquire = try c.duplicate_handle(s.acquire_fence_handle.to_HANDLE());
            errdefer _ = win32.foundation.CloseHandle(duplicate_acquire);

            const duplicate_release = try c.duplicate_handle(s.release_fence_handle.to_HANDLE());
            errdefer _ = win32.foundation.CloseHandle(duplicate_release);

            payload.success.texture_handle = .from_HANDLE(duplicate_texture);
            payload.success.acquire_fence_handle = .from_HANDLE(duplicate_acquire);
            payload.success.release_fence_handle = .from_HANDLE(duplicate_release);

            var buf: [constants.payload_max_size]u8 = undefined;
            const message = c.stringify(&buf, .{ .texture_created_d3d = payload });
            try c.send(io, message);
        },
        .failure => {
            var buf: [constants.payload_max_size]u8 = undefined;
            const message = c.stringify(&buf, .{ .texture_created_d3d = payload });
            try c.send(io, message);
        },
    }
}

pub fn send_frame_render(c: *ClientConnection, io: Io, payload: server_to_client.FrameRender) !void {
    var buf: [constants.payload_max_size]u8 = undefined;
    const message = c.stringify(&buf, .{ .frame_render = payload });
    try c.send(io, message);
}

pub fn send_keyboard_enter(c: *ClientConnection, io: Io, payload: server_to_client.KeyboardEnter) !void {
    var buf: [constants.payload_max_size]u8 = undefined;
    const message = c.stringify(&buf, .{ .keyboard_enter = payload });
    try c.send(io, message);
}

pub fn send_keyboard_leave(c: *ClientConnection, io: Io, payload: server_to_client.KeyboardLeave) !void {
    var buf: [constants.payload_max_size]u8 = undefined;
    const message = c.stringify(&buf, .{ .keyboard_leave = payload });
    try c.send(io, message);
}

pub fn send_keyboard_char(c: *ClientConnection, io: Io, payload: server_to_client.KeyboardChar) !void {
    var buf: [constants.payload_max_size]u8 = undefined;
    const message = c.stringify(&buf, .{ .keyboard_char = payload });
    try c.send(io, message);
}

pub fn send_keyboard_key(c: *ClientConnection, io: Io, payload: server_to_client.KeyboardKey) !void {
    var buf: [constants.payload_max_size]u8 = undefined;
    const message = c.stringify(&buf, .{ .keyboard_key = payload });
    try c.send(io, message);
}

pub fn send_mouse_enter(c: *ClientConnection, io: Io, payload: server_to_client.MouseEnter) !void {
    var buf: [constants.payload_max_size]u8 = undefined;
    const message = c.stringify(&buf, .{ .mouse_enter = payload });
    try c.send(io, message);
}

pub fn send_mouse_leave(c: *ClientConnection, io: Io, payload: server_to_client.MouseLeave) !void {
    var buf: [constants.payload_max_size]u8 = undefined;
    const message = c.stringify(&buf, .{ .mouse_leave = payload });
    try c.send(io, message);
}

pub fn send_mouse_motion(c: *ClientConnection, io: Io, payload: server_to_client.MouseMotion) !void {
    var buf: [constants.payload_max_size]u8 = undefined;
    const message = c.stringify(&buf, .{ .mouse_motion = payload });
    try c.send(io, message);
}

pub fn send_mouse_button(c: *ClientConnection, io: Io, payload: server_to_client.MouseButton) !void {
    var buf: [constants.payload_max_size]u8 = undefined;
    const message = c.stringify(&buf, .{ .mouse_button = payload });
    try c.send(io, message);
}

pub fn send_mouse_scroll(c: *ClientConnection, io: Io, payload: server_to_client.MouseScroll) !void {
    var buf: [constants.payload_max_size]u8 = undefined;
    const message = c.stringify(&buf, .{ .mouse_scroll = payload });
    try c.send(io, message);
}

fn stringify(c: *ClientConnection, buf: []u8, payload: server_to_client.MessagePayload) server_to_client.Message {
    std.debug.assert(c.format == .json);
    std.debug.assert(buf.len == constants.payload_max_size);

    var writer: Io.Writer = .fixed(buf);
    switch (payload) {
        inline else => |_, tag| {
            const p = @field(payload, @tagName(tag));
            std.json.Stringify.value(p, .{}, &writer) catch unreachable;
        },
    }
    const json = writer.buffered();

    const header: server_to_client.MessageHeader = .{
        .payload_len = @intCast(json.len),
        .format = .json,
        .message_tag = payload,
    };

    return .{ .header = header, .data = json };
}

fn send(c: *ClientConnection, _: Io, message: server_to_client.Message) !void {
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

fn send_with_fd(c: *ClientConnection, comptime Fd: type, fd: Fd, message: server_to_client.Message) !void {
    if (!constants.os_supports_fd) @compileError("OS does not support function");

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
    zio.ev.NetRecv.Error ||
    Server.HandleMessageFromUnknownError ||
    error{ FailedToSendHandle, FailedToSendFds };

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
const Win32SocketEvent = @import("Win32SocketEvent.zig");
const Server = @import("Server.zig");
const log = std.log.scoped(.Server);
const maybe_oom = @import("../maybe_oom.zig").maybe_oom;
