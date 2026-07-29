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
        if (!client.closed) {
            client.close(server.io);
        }
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
            log.err("Could not delete unix socket {s} error {}", .{ server.unix_path, e });
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
            log.debug("Removed closed client {}", .{client.id});
            client.destroy(server.gpa);
            _ = server.clients.map.orderedRemove(client.id);
        }
    }
}

pub fn client_connected(server: *Server, stream: net.Stream) !void {
    std.debug.assert(!server.task_master.is_running(.client_connected));

    try server.clients.map.ensureUnusedCapacity(server.gpa, 1);
    errdefer stream.close(server.io);

    const id = server.clients.new_id();
    const client: *Client = try .create(server.gpa, id, stream);

    server.clients.map.putAssumeCapacity(id, client);
    server.dispatch.window_system_put(.{ .client_connected = id }) catch |err| switch (err) {
        error.Canceled => return err,
    };
}

pub fn client_message_handle(server: *Server, arena: std.mem.Allocator, client_message: ClientMessage) error{Canceled}!void {
    std.debug.assert(!server.task_master.is_running(.client_has_message));

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
            log.err("Closing client {} with error {}\n", .{ client_message.client_id, err });

            try server.dispatch.window_system_put(.{ .client_disconnected = client.id });
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

    // Will be removed later
    if (client.closed) {
        return;
    }

    if (client_message.err) |err| {
        return err;
    }

    const timeout: Io.Timeout =
        .{ .duration = .{ .raw = .fromMilliseconds(1), .clock = .awake } };

    const maybe_message = try client_to_server.message_receive(server.io, arena, client, timeout);

    if (maybe_message) |message| {
        if (server.window_system_event_from_message(client, message)) |e| {
            try server.dispatch.window_system_put(e);
            log.debug("Server dispatched event {}", .{e});
        } else |err| {
            log.err("{}", .{err});
        }
    }
}

pub fn handle_event(
    server: *Server,
    event: Dispatch.ServerEvent,
) error{ Canceled, WriteFailed, OutOfMemory, Exit }!void {
    std.debug.assert(!server.task_master.is_running(.server_has_event));

    switch (event) {
        .exit => {
            return error.Exit;
        },
        .viewport_resize => |e| {
            const client = server.clients.map.get(e.client_id) orelse return;

            try server_to_client.message_send_json(
                server.io,
                server.gpa,
                client.stream,
                .{ .viewport_resize = e.resize },
            );
        },
        .buffer_released => |e| {
            const client = server.clients.map.get(e.client_id) orelse return;

            try server_to_client.message_send_json(
                server.io,
                server.gpa,
                client.stream,
                .{
                    .buffer_released = .{
                        .viewport_id = e.viewport_id,
                        .buffer_id = e.buffer_id,
                    },
                },
            );
        },
        .buffer_destroyed => |e| {
            const client = server.clients.map.get(e.client_id) orelse return;

            try server_to_client.message_send_json(
                server.io,
                server.gpa,
                client.stream,
                .{
                    .buffer_destroyed = .{ .buffer_id = e.buffer_id },
                },
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

            const expr = switch (tag) {
                .buffer_create_cpu_with_fd => Dispatch.WindowSystemEvent.BufferCreateCpuWithFd{
                    .client_id = client.id,
                    .buffer_id = msg.id,
                    .fd = msg.fd,
                    .width = msg.width,
                    .height = msg.height,
                    .format = msg.format,
                },
                .buffer_create_gpu_with_fds => Dispatch.WindowSystemEvent.BufferCreateGpuWithFds{
                    .client_id = client.id,
                    .buffer_id = msg.id,
                    .fds = msg.fds,
                    .width = msg.width,
                    .height = msg.height,
                    .format = msg.format,
                    .gbm_bo_modifier = msg.gbm_bo_modifier,
                },
                else => comptime unreachable,
            };

            return @unionInit(Dispatch.WindowSystemEvent, @tagName(tag), expr);
        },

        .buffer_present => |msg| {
            return .{
                .buffer_present = .{
                    .client_id = client.id,
                    .viewport_id = msg.viewport_id,
                    .buffer_id = msg.buffer_id,
                },
            };
        },
        .buffer_present_with_sync => |msg| {
            return .{
                .buffer_present_with_sync = .{
                    .client_id = client.id,
                    .viewport_id = msg.viewport_id,
                    .buffer_id = msg.buffer_id,
                    .acquire_point = msg.acquire_point,
                    .release_point = msg.release_point,
                },
            };
        },
        .buffer_destroy => |msg| {
            return .{
                .buffer_destroy = .{
                    .client_id = client.id,
                    .buffer_id = msg.buffer_id,
                },
            };
        },
        .window_create => |msg| {
            return .{
                .window_create = .{
                    .client_id = client.id,
                    .viewport_id = msg.viewport_id,
                    .width = msg.width,
                    .height = msg.height,
                    .create_sync_timeline = msg.create_sync_timeline,
                },
            };
        },
        .viewport_resize => |msg| {
            return .{
                .viewport_resize = .{
                    .client_id = client.id,
                    .viewport_id = msg.viewport_id,
                    .width = msg.width,
                    .height = msg.height,
                },
            };
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
    running: std.EnumSet(Task.Tag),
    select_buffer: []Task,
    select: Io.Select(Task),

    pub fn create(io: Io, gpa: std.mem.Allocator) !*TaskMaster {
        const tm = try gpa.create(TaskMaster);

        const len = @typeInfo(Task).@"union".fields.len;
        const buffer = try gpa.alloc(Task, len);
        tm.* = .{
            .running = .empty,
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
                    // FIXME: Memory leak when an error occurs
                    const r = result catch continue;
                    server.arena_release(r.arena);
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
        tm.running.remove(selected);
        return selected;
    }

    pub fn start(tm: *TaskMaster, server: *Server, tag: Task.Tag) void {
        std.debug.assert(!tm.is_running(tag));
        tm.running.insert(tag);

        switch (tag) {
            .client_connected => {
                tm.select.concurrent(
                    .client_connected,
                    Task.fn_client_connected,
                    .{ server.io, &server.server },
                ) catch @panic("ConcurrencyUnavailable");
            },

            .client_has_message => {
                server.remove_closed_clients();

                const map_clone = server.clients.map_clone(server.gpa) catch |err| switch (err) {
                    error.OutOfMemory => @panic("OOM"),
                };

                tm.select.concurrent(
                    .client_has_message,
                    Task.fn_client_has_message,
                    .{ server.io, server.arena_acquire(), map_clone },
                ) catch @panic("ConcurrencyUnavailable");
            },

            .server_has_event => {
                tm.select.concurrent(
                    .server_has_event,
                    Task.fn_server_has_event,
                    .{server.dispatch},
                ) catch @panic("ConcurrencyUnavailable");
            },
        }
    }

    pub fn handle(tm: *TaskMaster, server: *Server, task: Task) error{ Canceled, Exit }!void {
        std.debug.assert(!tm.is_running(task));

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
                const r = result catch |err| switch (err) {
                    error.Canceled => |e| return e,
                    error.OutOfMemory => return,
                    error.ConcurrencyUnavailable => @panic("ConcurrencyUnavailable"),
                };
                defer server.arena_release(r.arena);

                for (r.messages) |message| {
                    try server.client_message_handle(r.arena.allocator(), message);
                }
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

    fn is_running(tm: *TaskMaster, tag: Task.Tag) bool {
        return tm.running.contains(tag);
    }
};

pub const Task = union(enum) {
    const Tag = std.meta.Tag(Task);

    client_connected: ReturnType(fn_client_connected),
    client_has_message: ReturnType(fn_client_has_message),
    server_has_event: ReturnType(fn_server_has_event),

    fn fn_client_has_message(
        io: Io,
        arena_instance: *std.heap.ArenaAllocator,
        clone: Clients.MapClone,
    ) error{ Canceled, ConcurrencyUnavailable, OutOfMemory }!struct { arena: *std.heap.ArenaAllocator, messages: []const Server.ClientMessage } {
        defer clone.deinit();

        if (clone.map.count() == 0) {
            return .{ .arena = arena_instance, .messages = &.{} };
        }

        const arena = arena_instance.allocator();
        const count = clone.map.count();

        const storage = try arena.alloc(Io.Operation.Storage, count);
        const buffers = try arena.alloc([]u8, count);
        for (buffers) |*buf| {
            // TODO: calculate the maximum size
            buf.* = try arena.alloc(u8, 4096);
        }

        var batch = Io.Batch.init(storage);
        for (clone.map.values(), 0..) |client, i| {
            if (client.closed) continue;

            // len must be 1 for recv_fd to work
            const msg_buf = try arena.alloc(net.IncomingMessage, 1);

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
            else => |e| return e,
        };

        var list: std.ArrayList(Server.ClientMessage) = try .initCapacity(arena, count);
        while (batch.next()) |completed| {
            const err, const len = completed.result.net_receive;
            std.debug.assert(len == 1);
            const id = clone.map.values()[completed.index].id;
            list.appendAssumeCapacity(.{
                .client_id = id,
                .err = if (err) |e| switch (e) {
                    error.Canceled => |canceled| return canceled,
                    else => |rest| rest,
                } else null,
            });
        }

        return .{ .arena = arena_instance, .messages = try list.toOwnedSlice(arena) };
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
const constants = @import("../constants.zig");
const utils = @import("utils.zig");
const Clients = @import("Clients.zig");
const Client = @import("Client.zig");
const log = std.log.scoped(.Server);
const os_tag = @import("builtin").os.tag;
const MessagePayload = @import("../protocol/client_to_server.zig").MessagePayload;
const Dispatch = @import("../Dispatch.zig");
const server_to_client = @import("../protocol/server_to_client.zig");
const client_to_server = @import("../protocol/client_to_server.zig");
const ClientID = Clients.ClientID;
