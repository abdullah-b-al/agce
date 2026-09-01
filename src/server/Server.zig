const Server = @This();

io: Io,
gpa: std.mem.Allocator,
environ: *std.process.Environ.Map,
dispatch: *Dispatch,

rand: std.Random.DefaultPrng,
unix_path: []const u8,
server: net.Server,
clients: Clients,
generated_full_ids: std.array_hash_map.Auto(ptypes.ClientFullID, void),
arena_pool: std.ArrayList(*std.heap.ArenaAllocator),

pub fn create(
    io: Io,
    environ: *std.process.Environ.Map,
    gpa: std.mem.Allocator,
    dispatch: *Dispatch,
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

    const arena_count = 32;
    var arena_pool: std.ArrayList(*std.heap.ArenaAllocator) = try .initCapacity(gpa, arena_count);
    for (0..arena_count) |_| {
        const arena = try gpa.create(std.heap.ArenaAllocator);
        arena.* = .init(gpa);
        arena_pool.appendAssumeCapacity(arena);
    }

    server.* = .{
        .io = io,
        .gpa = gpa,
        .dispatch = dispatch,
        .rand = .init(0),
        .environ = environ,
        .generated_full_ids = .empty,

        .unix_path = unix_path,
        .server = net_server,
        .clients = .init,
        .arena_pool = arena_pool,
    };
    return server;
}

pub fn destroy(server: *Server) void {
    server.clients.deinit(server.io, server.gpa);
    server.generated_full_ids.deinit(server.gpa);

    for (server.arena_pool.items) |arena| {
        arena.deinit();
        server.gpa.destroy(arena);
    }
    server.arena_pool.deinit(server.gpa);

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

pub fn arena_acquire(server: *Server) *std.heap.ArenaAllocator {
    return server.arena_pool.pop() orelse @panic("Too many acquire requests");
}

pub fn arena_release(server: *Server, arena: *std.heap.ArenaAllocator) void {
    _ = arena.reset(.free_all);
    server.arena_pool.appendAssumeCapacity(arena);
}

fn message_receive(server: *const Server, arena: std.mem.Allocator, client_message: ClientMessage) ReceivedMessage {
    if (client_message.err) |err| {
        return .{
            .payload = .{ .err = err },
            .from = switch (client_message.client) {
                .known => |id| .{ .known = id },
                .unknown => |index| .{ .unknown = index },
            },
        };
    }

    const timeout: Io.Timeout =
        .{ .duration = .{ .raw = .fromNanoseconds(1), .clock = .awake } };

    const closed = switch (client_message.client) {
        .known => |id| server.clients.known.get(id).?.closed,
        .unknown => |index| server.clients.unknown.items[index].closed,
    };

    std.debug.assert(!closed);

    const stream = switch (client_message.client) {
        .known => |id| server.clients.known.get(id).?.stream,
        .unknown => |index| server.clients.unknown.items[index].stream,
    };

    const err_message = client_to_server.message_receive(server.io, arena, stream, timeout);

    return .{
        .payload = if (err_message) |message|
            .{ .message = message }
        else |err|
            .{ .err = err },

        .from = switch (client_message.client) {
            .known => |id| .{ .known = id },
            .unknown => |index| .{ .unknown = index },
        },
    };
}

pub fn handle_message(server: *Server, message: ReceivedMessage) void {
    const @"error" = switch (message.from) {
        .known => server.handle_message_from_known(message),
        .unknown => server.handle_message_from_unknown(message),
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
                    server.close_known_client_with(id, err);
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
        error.UnsupportedMessageOnOs,
        error.SystemResources,
        error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded,
        error.MessageOversize,
        error.NetworkDown,
        error.PortUnreachable,
        error.ConcurrencyUnavailable,
        error.OutOfMemory,
        error.Unexpected,
        => |e| {
            log.err("{} when handling client message", .{e});
        },
    };
}

pub fn handle_event(
    server: *Server,
    event: Dispatch.ServerEvent,
) error{ Canceled, WriteFailed, OutOfMemory, Exit }!void {
    switch (event) {
        .exit => {
            return error.Exit;
        },
        .unknown_client_connected => |stream| {
            errdefer stream.close(server.io);

            try server.clients.prepare_for_new_client(server.gpa);
            server.clients.new_unknown(server.gpa, stream);

            log.info("Unknown client connected", .{});
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
                payload,
            );
        },
    }
}

fn handle_message_from_known(server: *Server, message: ReceivedMessage) !void {
    std.debug.assert(message.from == .known);

    const client_id = message.from.known;
    const msg = switch (message.payload) {
        .err => |err| return err,
        .message => |msg| msg orelse return,
    };

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
                .{ .generated_client_full_id = .{ .full_id = full_id } },
            );
        },
        else => {
            const client = server.clients.known.get(client_id).?;
            const wse = try server.window_system_event_from_message(client, msg);
            try server.dispatch.window_system_put(@src(), wse);
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
) HandleMessageFromUnknownError!void {
    std.debug.assert(message.from == .unknown);

    const index = message.from.unknown;
    const msg = switch (message.payload) {
        .err => |err| return err,
        .message => |msg| msg orelse return,
    };

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
        .{ .registered = .{} },
    );

    try server.dispatch.window_system_put(@src(), .{
        .client_registered = .{ .client_id = id, .info = register.info },
    });

    errdefer comptime unreachable;

    // broadcast the new client's info
    for (server.clients.known.values()) |other| {
        if (@intFromEnum(other.id) == @intFromEnum(client.id)) continue;

        server_to_client.message_send_json(
            server.io,
            server.gpa,
            other.stream,
            .{ .client_registered = .{ .client_id = client.id, .info = register.info } },
        ) catch |err| log.err("{} from {f} during broadcast", .{ err, other.id });
    }
}

pub fn window_system_event_from_message(
    _: *Server,
    client: *Client,
    payload: client_to_server.MessagePayload,
) error{UnsupportedMessageOnOs}!Dispatch.WindowSystemEvent {
    switch (payload) {
        .register,
        .generate_client_full_id,
        => @panic("Cannot be turned into a WindowSystemEvent. This is meant for the Server"),

        inline .buffer_create_cpu_with_fd,
        .buffer_create_gpu_with_fds,
        => |msg, tag| {
            if (os_tag != .linux) {
                return error.UnsupportedMessageOnOs;
            }

            const T = utils.TypeOfField(Dispatch.WindowSystemEvent, @tagName(tag));
            const expr: T = switch (tag) {
                .buffer_create_cpu_with_fd => .{
                    .client_id = client.id,
                    .payload = .{
                        .buffer_id = msg.buffer_id,
                        .fd = msg.fd,
                        .width = msg.width,
                        .height = msg.height,
                        .format = msg.format,
                    },
                },
                .buffer_create_gpu_with_fds => .{
                    .client_id = client.id,
                    .payload = .{
                        .buffer_id = msg.buffer_id,
                        .fds = msg.fds,
                        .width = msg.width,
                        .height = msg.height,
                        .format = msg.format,
                        .gbm_bo_modifier = msg.gbm_bo_modifier,
                    },
                },
                else => comptime unreachable,
            };

            return @unionInit(Dispatch.WindowSystemEvent, @tagName(tag), expr);
        },

        inline .buffer_present,
        .buffer_present_with_sync,
        .buffer_destroy,
        .viewport_create,
        .cursor_shape_set,
        .sub_viewport_embed,
        .sub_viewport_rect_set,
        .sub_viewport_display_state_set,
        => |msg, tag| {
            return @unionInit(
                Dispatch.WindowSystemEvent,
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

fn close_known_client_with(server: *Server, id: ClientID, err: anyerror) void {
    const client = server.clients.known.get(id) orelse return;
    client.close(server.io);
    log.err("Closing client {} with {}", .{ id, err });

    server.dispatch.window_system_put(
        @src(),
        .{ .client_disconnected = client.id },
    ) catch {};

    for (server.clients.known.values()) |c| {
        if (c.id == id) continue;

        server_to_client.message_send_json(
            server.io,
            server.gpa,
            c.stream,
            .{
                .client_disconnected = .{ .client_id = id },
            },
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

pub const ClientMessage = struct {
    err: ?Io.Operation.NetReceive.Error,
    client: Source,

    const Source = union(enum) {
        known: ClientID,
        unknown: usize,
    };
};

fn ReturnType(comptime func: anytype) type {
    return @typeInfo(@TypeOf(func)).@"fn".return_type.?;
}

fn ErrorSetOf(comptime func: anytype) type {
    const T = @typeInfo(@TypeOf(func)).@"fn".return_type.?;
    return @typeInfo(T).error_union.error_set;
}

pub const Task = union(enum) {
    const Tag = std.meta.Tag(Task);

    get_events: ReturnType(fn_get_events),
    get_client_messages: ReturnType(fn_get_client_messages),

    pub fn handle(task: Task, server: *Server) error{ Canceled, OutOfMemory, Exit }!void {
        switch (task) {
            .get_events => |result| {
                defer server.arena_release(result.arena);

                if (result.err) |err| return err;

                for (result.events) |event| {
                    server.handle_event(event) catch |err| switch (err) {
                        error.Exit, error.Canceled => |e| return e,
                        else => |e| log.err("Server: {}", .{e}),
                    };
                }
            },
            .get_client_messages => |result| {
                defer server.arena_release(result.arena);

                if (result.err) |err| return err;

                for (result.messages) |message| {
                    server.handle_message(message);
                }
            },
        }

        server.clients.remove_closed_known_clients();
        server.clients.remove_promoted_or_closed_unknown_clients();
    }

    pub fn fn_get_events(server: *Server, arena: *std.heap.ArenaAllocator) GetEvents {
        const buf = arena.allocator().alloc(Dispatch.ServerEvent, 128) catch |err|
            return .@"error"(arena, err);

        const len = server.dispatch.server_get_many(buf) catch |err|
            return .@"error"(arena, err);

        return .{ .arena = arena, .events = buf[0..len], .err = null };
    }

    pub fn fn_get_client_messages(server: *Server, arena: *std.heap.ArenaAllocator) GetClientMessages {

        // In zig 0.16 we cannot get aux data from a unix socket.
        // So we peek in a batch then get the each message on its own
        const batch = batch_peek(server.io, arena.allocator(), &server.clients) catch |err| {
            return .{ .arena = arena, .messages = &.{}, .err = err };
        };

        var list = std.ArrayList(ReceivedMessage).initCapacity(arena.allocator(), batch.len) catch |err| {
            return .{ .arena = arena, .messages = &.{}, .err = err };
        };

        for (batch) |result| {
            const message = server.message_receive(arena.allocator(), result);
            list.appendAssumeCapacity(message);
        }

        return .{ .arena = arena, .messages = list.items, .err = null };
    }

    const GetEvents = struct {
        arena: *std.heap.ArenaAllocator,
        events: []const Dispatch.ServerEvent,
        err: ?error{ Canceled, OutOfMemory },

        pub fn @"error"(arena: *std.heap.ArenaAllocator, err: anytype) GetEvents {
            return .{ .arena = arena, .events = &.{}, .err = err };
        }
    };

    const GetClientMessages = struct {
        arena: *std.heap.ArenaAllocator,
        messages: []const ReceivedMessage,
        err: ?error{ OutOfMemory, Canceled },
    };

    fn batch_peek(
        io: Io,
        arena: std.mem.Allocator,
        clients: *const Clients,
    ) error{ Canceled, OutOfMemory }![]const ClientMessage {
        std.debug.assert(clients.count() > 0);

        const count = clients.count();

        const storage = try arena.alloc(Io.Operation.Storage, count);
        const buffers = try arena.alloc([]u8, count);

        for (buffers) |*buf| {
            buf.* = try arena.alloc(u8, 1);
        }

        var batch = Io.Batch.init(storage);
        var batch_i: usize = 0;
        const table = .{
            clients.known.values(),
            clients.unknown.items,
        };

        inline for (table) |entry| {
            for (entry) |client| {
                std.debug.assert(!client.closed);
                if (@TypeOf(client) == *UnknownClient or @TypeOf(client) == UnknownClient) {
                    std.debug.assert(!client.promoted_to_known);
                }

                const msg_buf = try arena.alloc(net.IncomingMessage, 1);

                const op: Io.Operation = .{
                    .net_receive = .{
                        .socket_handle = client.stream.socket.handle,
                        .message_buffer = msg_buf,
                        .data_buffer = buffers[batch_i],
                        .flags = .{ .peek = true },
                    },
                };

                _ = batch.add(op);
                batch_i += 1;
            }
        }

        std.debug.assert(batch_i == count);

        try batch.awaitAsync(io);

        var list = try std.ArrayList(Server.ClientMessage).initCapacity(arena, count);

        while (batch.next()) |completed| {
            const err, _ = completed.result.net_receive;
            const source: ClientMessage.Source = blk: {
                if (completed.index < clients.known.count()) {
                    const index = completed.index;
                    const id = clients.known.values()[index].id;
                    break :blk .{ .known = id };
                } else {
                    const index = completed.index - clients.known.count();
                    break :blk .{ .unknown = index };
                }
            };

            list.appendAssumeCapacity(.{
                .client = source,
                .err = if (err) |e| switch (e) {
                    error.Canceled => |c| return c,
                    else => |rest| rest,
                } else null,
            });
        }

        return try list.toOwnedSlice(arena);
    }
};

const ReceivedMessage = struct {
    payload: Payload,
    from: union(enum) {
        known: ClientID,
        unknown: usize,
    },

    const Payload = union(enum) {
        message: ?client_to_server.MessagePayload,
        err: ErrorSetOf(client_to_server.message_receive),
    };
};

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const utils = @import("utils");
const constants = @import("constants");
const Clients = @import("Clients.zig");
const log = std.log.scoped(.Server);
const os_tag = @import("builtin").os.tag;
const Dispatch = @import("../Dispatch.zig");
const server_to_client = @import("protocol").server_to_client;
const client_to_server = @import("protocol").client_to_server;
const ptypes = @import("protocol").types;
const ClientID = ptypes.ClientID;
const Client = Clients.Client;
const UnknownClient = Clients.UnknownClient;
