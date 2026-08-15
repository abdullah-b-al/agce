const Server = @This();

io: Io,
gpa: std.mem.Allocator,
dispatch: *Dispatch,

unix_path: []const u8,
server: net.Server,
clients: Clients,
arena_pool: std.ArrayList(*std.heap.ArenaAllocator),

task_master: *TaskMaster,

pub fn create(
    io: Io,
    environ: *const std.process.Environ.Map,
    gpa: std.mem.Allocator,
    dispatch: *Dispatch,
) !*Server {
    const server = try gpa.create(Server);
    errdefer gpa.destroy(server);

    var path_buf: [utils.socket_max_path]u8 = undefined;
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

    const task_master: *TaskMaster = try .create(io, gpa);
    server.* = .{
        .io = io,
        .gpa = gpa,
        .dispatch = dispatch,

        .unix_path = unix_path,
        .server = net_server,
        .clients = .init,
        .arena_pool = arena_pool,
        .task_master = task_master,
    };
    return server;
}

pub fn destroy(server: *Server) void {
    server.task_master.destroy(server);

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
    std.debug.assert(!server.task_master.running(.client_connected));

    try server.clients.map.ensureUnusedCapacity(server.gpa, 1);
    errdefer stream.close(server.io);

    const id = server.clients.new_id();
    const client: *Client = try .create(server.gpa, id, stream);

    server.clients.map.putAssumeCapacity(id, client);
    server.dispatch.window_system_put(@src(), .{ .client_connected = id }) catch |err| switch (err) {
        error.Canceled => return err,
    };
}

pub fn client_message_handle(server: *Server, arena: std.mem.Allocator, client_message: ClientMessage) error{Canceled}!void {
    std.debug.assert(!server.task_master.running(.client_has_message));

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
    std.debug.assert(!server.task_master.running(.server_has_event));

    switch (event) {
        .exit => {
            return error.Exit;
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

pub fn window_system_event_from_message(_: *Server, client: *Client, payload: MessagePayload) !Dispatch.WindowSystemEvent {
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

        inline .buffer_present,
        .buffer_present_with_sync,
        .buffer_destroy,
        .window_create,
        .viewport_resize,
        .cursor_shape_set,
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

pub const TaskMaster = struct {
    running_tasks: std.EnumSet(Task.Tag),
    select_buffer: []Task,
    select: Io.Select(Task),

    pub fn create(io: Io, gpa: std.mem.Allocator) !*TaskMaster {
        const tm = try gpa.create(TaskMaster);

        const len = @typeInfo(Task).@"union".fields.len;
        const buffer = try gpa.alloc(Task, len);
        tm.* = .{
            .running_tasks = .empty,
            .select = .init(io, buffer),
            .select_buffer = buffer,
        };
        return tm;
    }

    pub fn destroy(tm: *TaskMaster, server: *Server) void {
        while (tm.select.cancel()) |task| {
            switch (task) {
                .client_connected => |result| {
                    const stream = result catch continue;
                    stream.close(server.io);
                },
                .client_has_message => |result| {
                    server.arena_release(result.arena);
                },
                .server_has_event => {
                    // TODO: Figure out if there is a need to do anything here
                },
            }
        }

        server.gpa.free(tm.select_buffer);
        server.gpa.destroy(tm);
    }

    pub fn await(tm: *TaskMaster) !Task {
        const selected = try tm.select.await();
        tm.running_tasks.remove(selected);
        return selected;
    }

    pub fn start(tm: *TaskMaster, server: *Server, tag: Task.Tag) void {
        branch: switch (tag) {
            .client_connected => |t| {
                tm.running_set(t);
                tm.select.concurrent(
                    .client_connected,
                    Task.fn_client_connected,
                    .{ server.io, &server.server },
                ) catch @panic("ConcurrencyUnavailable");

                continue :branch .client_has_message;
            },

            .client_has_message => |t| {
                if (!tm.running(t) and server.clients.map.count() > 0) {
                    const map_clone = server.clients.map_clone(server.gpa) catch |err| switch (err) {
                        error.OutOfMemory => @panic("OOM"),
                    };

                    tm.running_set(t);
                    tm.select.concurrent(
                        .client_has_message,
                        Task.fn_client_has_message,
                        .{ server.io, server.arena_acquire(), map_clone },
                    ) catch @panic("ConcurrencyUnavailable");
                }
            },

            .server_has_event => |t| {
                tm.running_set(t);
                tm.select.concurrent(
                    .server_has_event,
                    Task.fn_server_has_event,
                    .{server.dispatch},
                ) catch @panic("ConcurrencyUnavailable");
            },
        }
    }

    pub fn handle(tm: *TaskMaster, server: *Server, task: Task) error{ Canceled, Exit }!void {
        std.debug.assert(!tm.running(task));

        switch (task) {
            .client_connected => |result| {
                const stream = result catch |err| switch (err) {
                    error.Canceled => |e| return e,
                    else => |e| {
                        log.err("Server: {}", .{e});
                        return;
                    },
                };

                server.client_connected(stream) catch |err| switch (err) {
                    error.Canceled => |e| return e,
                    error.OutOfMemory => |e| {
                        log.err("Server: {}", .{e});
                        return;
                    },
                };
            },

            .client_has_message => |result| {
                if (result.err) |e| switch (e) {
                    error.Canceled => |canceled| return canceled,
                    error.OutOfMemory => return,
                    error.ConcurrencyUnavailable => @panic("ConcurrencyUnavailable"),
                };
                defer server.arena_release(result.arena);

                for (result.messages) |message| {
                    try server.client_message_handle(result.arena.allocator(), message);
                }

                server.remove_closed_clients();
            },

            .server_has_event => |result| {
                const event = try result;
                server.handle_event(event) catch |err| switch (err) {
                    error.Exit => |e| return e,
                    else => |e| log.err("Server: {}", .{e}),
                };
            },
        }
    }

    fn running(tm: *TaskMaster, tag: Task.Tag) bool {
        return tm.running_tasks.contains(tag);
    }

    fn running_set(tm: *TaskMaster, tag: Task.Tag) void {
        std.debug.assert(!tm.running(tag));
        tm.running_tasks.insert(tag);
    }
};

pub const Task = union(enum) {
    const Tag = std.meta.Tag(Task);

    client_connected: ReturnType(fn_client_connected),
    client_has_message: ReturnType(fn_client_has_message),
    server_has_event: ReturnType(fn_server_has_event),

    const ClientHasMessage = struct {
        const Error = error{ Canceled, ConcurrencyUnavailable, OutOfMemory };

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
        clone: Clients.MapClone,
    ) ClientHasMessage {
        std.debug.assert(clone.map.count() > 0);
        defer clone.deinit();

        const arena = arena_instance.allocator();
        const count = clone.map.count();

        const storage = arena.alloc(Io.Operation.Storage, count) catch |err|
            return .@"error"(arena_instance, err);
        const buffers = arena.alloc([]u8, count) catch |err|
            return .@"error"(arena_instance, err);

        for (buffers) |*buf| {
            // TODO: calculate the maximum size
            buf.* = arena.alloc(u8, 4096) catch |err|
                return .@"error"(arena_instance, err);
        }

        var batch = Io.Batch.init(storage);
        for (clone.map.values(), 0..) |client, i| {
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

        batch.awaitConcurrent(io, .none) catch |err| switch (err) {
            error.Timeout => unreachable,
            else => |e| return .@"error"(arena_instance, e),
        };

        var list = std.ArrayList(Server.ClientMessage).initCapacity(arena, count) catch |err|
            return .@"error"(arena_instance, err);

        while (batch.next()) |completed| {
            const err, _ = completed.result.net_receive;
            const id = clone.map.values()[completed.index].id;
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

    fn fn_server_has_event(dispatch: *Dispatch) error{Canceled}!Dispatch.ServerEvent {
        return try dispatch.server_get();
    }
};

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const utils = @import("utils");
const Clients = @import("Clients.zig");
const log = std.log.scoped(.Server);
const os_tag = @import("builtin").os.tag;
const MessagePayload = client_to_server.MessagePayload;
const Dispatch = @import("../Dispatch.zig");
const server_to_client = @import("protocol").server_to_client;
const client_to_server = @import("protocol").client_to_server;
const ClientID = Clients.ClientID;
const Client = Clients.Client;
