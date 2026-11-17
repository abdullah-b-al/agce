const Server = @This();

io: Io,
gpa: std.mem.Allocator,

rand: std.Random.DefaultPrng,
unix_path: []const u8,
server: zio.net.Server,
clients: Clients,

io_queue_buffer: []Compositor.EventFromServer,
io_queue: *Io.Queue(Compositor.EventFromServer),

compositor_events: std.ArrayList(Compositor.EventFromServer),

win32_socket_event: Win32SocketEvent,

pub fn create(
    io: Io,
    environ_map: *const std.process.Environ.Map,
    gpa: std.mem.Allocator,
    socket_owner: UnixSocketOwner,
) !*Server {
    const server = try gpa.create(Server);
    errdefer gpa.destroy(server);

    const io_queue_buffer = try gpa.alloc(Compositor.EventFromServer, 128);
    errdefer gpa.free(io_queue_buffer);

    const io_queue = try gpa.create(Io.Queue(Compositor.EventFromServer));
    errdefer gpa.destroy(io_queue);

    io_queue.* = .init(io_queue_buffer);

    var rand: std.Random.DefaultPrng = .init(
        @bitCast(Io.Timestamp.now(io, .real).toMilliseconds()),
    );

    const unix_path = if (environ_map.get(constants.env_agce_socket_path)) |path| blk: {
        break :blk try gpa.dupe(u8, path);
    } else blk: {
        const runtime_path = try known_folders.getPath(io, gpa, environ_map, .runtime) orelse
            return error.CouldNotGetRuntimeDirPath;
        defer gpa.free(runtime_path);

        const runtime_dir = Io.Dir.openDirAbsolute(io, runtime_path, .{}) catch |err| {
            log.err("{}", .{err});
            return error.CouldNotOpenRuntimeDir;
        };
        defer runtime_dir.close(io);

        const agce_dir = runtime_dir.createDirPathOpen(io, constants.socket_dir_name, .{}) catch |err| {
            log.err("{}", .{err});
            return error.CouldNotOpenOrCreateAgceSocketDir;
        };
        defer agce_dir.close(io);

        if (socket_owner == .embedded) {
            agce_dir.createDir(io, socket_owner.embedded, .default_dir) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => {
                    log.err("{}", .{err});
                    return error.CouldNotCreateEmbeddedSocketDir;
                },
            };
        }

        var random_digits: [5]u8 = undefined;
        for (&random_digits) |*d| d.* = rand.random().intRangeAtMost(u8, '0', '9');

        switch (socket_owner) {
            .mux => break :blk try std.fs.path.join(gpa, &.{
                runtime_path,
                constants.socket_dir_name,
                constants.socket_mux_file_name,
            }),
            .embedded => |embedded| break :blk try std.fs.path.join(gpa, &.{
                runtime_path,
                constants.socket_dir_name,
                embedded,
                random_digits ++ "." ++ constants.socket_extension,
            }),
        }
    };
    errdefer gpa.free(unix_path);

    const address = zio.net.UnixAddress.init(unix_path) catch |err| switch (err) {
        error.NameTooLong => return error.UnixSocketPathTooLong,
    };
    const net_server = address.listen(.{}) catch |err| {
        log.err("Failed to listen to socket {s} {}", .{ unix_path, err });
        return err;
    };
    log.info("Created server on {s}", .{unix_path});

    const socket_event = try Win32SocketEvent.create(net_server.socket, .accept);

    server.* = .{
        .io = io,
        .gpa = gpa,
        .rand = rand,

        .unix_path = unix_path,
        .server = net_server,
        .clients = .init,
        .io_queue_buffer = io_queue_buffer,
        .io_queue = io_queue,
        .compositor_events = .empty,

        .win32_socket_event = socket_event,
    };
    return server;
}

pub fn destroy(server: *Server) void {
    server.clients.deinit(server.io, server.gpa);

    server.win32_socket_event.close();
    server.server.shutdown(.both) catch {};
    const err =
        if (std.fs.path.isAbsolute(server.unix_path))
            Io.Dir.deleteFileAbsolute(server.io, server.unix_path)
        else
            Io.Dir.cwd().deleteFile(server.io, server.unix_path);

    err catch |e| switch (e) {
        error.Canceled => {},
        else => {
            log.err("Could not delete unix socket {s} {}", .{ server.unix_path, e });
        },
    };

    server.compositor_events.deinit(server.gpa);
    server.gpa.free(server.unix_path);
    server.gpa.free(server.io_queue_buffer);
    server.gpa.destroy(server.io_queue);
    server.gpa.destroy(server);
}

pub fn accept(server: *Server) !void {
    while (true) {
        const stream = server.server.accept(.{ .timeout = .fromNanoseconds(0) }) catch |err|
            switch (err) {
                error.Timeout => return,
                else => |e| return e,
            };
        errdefer stream.close();

        try server.clients.new_unknown(server.gpa, stream);

        log.info("Unknown client connected", .{});
    }
}

pub fn handle_events(server: *Server, com: *Compositor) error{OutOfMemory}!void {
    while (com.server_events.peek()) |node| {
        server.handle_event(node.event) catch |err| {
            switch (err) {
                error.OutOfMemory => |e| {
                    return e;
                },

                // TODO: Do not close the client when sending handles fails
                error.FailedToSendFds,
                error.FailedToSendHandle,
                error.ConnectionClosed,
                => |e| {
                    server.mark_for_closing_client_uuid_with(node.event.client_uuid(), e);
                },
            }
        };

        const popped = com.server_events.pop().?;
        std.debug.assert(popped == node);
        com.server_events.destroy(node);
    }
}

pub fn process_incoming_messages(server: *Server) error{OutOfMemory}!void {
    // Mark closed clients first to make sure they're removed by the end of tick()
    for (server.clients.list.items, 0..) |client, i| {
        if (client.messaging_state == .close) {
            server.mark_for_closing_client_with(i, error.ConnectionResetByPeer);
            client.messaging_state = .none;
        }
    }

    for (server.clients.list.items, 0..) |client, i| {
        const source: MessageSource = switch (client.kind) {
            .unknown => .{ .unknown = i },
            .remote => |id| .{ .remote = id },
            .local => |id| .{ .local = id },
        };

        branch: switch (client.messaging_state) {
            .close => unreachable,
            .none => continue,
            .read => {
                try client.connection.read_and_parse_all(server.io, server.gpa, source);
                continue :branch .handle_messages;
            },
            .handle_messages => {
                client.messaging_state = .handle_messages;

                try maybe_oom();
                try server.compositor_events.ensureTotalCapacityPrecise(
                    server.gpa,
                    client.connection.messages_parsed.items.len * 2,
                );

                errdefer comptime unreachable;

                while (client.connection.messages_parsed.pop()) |const_parsed| {
                    var parsed = const_parsed;
                    server.handle_message(.{
                        .payload = parsed.payload,
                        .from = parsed.from,
                    });
                    parsed.deinit(server.gpa);
                }

                client.messaging_state = .none;
            },
        }
    }
}

pub fn connect_local(server: *Server) !zio.net.Stream {
    return try server.server.socket.address.connect(.{ .timeout = .none });
}

fn handle_message(server: *Server, message: ReceivedMessage) void {
    switch (message.from) {
        .remote => server.handle_message_from_remote(message),
        .local => server.handle_message_from_local(message),

        .unknown => |index| {
            server.handle_message_from_unknown(message) catch |err| switch (err) {
                error.MisbehavingUnknownClient,
                error.OutOfMemoryDuringRegister,
                error.ClientUUIDAlreadyExists,
                error.ConnectionClosed,
                => |e| {
                    server.mark_for_closing_unknown_client_with(index, e);
                },
            };
        },
    }
}

pub fn handle_event(
    server: *Server,
    event: Event,
) error{
    OutOfMemory,
    FailedToSendFds,
    FailedToSendHandle,
    ConnectionClosed,
}!void {
    try maybe_oom();

    switch (event) {
        .buffer_created_cpu => |e| {
            defer if (constants.os_supports_fd and e.payload == .success) {
                e.payload.success.handle.close();
            };

            const client = server.clients.get_remote(e.client_uuid) orelse return;
            client.connection.send_buffer_created_cpu(
                server.io,
                server.gpa,
                e.payload,
            ) catch |err| {
                if (os == .windows) {
                    return switch (err) {
                        error.Win32OpenProcessFailed,
                        error.DuplicateHandleFailed,
                        => error.FailedToSendHandle,
                        else => return error.ConnectionClosed,
                    };
                } else return error.ConnectionClosed;
            };
        },
        .buffer_created_gbm_bo => |e| {
            if (!constants.os_has_gbm) {
                @panic("OS does not support gbm");
            }
            defer if (e.payload == .success) {
                e.payload.success.fds.buffer.close();
                e.payload.success.fds.acquire_timeline.close();
                e.payload.success.fds.release_timeline.close();
            };

            const client = server.clients.get_remote(e.client_uuid) orelse return;
            client.connection.send_buffer_created_gbm_bo(server.io, server.gpa, e.payload) catch
                return error.ConnectionClosed;
        },
        .texture_created_d3d => |e| {
            if (!constants.os_has_d3d) @panic("OS does not support d3d");
            defer if (e.payload == .success) {
                e.payload.success.texture_handle.close();
                e.payload.success.acquire_fence_handle.close();
                e.payload.success.release_fence_handle.close();
            };

            const client = server.clients.get_remote(e.client_uuid) orelse return;
            client.connection.send_texture_created_d3d(server.io, server.gpa, e.payload) catch |err|
                return switch (err) {
                    error.OutOfMemory => error.OutOfMemory,

                    error.Win32OpenProcessFailed,
                    error.DuplicateHandleFailed,
                    => error.FailedToSendHandle,

                    else => error.ConnectionClosed,
                };
        },

        inline else => |e, tag| {
            const connection: *ClientConnection = blk: {
                if (server.clients.get_remote(e.client_uuid)) |remote| break :blk &remote.connection;
                if (server.clients.get_local(e.client_uuid)) |local| break :blk &local.connection;
                return;
            };

            const send = @field(ClientConnection, "send_" ++ @tagName(tag));
            send(connection, server.io, server.gpa, e.payload) catch
                return error.ConnectionClosed;
        },
    }
}

fn handle_message_from_remote(server: *Server, message: ReceivedMessage) void {
    std.debug.assert(message.from == .remote);

    const client_uuid = message.from.remote;
    const msg = message.payload;

    switch (msg) {
        .register,
        .wake_up,
        .queue_pop,
        => |_, tag| log.err("Received invalid message for client {s}", .{@tagName(tag)}),

        inline else => |_, tag| {
            std.debug.assert(server.clients.contains_remote(client_uuid));
            const ce = server.compositor_event_from_message(client_uuid, tag, msg);
            server.compositor_events.insertAssumeCapacity(0, ce);
        },
    }
}

pub const HandleMessageFromUnknownError = error{
    OutOfMemoryDuringRegister,
    MisbehavingUnknownClient,
    ConnectionClosed,
    ClientUUIDAlreadyExists,
};

fn handle_message_from_unknown(server: *Server, message: ReceivedMessage) HandleMessageFromUnknownError!void {
    std.debug.assert(message.from == .unknown);

    const index = message.from.unknown;
    const msg = message.payload;

    const register = switch (msg) {
        .register => |r| r,
        else => {
            return error.MisbehavingUnknownClient;
        },
    };

    if (server.clients.contains(register.uuid)) {
        return error.ClientUUIDAlreadyExists;
    }

    if (register.is_local) {
        server.clients.promote_client_to_local(index, register.uuid);

        const client = server.clients.get_local(register.uuid).?;

        client.connection.send_registered(server.io, server.gpa, .{}) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemoryDuringRegister,
            else => return error.ConnectionClosed,
        };

        log.debug("Promoted unknown client to local {f}", .{register.uuid});
    } else {
        server.clients.promote_client_to_remote(index, register.uuid, register.pid);
        log.debug("Promoted unknown client to {f}", .{register.uuid});

        //
        // Finalize registration
        //

        const client = server.clients.get_remote(register.uuid).?;

        client.connection.send_registered(server.io, server.gpa, .{}) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemoryDuringRegister,
            else => return error.ConnectionClosed,
        };

        errdefer comptime unreachable;

        // broadcast the new client
        for (server.clients.list.items) |other| {
            const other_uuid = other.uuid() orelse continue;
            if (other_uuid == register.uuid) continue;

            other.connection.send_client_registered(
                server.io,
                server.gpa,
                .{ .client_uuid = register.uuid },
            ) catch |err|
                log.err("{} from {f} during broadcast", .{ err, other_uuid });
        }
    }
}

fn handle_message_from_local(server: *Server, message: ReceivedMessage) void {
    std.debug.assert(message.from == .local);

    const uuid = message.from.local;
    const msg = message.payload;

    switch (msg) {
        .wake_up => {
            log.debug("Received wake_up", .{});
        },
        .queue_pop => {
            const event = server.io_queue.getOne(server.io) catch return;
            server.compositor_events.insertAssumeCapacity(0, event);
        },

        inline .viewport_pos_set,
        .viewport_size_set,
        .viewport_display_state_set,
        .viewport_close,
        => |_, tag| {
            std.debug.assert(server.clients.contains_local(uuid));
            const ce = server.compositor_event_from_message(uuid, tag, msg);
            server.compositor_events.insertAssumeCapacity(0, ce);
        },

        else => {
            log.err("Received invalid message for local client", .{});
        },
    }
}

pub fn compositor_event_from_message(
    _: *Server,
    uuid: ClientUUID,
    comptime payload_tag: client_to_server.MessageTag,
    payload: client_to_server.MessagePayload,
) Compositor.EventFromServer {
    std.debug.assert(payload_tag == payload);
    switch (payload_tag) {
        .register,
        .wake_up,
        .queue_pop,
        => @compileError(@tagName(payload_tag) ++ " Cannot be turned into a CompositorEvent. This is meant for the Server"),

        inline .buffer_present,
        .buffer_present_with_sync,
        .buffer_destroy,
        .viewport_create,
        .cursor_shape_set,
        .remote_viewport_embed,
        .viewport_pos_set,
        .viewport_size_set,
        .viewport_display_state_set,
        .viewport_close,
        .viewport_destroy,
        .buffer_create_cpu,
        .buffer_create_gbm_bo,
        .texture_create_d3d,
        => {
            const msg = @field(payload, @tagName(payload_tag));
            return @unionInit(
                Compositor.EventFromServer,
                @tagName(payload_tag),
                .{ .client_uuid = uuid, .payload = msg },
            );
        },
    }
}

pub fn close_clients_marked_with_error(server: *Server) void {
    for (server.clients.list.items) |client| {
        const err = client.connection.close_with_error orelse continue;
        client.connection.close(server.gpa);

        if (client.uuid()) |uuid| {
            if (client.kind == .remote) {
                for (server.clients.list.items) |other| {
                    const other_uuid = other.uuid() orelse continue;
                    if (other_uuid == uuid or other.connection.closed) continue;

                    other.connection.send_client_disconnected(
                        server.io,
                        server.gpa,
                        .{ .client_uuid = uuid },
                    ) catch {};
                }
            }

            if (err == error.ConnectionClosed or err == error.ConnectionResetByPeer) {
                log.info("Closing {s} client {f} with {}", .{ @tagName(client.kind), uuid, err });
            } else {
                log.err("Closing {s} client {f} with {}", .{ @tagName(client.kind), uuid, err });
            }
        } else {
            log.err("Closing unknown client with {}", .{err});

            switch (err) {
                error.MisbehavingUnknownClient => {
                    log.err("Expected only a register message during register phase", .{});
                },
                else => {},
            }
        }
    }
}

fn mark_for_closing_client_with(server: *Server, index: usize, err: ClientConnection.CloseError) void {
    const client = server.clients.list.items[index];
    client.connection.close_with_error = err;
}

pub fn mark_for_closing_client_uuid_with(server: *Server, id: ClientUUID, err: ClientConnection.CloseError) void {
    const client =
        server.clients.get_remote(id) orelse
        server.clients.get_local(id) orelse
        return;
    client.connection.close_with_error = err;
}

fn mark_for_closing_remote_client_with(server: *Server, id: ClientUUID, err: ClientConnection.CloseError) void {
    const client = server.clients.get_remote(id) orelse return;
    client.connection.close_with_error = err;
}

fn mark_for_closing_unknown_client_with(server: *Server, index: usize, err: ClientConnection.CloseError) void {
    const client = server.clients.list.items[index];
    client.connection.close_with_error = err;
}

fn mark_for_closing_local_client_with(server: *Server, id: ClientUUID, err: ClientConnection.CloseError) void {
    const client = server.clients.get_local(id) orelse return;
    client.connection.close_with_error = err;
}

fn ReturnType(comptime func: anytype) type {
    return @typeInfo(@TypeOf(func)).@"fn".return_type.?;
}

pub const UnixSocketOwner = union(enum) {
    mux,
    embedded: []const u8,
};

const ReceivedMessage = struct {
    payload: Payload,
    from: MessageSource,

    const Payload = client_to_server.MessagePayload;
};

pub const ParsedMessage = struct {
    arena: *std.heap.ArenaAllocator,
    header: client_to_server.MessageHeader,
    payload: client_to_server.MessagePayload,
    from: MessageSource,

    pub fn deinit(parsed: *ParsedMessage, gpa: std.mem.Allocator) void {
        parsed.arena.deinit();
        gpa.destroy(parsed.arena);
    }

    pub fn parse(header: client_to_server.MessageHeader, raw: []const u8, arena: std.mem.Allocator) error{ParseFailed}!client_to_server.MessagePayload {
        switch (header.message_tag) {
            inline else => |tag| {
                switch (header.format) {
                    .json => {
                        const T = @FieldType(client_to_server.MessagePayload, @tagName(tag));
                        const p = std.json.parseFromSliceLeaky(
                            T,
                            arena,
                            raw,
                            .{ .allocate = .alloc_if_needed },
                        ) catch |err| {
                            // TODO: Check errors
                            log.err("{}", .{err});
                            return error.ParseFailed;
                        };

                        return @unionInit(client_to_server.MessagePayload, @tagName(tag), p);
                    },
                }
            },
        }
    }
};

pub const RawMessage = struct {
    header: client_to_server.MessageHeader,
    raw: []const u8,
    from: MessageSource,

    pub fn deinit(raw: *RawMessage, gpa: std.mem.Allocator) void {
        gpa.free(raw.raw);
    }

    pub fn parse(raw: RawMessage, arena: std.mem.Allocator) error{ParseFailed}!client_to_server.MessagePayload {
        switch (raw.header.message_tag) {
            inline else => |tag| {
                switch (raw.header.format) {
                    .json => {
                        const T = @FieldType(client_to_server.MessagePayload, @tagName(tag));
                        const p = std.json.parseFromSliceLeaky(T, arena, raw.raw, .{
                            .allocate = .alloc_if_needed,
                        }) catch |err| {
                            // TODO: Check errors
                            log.err("{} {s}", .{ err, raw.raw });
                            return error.ParseFailed;
                        };

                        return @unionInit(client_to_server.MessagePayload, @tagName(tag), p);
                    },
                }
            },
        }
    }
};

pub const MessageSource = union(enum) {
    unknown: usize,
    remote: ClientUUID,
    local: ClientUUID,
};

pub const Event = union(enum) {
    viewport_create: server_to_client.WithClientUUID(server_to_client.ViewportCreate),
    viewport_created: server_to_client.WithClientUUID(server_to_client.ViewportCreated),
    viewport_resize: server_to_client.WithClientUUID(server_to_client.ViewportResize),
    viewport_close: server_to_client.WithClientUUID(server_to_client.ViewportClose),
    viewport_display_state: server_to_client.WithClientUUID(server_to_client.ViewportDisplayState),

    remote_viewport_embedded: server_to_client.WithClientUUID(server_to_client.RemoteViewportEmbedded),
    remote_viewport_display_state: server_to_client.WithClientUUID(server_to_client.RemoteViewportDisplayState),
    remote_viewport_closed: server_to_client.WithClientUUID(server_to_client.RemoteViewportClosed),
    remote_viewport_render_size: server_to_client.WithClientUUID(server_to_client.RemoteViewportRenderSize),

    frame_render: server_to_client.WithClientUUID(server_to_client.FrameRender),

    buffer_released: server_to_client.WithClientUUID(server_to_client.BufferReleased),
    buffer_created_cpu: server_to_client.WithClientUUID(server_to_client.BufferCreatedCpu),
    buffer_created_gbm_bo: server_to_client.WithClientUUID(server_to_client.BufferCreatedGbmBo),
    texture_created_d3d: server_to_client.WithClientUUID(server_to_client.TextureCreatedD3D),

    keyboard_enter: server_to_client.WithClientUUID(server_to_client.KeyboardEnter),
    keyboard_leave: server_to_client.WithClientUUID(server_to_client.KeyboardLeave),
    keyboard_key: server_to_client.WithClientUUID(server_to_client.KeyboardKey),
    keyboard_char: server_to_client.WithClientUUID(server_to_client.KeyboardChar),
    mouse_enter: server_to_client.WithClientUUID(server_to_client.MouseEnter),
    mouse_leave: server_to_client.WithClientUUID(server_to_client.MouseLeave),
    mouse_motion: server_to_client.WithClientUUID(server_to_client.MouseMotion),
    mouse_button: server_to_client.WithClientUUID(server_to_client.MouseButton),
    mouse_scroll: server_to_client.WithClientUUID(server_to_client.MouseScroll),

    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try utils.format_union(self, writer);
    }

    pub fn client_uuid(self: Event) ClientUUID {
        return switch (self) {
            inline else => |v| v.client_uuid,
        };
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
const Compositor = @import("../Compositor.zig");
const server_to_client = @import("protocol").server_to_client;
const client_to_server = @import("protocol").client_to_server;
const local_client = @import("protocol").local_client;
const ptypes = @import("protocol").types;
const ClientUUID = ptypes.ClientUUID;
const RemoteClient = Clients.RemoteClient;
const UnknownClient = Clients.UnknownClient;
const os = @import("builtin").os.tag;
const ClientConnection = @import("ClientConnection.zig");
const zio = @import("zio");
const win_sock = @import("win32").networking.win_sock;
const Win32SocketEvent = @import("Win32SocketEvent.zig");
const known_folders = @import("known-folders");
const polling = @import("../polling.zig");
const maybe_oom = @import("../maybe_oom.zig").maybe_oom;
