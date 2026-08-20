const Server = @This();

io: Io,
gpa: std.mem.Allocator,
dispatch: *Dispatch,

unix_path: []const u8,
server: net.Server,
clients: Clients,
arena_pool: std.ArrayList(*std.heap.ArenaAllocator),

pub fn create(
    io: Io,
    environ: *const std.process.Environ.Map,
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

        .unix_path = unix_path,
        .server = net_server,
        .clients = .init,
        .arena_pool = arena_pool,
    };
    return server;
}

pub fn destroy(server: *Server) void {
    for (server.clients.map.values()) |client| {
        client.close(server.io);
        server.gpa.destroy(client);
    }
    server.clients.map.deinit(server.gpa);

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

pub fn remove_closed_clients(server: *Server) void {
    var i = server.clients.map.count();
    while (i > 0) {
        i -= 1;
        const client = server.clients.map.values()[i];
        if (client.closed) {
            const id = client.id;
            log.debug("Removed closed client {f}", .{id});
            client.destroy(server.gpa);
            _ = server.clients.map.orderedRemove(id);
        }
    }
}

pub fn client_connected(server: *Server, stream: net.Stream) !void {
    try server.clients.map.ensureUnusedCapacity(server.gpa, 1);
    errdefer stream.close(server.io);

    const id = server.clients.new_id();
    const client: *Client = try .create(server.gpa, id, stream);
    log.info("Client connected {}", .{id});

    server.clients.map.putAssumeCapacity(id, client);
    server.dispatch.window_system_put(@src(), .{ .client_connected = id }) catch |err| switch (err) {
        error.Canceled => return err,
    };
}

pub fn client_message_handle(server: *Server, arena: std.mem.Allocator, client_message: ClientMessage) error{Canceled}!void {
    server.client_message_handle_inner(arena, client_message) catch |err| switch (err) {
        error.Canceled => |e| return e,

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
            const client = server.clients.map.get(client_message.client_id) orelse return;
            client.close(server.io);
            log.err("Closing client {} with error {}", .{ client_message.client_id, err });

            try server.dispatch.window_system_put(@src(), .{ .client_disconnected = client.id });
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
    const id = client_message.client_id;
    const client = server.clients.map.get(id) orelse return;
    std.debug.assert(!client.closed);

    if (client_message.err) |err| {
        return err;
    }

    const timeout: Io.Timeout =
        .{ .duration = .{ .raw = .fromMilliseconds(1), .clock = .awake } };

    const maybe_message = try client_to_server.message_receive(server.io, arena, client.stream, timeout);

    if (maybe_message) |message| {
        if (server.window_system_event_from_message(client, message)) |e| {
            try server.dispatch.window_system_put(@src(), e);
            // log.debug("Server dispatched event {}", .{e});
        } else |err| {
            log.err("{}", .{err});
        }
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
        .client_info => {
            var msg = event.client_info;
            defer msg.managed.deinit();

            for (server.clients.map.values()) |client| {
                if (@intFromEnum(client.id) == @intFromEnum(msg.client_id)) continue;

                try server_to_client.message_send_json(
                    server.io,
                    server.gpa,
                    client.stream,
                    .{
                        .client_info = .{
                            .client_id = msg.client_id,
                            .info = msg.managed.unmanaged,
                        },
                    },
                );
            }
        },
        inline else => |e, tag| {
            const client = server.clients.map.get(e.client_id) orelse return;

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

pub fn window_system_event_from_message(server: *Server, client: *Client, payload: MessagePayload) !Dispatch.WindowSystemEvent {
    switch (payload) {
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

        .client_info_set => |msg| {
            return .{
                .client_info_set = .{
                    .client_id = client.id,
                    .payload = .{
                        .gpa = server.gpa,
                        .unmanaged = try .dupe(server.gpa, msg),
                    },
                },
            };
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

pub const ClientMessage = struct {
    client_id: ClientID,
    err: ?Io.Operation.NetReceive.Error,
};

fn ReturnType(comptime func: anytype) type {
    return @typeInfo(@TypeOf(func)).@"fn".return_type.?;
}

pub const CheckClientTask = union(enum) {
    pub const task_count = @typeInfo(CheckClientTask).@"union".fields.len;

    client_connected: ReturnType(fn_client_connected),
    client_has_message: ReturnType(fn_client_has_message),

    pub fn handle(task: CheckClientTask, server: *Server) !void {
        switch (task) {
            .client_connected => |result| {
                const stream = result catch |err| switch (err) {
                    error.Canceled => return,
                    else => |e| {
                        log.err("Server: {}", .{e});
                        return;
                    },
                };

                server.client_connected(stream) catch |err| switch (err) {
                    error.Canceled => return,
                    error.OutOfMemory => |e| {
                        log.err("{}", .{e});
                        return;
                    },
                };
            },
            .client_has_message => |result| {
                defer server.arena_release(result.arena);

                if (result.err) |e| switch (e) {
                    error.Canceled, error.OutOfMemory => return,
                };

                for (result.messages) |message| {
                    server.client_message_handle(result.arena.allocator(), message) catch return;
                }

                server.remove_closed_clients();
            },
        }
    }

    const ClientHasMessage = struct {
        const Error = error{ Canceled, OutOfMemory };

        arena: *std.heap.ArenaAllocator,
        messages: []const Server.ClientMessage,
        err: ?Error,

        pub fn @"error"(
            arena: *std.heap.ArenaAllocator,
            err: anytype,
        ) ClientHasMessage {
            return .{ .arena = arena, .messages = &.{}, .err = err };
        }
    };

    fn fn_client_has_message(
        io: Io,
        arena_instance: *std.heap.ArenaAllocator,
        clients: *const Clients,
    ) ClientHasMessage {
        std.debug.assert(clients.map.count() > 0);

        const arena = arena_instance.allocator();
        const count = clients.map.count();

        const storage = arena.alloc(Io.Operation.Storage, count) catch |err|
            return .@"error"(arena_instance, err);
        const buffers = arena.alloc([]u8, count) catch |err|
            return .@"error"(arena_instance, err);

        for (buffers) |*buf| {
            buf.* = arena.alloc(u8, 1) catch |err|
                return .@"error"(arena_instance, err);
        }

        var batch = Io.Batch.init(storage);
        for (clients.map.values(), 0..) |client, i| {
            std.debug.assert(!client.closed);

            // len must be 1 for recv_fd to work
            const msg_buf = arena.alloc(net.IncomingMessage, 1) catch |err| return .@"error"(arena_instance, err);

            const op: Io.Operation = .{
                .net_receive = .{
                    .socket_handle = client.stream.socket.handle,
                    .message_buffer = msg_buf,
                    .data_buffer = buffers[i],
                    .flags = .{ .peek = true },
                },
            };

            _ = batch.add(op);
        }

        batch.awaitAsync(io) catch |err| switch (err) {
            error.Canceled => |e| return .@"error"(arena_instance, e),
        };

        var list = std.ArrayList(Server.ClientMessage).initCapacity(arena, count) catch |err|
            return .@"error"(arena_instance, err);

        while (batch.next()) |completed| {
            const err, _ = completed.result.net_receive;
            const id = clients.map.values()[completed.index].id;
            list.appendAssumeCapacity(.{
                .client_id = id,
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
            .client_connected,
            CheckClientTask.fn_client_connected,
            .{ server.io, &server.server },
        ) catch @panic("ConcurrencyUnavailable");

        if (server.clients.map.count() > 0) {
            select.concurrent(
                .client_has_message,
                CheckClientTask.fn_client_has_message,
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
