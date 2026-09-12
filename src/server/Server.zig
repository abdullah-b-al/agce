const Server = @This();

io: Io,
gpa: std.mem.Allocator,
environ: *std.process.Environ.Map,

rand: std.Random.DefaultPrng,
unix_path: []const u8,
server: net.Server,
clients: Clients,
generated_full_ids: std.array_hash_map.Auto(ptypes.ClientFullID, void),

pub fn create(
    io: Io,
    environ: *std.process.Environ.Map,
    gpa: std.mem.Allocator,
) !*Server {
    const server = try gpa.create(Server);
    errdefer gpa.destroy(server);

    var path_buf: [constants.socket_max_path]u8 = undefined;
    const unix_path = blk: {
        const path = utils.unix_address_path(environ, &path_buf);
        break :blk try gpa.dupe(u8, path);
    };
    const address = net.UnixAddress.init(unix_path) catch |err| switch (err) {
        error.NameTooLong => unreachable,
    };
    const net_server = address.listen(io, .{}) catch |err| {
        log.err("Failed to listen to socket {s} {}", .{ unix_path, err });
        return err;
    };
    log.info("Created server on {s}", .{address.path});

    server.* = .{
        .io = io,
        .gpa = gpa,
        .rand = .init(0),
        .environ = environ,
        .generated_full_ids = .empty,

        .unix_path = unix_path,
        .server = net_server,
        .clients = .init,
    };
    return server;
}

pub fn destroy(server: *Server) void {
    server.clients.deinit(server.io, server.gpa);
    server.generated_full_ids.deinit(server.gpa);

    server.server.deinit(server.io);
    Io.Dir.deleteFileAbsolute(server.io, server.unix_path) catch |err| switch (err) {
        error.Canceled => {},
        else => |e| {
            log.err("Could not delete unix socket {s} {}", .{ server.unix_path, e });
        },
    };

    server.gpa.free(server.unix_path);
    server.gpa.destroy(server);
}

fn message_receive(server: *const Server, arena: std.mem.Allocator, source: MessageSource) ReceivedMessage {
    const closed = switch (source) {
        .known => |id| server.clients.known.get(id).?.closed,
        .unknown => |index| server.clients.unknown.items[index].closed,
    };

    std.debug.assert(!closed);

    const stream = switch (source) {
        .known => |id| server.clients.known.get(id).?.stream,
        .unknown => |index| server.clients.unknown.items[index].stream,
    };

    const timeout: Io.Timeout =
        .{ .duration = .{ .raw = .fromNanoseconds(1), .clock = .awake } };

    const err_message = switch (os) {
        .linux => client_to_server.message_receive(server.io, arena, stream, timeout),
        .windows => @panic("TODO"),
        else => comptime unreachable,
    };

    return .{
        .payload = err_message,

        .from = switch (source) {
            .known => |id| .{ .known = id },
            .unknown => |index| .{ .unknown = index },
        },
    };
}

pub fn handle_message(server: *Server, message: ReceivedMessage, events: *std.ArrayList(WindowSystemEvent)) void {
    const @"error" = switch (message.from) {
        .known => server.handle_message_from_known(message, events),
        .unknown => server.handle_message_from_unknown(message, events),
    };

    @"error" catch |err| switch (err) {
        // irrelevant at this point
        error.Canceled => {},

        // TODO: Get the real error and handle it
        error.WriteFailed => {},

        error.MisbehavingUnknownClient,
        error.ClientSentInvalidClientFullID,
        error.OutOfMemoryDuringRegister,
        => {
            switch (message.from) {
                .unknown => |index| server.close_unknown_client_with(index, err),
                .known => @panic("Not possiable with a known client"),
            }
        },

        error.Unexpected,
        error.UnsupportedMessageOnOs,
        error.HeaderInvalidLen,
        error.HeaderInvalidFormat,
        error.HeaderInvalidMessageTag,
        error.ConnectionClosed,
        error.ConnectionResetByPeer,
        error.SocketUnconnected,
        error.CmsgNoHeader,
        error.CmsgInvalidLevel,
        error.CmsgInvalidType,
        => {
            switch (message.from) {
                .known => |id| {
                    server.close_known_client_with(id, err, events);
                },
                .unknown => |index| {
                    server.close_unknown_client_with(index, err);
                },
            }
        },

        error.Overflow,
        error.InvalidCharacter,
        error.RecvMsgFailed,
        error.UnexpectedToken,
        error.InvalidNumber,
        error.InvalidEnumTag,
        error.DuplicateField,
        error.UnknownField,
        error.MissingField,
        error.LengthMismatch,
        error.SyntaxError,
        error.UnexpectedEndOfInput,
        error.BufferUnderrun,
        error.ValueTooLong,
        error.SystemResources,
        error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded,
        error.MessageOversize,
        error.NetworkDown,
        error.PortUnreachable,
        error.ConcurrencyUnavailable,
        error.OutOfMemory,
        => |e| {
            log.err("{} when handling client message", .{e});
        },
    };
}

pub fn handle_events(
    server: *Server,
    events: []const Event,
) void {
    for (events) |e| {
        server.handle_event(e) catch |err| {
            log.err("{}", .{err});
        };
    }
}

pub fn handle_event(
    server: *Server,
    event: Event,
) error{ Canceled, WriteFailed, OutOfMemory, FailedToSendFds }!void {
    switch (event) {
        .unknown_client_connected => |stream| {
            errdefer stream.close(server.io);

            try server.clients.prepare_for_new_client(server.gpa);
            server.clients.new_unknown(server.gpa, stream);

            log.info("Unknown client connected", .{});
        },
        .buffer_created_cpu => |e, tag| {
            switch (os) {
                .linux => {
                    defer std.debug.assert(std.os.linux.close(@intFromEnum(e.payload.handle)) == 0);

                    const client = server.clients.known.get(e.client_id) orelse return;
                    const payload = @unionInit(
                        server_to_client.MessagePayload,
                        @tagName(tag),
                        e.payload,
                    );

                    try server_to_client.message_send_json(
                        server.io,
                        server.gpa,
                        client.stream,
                        @tagName(tag),
                        payload,
                    );
                },
                .windows => @panic("TODO"),
                else => comptime unreachable,
            }
        },
        .buffer_created_gbm_bo => |e, tag| {
            switch (os) {
                .linux => {
                    defer {
                        std.debug.assert(std.os.linux.close(@intFromEnum(e.payload.fds.buffer)) == 0);
                        std.debug.assert(std.os.linux.close(@intFromEnum(e.payload.fds.acquire_timeline)) == 0);
                        std.debug.assert(std.os.linux.close(@intFromEnum(e.payload.fds.release_timeline)) == 0);
                    }

                    const client = server.clients.known.get(e.client_id) orelse return;
                    const payload = @unionInit(
                        server_to_client.MessagePayload,
                        @tagName(tag),
                        e.payload,
                    );

                    try server_to_client.message_send_json(
                        server.io,
                        server.gpa,
                        client.stream,
                        @tagName(tag),
                        payload,
                    );
                },
                .windows => @panic("TODO"),
                else => comptime unreachable,
            }
        },

        inline else => |e, tag| {
            const client = server.clients.known.get(e.client_id) orelse return;

            const payload = @unionInit(
                server_to_client.MessagePayload,
                @tagName(tag),
                e.payload,
            );
            try server_to_client.message_send_json(
                server.io,
                server.gpa,
                client.stream,
                @tagName(tag),
                payload,
            );
        },
    }
}

const HandleMessageError = error{
    ConcurrencyUnavailable,
    Canceled,
    SystemResources,
    ConnectionResetByPeer,
    SocketUnconnected,
    Unexpected,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    MessageOversize,
    NetworkDown,
    PortUnreachable,
    OutOfMemory,
    Overflow,
    InvalidCharacter,
    ConnectionClosed,
    HeaderInvalidLen,
    HeaderInvalidFormat,
    HeaderInvalidMessageTag,
    RecvMsgFailed,
    UnexpectedToken,
    InvalidNumber,
    InvalidEnumTag,
    DuplicateField,
    UnknownField,
    MissingField,
    LengthMismatch,
    SyntaxError,
    UnexpectedEndOfInput,
    BufferUnderrun,
    ValueTooLong,
    UnsupportedMessageOnOs,
    WriteFailed,

    // linux only
    CmsgNoHeader,
    CmsgInvalidLevel,
    CmsgInvalidType,
};

fn handle_message_from_known(server: *Server, message: ReceivedMessage, events: *std.ArrayList(WindowSystemEvent)) HandleMessageError!void {
    std.debug.assert(message.from == .known);

    const client_id = message.from.known;
    const msg = (message.payload catch |err| return err) orelse return;

    switch (msg) {
        .generate_client_full_id => {
            const client = server.clients.known.get(client_id) orelse return;
            try server.generated_full_ids.ensureUnusedCapacity(server.gpa, 1);

            const full_id = server.generate_full_id();
            server.generated_full_ids.putAssumeCapacityNoClobber(full_id, {});
            log.debug("Generated {f}", .{full_id});

            try server_to_client.message_send_json(
                server.io,
                server.gpa,
                client.stream,
                "generated_client_full_id",
                .{ .generated_client_full_id = .{ .full_id = full_id } },
            );
        },
        else => {
            const client = server.clients.known.get(client_id).?;
            const wse = try server.window_system_event_from_message(client, msg);
            events.appendAssumeCapacity(wse);
        },
    }
}

const HandleMessageFromUnknownError =
    error{
        OutOfMemoryDuringRegister,
        MisbehavingUnknownClient,
        ClientSentInvalidClientFullID,
        WriteFailed,
    } || ErrorSetOf(client_to_server.message_receive);

fn handle_message_from_unknown(
    server: *Server,
    message: ReceivedMessage,
    events: *std.ArrayList(WindowSystemEvent),
) HandleMessageFromUnknownError!void {
    std.debug.assert(message.from == .unknown);

    const index = message.from.unknown;
    const msg = (message.payload catch |err| return err) orelse return;

    const register = switch (msg) {
        .register => |r| r,
        else => {
            return error.MisbehavingUnknownClient;
        },
    };

    const id = blk: {
        const full_id =
            register.full_id orelse
            break :blk server.clients.next_id.increment();

        if (server.generated_full_ids.contains(full_id)) {
            _ = server.generated_full_ids.orderedRemove(full_id);
            break :blk full_id.id;
        }

        log.err("{} {}", .{ error.ClientSentInvalidClientFullID, full_id });
        return error.ClientSentInvalidClientFullID;
    };

    server.clients.promote_client_to_known(server.gpa, index, id);
    log.debug("Promoted unknown client to {f}", .{id});

    //
    // Finalize registration
    //

    const client = server.clients.known.get(id).?;

    try server_to_client.message_send_json(
        server.io,
        server.gpa,
        client.stream,
        "registered",
        .{ .registered = .{} },
    );

    events.appendAssumeCapacity(
        .{ .client_registered = .{ .client_id = id } },
    );

    errdefer comptime unreachable;

    // broadcast the new client
    for (server.clients.known.values()) |other| {
        if (@intFromEnum(other.id) == @intFromEnum(client.id)) continue;

        server_to_client.message_send_json(
            server.io,
            server.gpa,
            other.stream,
            "client_registered",
            .{ .client_registered = .{ .client_id = client.id } },
        ) catch |err| log.err("{} from {f} during broadcast", .{ err, other.id });
    }
}

pub fn window_system_event_from_message(
    _: *Server,
    client: *Client,
    payload: client_to_server.MessagePayload,
) error{UnsupportedMessageOnOs}!WindowSystemEvent {
    switch (payload) {
        .register,
        .generate_client_full_id,
        => @panic("Cannot be turned into a WindowSystemEvent. This is meant for the Server"),

        inline .buffer_present,
        .buffer_present_with_sync,
        .buffer_destroy,
        .viewport_create,
        .cursor_shape_set,
        .sub_viewport_embed,
        .sub_viewport_pos_set,
        .sub_viewport_size_set,
        .sub_viewport_display_state_set,
        .viewport_destroy,
        .buffer_create_cpu,
        .buffer_create_gbm_bo,
        => |msg, tag| {
            return @unionInit(
                WindowSystemEvent,
                @tagName(tag),
                .{ .client_id = client.id, .payload = msg },
            );
        },
    }
}

pub fn generate_full_id(server: *Server) ptypes.ClientFullID {
    const client_id = server.clients.next_id.increment();
    var fp: ptypes.ClientFingerprint = @enumFromInt(server.rand.random().int(u32));

    while (server.generated_full_ids.contains(.{ .id = client_id, .fingerprint = fp })) {
        fp = @enumFromInt(server.rand.random().int(u32));
    }

    return .{ .id = client_id, .fingerprint = fp };
}

pub fn messages_receive(server: *Server, arena: std.mem.Allocator, poll_result: []const MessageSource) error{OutOfMemory}![]const ReceivedMessage {
    var list = try std.ArrayList(ReceivedMessage).initCapacity(arena, poll_result.len);

    for (poll_result) |result| {
        const message = server.message_receive(arena, result);
        list.appendAssumeCapacity(message);
    }

    return list.items;
}

pub fn messages_handle(server: *Server, arena: std.mem.Allocator, messages: []const ReceivedMessage) error{OutOfMemory}![]const WindowSystemEvent {
    var list: std.ArrayList(WindowSystemEvent) = try .initCapacity(arena, messages.len);

    for (messages) |msg| {
        server.handle_message(msg, &list);
    }

    return list.items;
}

fn close_known_client_with(server: *Server, id: ClientID, err: anyerror, events: *std.ArrayList(WindowSystemEvent)) void {
    const client = server.clients.known.get(id) orelse return;
    client.close(server.io);
    log.err("Closing client {} with {}", .{ id, err });

    events.appendAssumeCapacity(.{ .client_disconnected = client.id });

    for (server.clients.known.values()) |c| {
        if (c.id == id or c.closed) continue;

        server_to_client.message_send_json(
            server.io,
            server.gpa,
            c.stream,
            "client_disconnected",
            .{ .client_disconnected = .{ .client_id = id } },
        ) catch {};
    }
}

fn close_unknown_client_with(server: *Server, index: usize, err: anyerror) void {
    const client = server.clients.unknown.items[index];
    client.close(server.io);
    log.err("Closing client unknown with {}", .{err});

    switch (err) {
        error.MisbehavingUnknownClient => {
            log.err("Expected only a register message during register phase", .{});
        },
        else => {},
    }
}

fn ReturnType(comptime func: anytype) type {
    return @typeInfo(@TypeOf(func)).@"fn".return_type.?;
}

fn ErrorSetOf(comptime func: anytype) type {
    const T = @typeInfo(@TypeOf(func)).@"fn".return_type.?;
    return @typeInfo(T).error_union.error_set;
}

const ReceivedMessage = struct {
    payload: Payload,
    from: MessageSource,

    const Payload = ErrorSetOf(client_to_server.message_receive)!?client_to_server.MessagePayload;
};

pub const MessageSource = union(enum) {
    known: ClientID,
    unknown: usize,
};

pub const Event = union(enum) {
    const Payload = server_to_client.MessagePayload;

    unknown_client_connected: net.Stream,

    viewport_create: ptypes.WithClientID(Payload.ViewportCreate),
    viewport_created: ptypes.WithClientID(Payload.ViewportCreated),
    viewport_resize: ptypes.WithClientID(Payload.ViewportResize),
    viewport_close: ptypes.WithClientID(Payload.ViewportClose),
    viewport_display_state: ptypes.WithClientID(Payload.ViewportDisplayState),

    sub_viewport_embeded: ptypes.WithClientID(Payload.SubViewportEmbeded),
    sub_viewport_display_state: ptypes.WithClientID(Payload.SubViewportDisplayState),
    sub_viewport_closed: ptypes.WithClientID(Payload.SubviewportClosed),

    frame_render: ptypes.WithClientID(Payload.FrameRender),

    buffer_released: ptypes.WithClientID(Payload.BufferReleased),
    buffer_created_cpu: ptypes.WithClientID(Payload.BufferCreatedCpu),
    buffer_created_gbm_bo: ptypes.WithClientID(Payload.BufferCreatedGbmBo),

    keyboard_key: ptypes.WithClientID(Payload.KeyboardKey),
    keyboard_char: ptypes.WithClientID(Payload.KeyboardChar),
    mouse_enter: ptypes.WithClientID(Payload.MouseEnter),
    mouse_leave: ptypes.WithClientID(Payload.MouseLeave),
    mouse_motion: ptypes.WithClientID(Payload.MouseMotion),
    mouse_button: ptypes.WithClientID(Payload.MouseButton),
    mouse_scroll: ptypes.WithClientID(Payload.MouseScroll),

    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try utils.format_union(self, writer);
    }
};

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const utils = @import("utils");
const constants = @import("constants");
const Clients = @import("Clients.zig");
const log = std.log.scoped(.Server);
const os_tag = @import("builtin").os.tag;
const WindowSystemEvent = @import("../WindowSystem.zig").Event;
const server_to_client = @import("protocol").server_to_client;
const client_to_server = @import("protocol").client_to_server;
const ptypes = @import("protocol").types;
const ClientID = ptypes.ClientID;
const Client = Clients.Client;
const UnknownClient = Clients.UnknownClient;
const os = @import("builtin").os.tag;
