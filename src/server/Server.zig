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

    const capacity = 32;
    var arena_pool: std.ArrayList(*std.heap.ArenaAllocator) = try .initCapacity(gpa, capacity);
    for (0..capacity) |_| {
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

pub fn unknown_client_connected(server: *Server, stream: net.Stream) !void {
    errdefer stream.close(server.io);

    try server.clients.prepare_for_new_client(server.gpa);
    server.clients.new_unknown(server.gpa, stream);

    log.info("Unknown client connected", .{});
}

pub fn client_message_handle(server: *Server, arena: std.mem.Allocator, client_message: ClientMessage) error{Canceled}!void {
    return server.client_message_handle_inner(arena, client_message) catch |err| switch (err) {
        error.Canceled => |e| return e,

        error.MisbehavingUnknownClient => {
            switch (client_message.client) {
                .known => @panic("Invalid error for client"),
                .unknown => |index| {
                    const client = server.clients.unknown.items[index];
                    client.close(server.io);
                    log.err("Closing misbehaving unknown client. Expected only a register message during register phase", .{});
                },
            }
        },

        error.ClientSentInvalidClientFullID,
        error.OutOfMemoryDuringRegister,
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
            switch (client_message.client) {
                .known => |id| {
                    const client = server.clients.known.get(id) orelse return;
                    client.close(server.io);
                    log.err("Closing client {} with {}", .{ id, err });

                    try server.dispatch.window_system_put(@src(), .{ .client_disconnected = client.id });
                },
                .unknown => |index| {
                    const client = server.clients.unknown.items[index];
                    client.close(server.io);
                    log.err("Closing client unknown with {}", .{err});
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

fn client_message_handle_inner(server: *Server, arena: std.mem.Allocator, client_message: ClientMessage) !void {
    if (client_message.err) |err| {
        return err;
    }

    const timeout: Io.Timeout =
        .{ .duration = .{ .raw = .fromNanoseconds(1), .clock = .awake } };

    switch (client_message.client) {
        .known => |id| {
            const client = server.clients.known.get(id).?;
            std.debug.assert(!client.closed);

            const maybe_message = try client_to_server.message_receive(server.io, arena, client.stream, timeout);
            const message = maybe_message orelse return;

            switch (message) {
                .generate_client_full_id => {
                    try server.dispatch.server_put(@src(), .{
                        .generate_client_full_id = id,
                    });
                },
                else => {
                    const e = try server.window_system_event_from_message(client, message);
                    try server.dispatch.window_system_put(@src(), e);
                },
            }
        },
        .unknown => |index| {
            const client = server.clients.unknown.items[index];
            std.debug.assert(!client.closed);

            const maybe_message = try client_to_server.message_receive(server.io, arena, client.stream, timeout);
            const message = maybe_message orelse return;

            const register = switch (message) {
                .register => |r| r,
                else => return error.MisbehavingUnknownClient,
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

            const fingerprint =
                if (register.full_id) |full|
                    full.fingerprint
                else
                    null;

            server.clients.promote_client_to_known(server.gpa, index, id);
            log.debug("Promoted unknown client to {f}", .{id});

            var dupe: ?ptypes.ClientInfoClone =
                if (register.info) |info|
                    ptypes.ClientInfoClone.dupe(server.gpa, info) catch
                        return error.OutOfMemoryDuringRegister
                else
                    null;
            errdefer if (dupe) |*d| d.deinit(server.gpa);

            try server.dispatch.server_put(@src(), .{
                .client_registered = .{
                    .client_id = id,
                    .fingerprint = fingerprint,
                    .info = dupe,
                },
            });
        },
    }
}

pub fn handle_event(
    server: *Server,
    event: Dispatch.ServerEvent,
) error{ Canceled, WriteFailed, OutOfMemory, Exit }!void {
    switch (event) {
        .exit => {
            return error.Exit;
        },
        .generate_client_full_id => |requster| {
            const client = server.clients.known.get(requster) orelse return;
            try server.generated_full_ids.ensureUnusedCapacity(server.gpa, 1);

            const full_id = server.generate_full_id();
            server.generated_full_ids.putAssumeCapacityNoClobber(full_id, {});
            log.debug("Generated {f}", .{full_id});
            try server_to_client.message_send_json(
                server.io,
                server.gpa,
                client.stream,
                .{
                    .generated_client_full_id = .{
                        .full_id = full_id,
                    },
                },
            );
        },
        .client_registered => {
            var e = event.client_registered;
            defer if (e.info) |*info| info.deinit(server.gpa);

            const client = server.clients.known.get(e.client_id) orelse return;

            try server_to_client.message_send_json(
                server.io,
                server.gpa,
                client.stream,
                .{ .registered = .{} },
            );

            // broadcast the new client's info
            for (server.clients.known.values()) |other| {
                if (@intFromEnum(other.id) == @intFromEnum(client.id)) continue;

                try server_to_client.message_send_json(
                    server.io,
                    server.gpa,
                    other.stream,
                    .{
                        .client_registered = .{
                            .client_id = client.id,
                            .info = e.info,
                        },
                    },
                );
            }

            const dupe: ?ptypes.ClientInfoCloneManaged =
                if (e.info) |info|
                    .{ .gpa = server.gpa, .unmanaged = try .dupe(server.gpa, info) }
                else
                    null;

            try server.dispatch.window_system_put(@src(), .{
                .client_registered = .{
                    .client_id = e.client_id,
                    .info = dupe,
                },
            });
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

pub fn window_system_event_from_message(
    _: *Server,
    client: *Client,
    payload: MessagePayload,
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
        .viewport_resize,
        .cursor_shape_set,
        .sub_viewport_embed,
        .sub_viewport_rect_set,
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

pub const CheckClientTask = union(enum) {
    pub const task_count = @typeInfo(CheckClientTask).@"union".fields.len;

    accept_new_connection: ReturnType(fn_client_connected),
    check_client_messages: ReturnType(fn_check_client_messages),

    pub fn handle(task: CheckClientTask, server: *Server) !void {
        switch (task) {
            .accept_new_connection => |result| {
                const stream = result catch |err| switch (err) {
                    error.Canceled => return,
                    else => |e| {
                        log.err("accept_new_connection {}", .{e});
                        return;
                    },
                };

                server.unknown_client_connected(stream) catch |err| switch (err) {
                    error.OutOfMemory => |e| {
                        log.err("accept_new_connection {}", .{e});
                        return;
                    },
                };
            },
            .check_client_messages => |result| {
                defer server.arena_release(result.arena);

                if (result.err) |e| switch (e) {
                    error.Canceled, error.OutOfMemory => return,
                };

                for (result.messages) |message| {
                    server.client_message_handle(result.arena.allocator(), message) catch return;
                }

                server.clients.remove_closed_known_clients();
                server.clients.remove_promoted_or_closed_unknown_clients();
            },
        }
    }

    const CheckClientMessage = struct {
        const Error = error{ Canceled, OutOfMemory };

        arena: *std.heap.ArenaAllocator,
        messages: []const Server.ClientMessage,
        err: ?Error,

        pub fn @"error"(
            arena: *std.heap.ArenaAllocator,
            err: anytype,
        ) CheckClientMessage {
            return .{ .arena = arena, .messages = &.{}, .err = err };
        }
    };

    fn fn_check_client_messages(
        io: Io,
        arena_instance: *std.heap.ArenaAllocator,
        clients: *const Clients,
    ) CheckClientMessage {
        std.debug.assert(clients.count() > 0);

        const arena = arena_instance.allocator();
        const count = clients.count();

        const storage = arena.alloc(Io.Operation.Storage, count) catch |err|
            return .@"error"(arena_instance, err);
        const buffers = arena.alloc([]u8, count) catch |err|
            return .@"error"(arena_instance, err);

        for (buffers) |*buf| {
            buf.* = arena.alloc(u8, 1) catch |err|
                return .@"error"(arena_instance, err);
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

                // len must be 1 for recv_fd to work
                const msg_buf = arena.alloc(net.IncomingMessage, 1) catch |err| return .@"error"(arena_instance, err);

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

        batch.awaitAsync(io) catch |err| switch (err) {
            error.Canceled => |e| return .@"error"(arena_instance, e),
        };

        var list = std.ArrayList(Server.ClientMessage).initCapacity(arena, count) catch |err|
            return .@"error"(arena_instance, err);

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
                    error.Canceled => |canceled| return .@"error"(arena_instance, canceled),
                    else => |rest| rest,
                } else null,
            });
        }

        return .{
            .arena = arena_instance,
            .messages = list.toOwnedSlice(arena) catch |err| return .@"error"(arena_instance, err),
            .err = null,
        };
    }

    fn fn_client_connected(io: Io, server: *net.Server) net.Server.AcceptError!net.Stream {
        return server.accept(io);
    }
};

pub const Task = union(enum) {
    const Tag = std.meta.Tag(Task);

    check_clients: ReturnType(fn_check_clients),
    check_events: ReturnType(fn_check_events),

    pub fn handle(task: Task, server: *Server) !void {
        switch (task) {
            .check_clients => |err_results| {
                const results = try err_results;
                for (results) |maybe_result| {
                    const result = maybe_result orelse continue;
                    try result.handle(server);
                }
            },
            .check_events => |err_event| {
                const event = try err_event;
                server.handle_event(event) catch |err| switch (err) {
                    error.Exit => return,
                    error.Canceled => |e| return e,
                    else => |e| log.err("Server: {}", .{e}),
                };
            },
        }
    }

    pub fn fn_check_events(dispatch: *Dispatch) error{Canceled}!Dispatch.ServerEvent {
        return try dispatch.server_get();
    }

    pub fn fn_check_clients(server: *Server) error{Canceled}![CheckClientTask.task_count]?CheckClientTask {
        var select_buffer: [CheckClientTask.task_count]CheckClientTask = undefined;
        var select: Io.Select(CheckClientTask) = .init(server.io, &select_buffer);

        select.concurrent(
            .accept_new_connection,
            CheckClientTask.fn_client_connected,
            .{ server.io, &server.server },
        ) catch @panic("ConcurrencyUnavailable");

        if (server.clients.count() > 0) {
            select.concurrent(
                .check_client_messages,
                CheckClientTask.fn_check_client_messages,
                .{ server.io, server.arena_acquire(), &server.clients },
            ) catch @panic("ConcurrencyUnavailable");
        }

        var result_buffer: [CheckClientTask.task_count]?CheckClientTask = @splat(null);
        var result: std.ArrayList(?CheckClientTask) = .initBuffer(&result_buffer);

        errdefer {
            while (select.cancel()) |canceled| {
                canceled.handle(server) catch {};
            }
        }

        const selected = try select.await();

        errdefer comptime unreachable;

        result.appendBounded(selected) catch unreachable;
        if (select.cancel()) |task| {
            result.appendBounded(task) catch unreachable;
        }
        std.debug.assert(select.cancel() == null);

        return result_buffer;
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
const MessagePayload = client_to_server.MessagePayload;
const Dispatch = @import("../Dispatch.zig");
const server_to_client = @import("protocol").server_to_client;
const client_to_server = @import("protocol").client_to_server;
const ptypes = @import("protocol").types;
const ClientID = ptypes.ClientID;
const Client = Clients.Client;
const UnknownClient = Clients.UnknownClient;
