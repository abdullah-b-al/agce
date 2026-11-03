const Server = @This();

io: Io,
gpa: std.mem.Allocator,

rand: std.Random.DefaultPrng,
unix_path: []const u8,
server: zio.net.Server,
clients: Clients,

win32_event_handle: Win32EventHandle,

pub fn create(
    io: Io,
    environ_map: *const std.process.Environ.Map,
    gpa: std.mem.Allocator,
    socket_owner: UnixSocketOwner,
) !*Server {
    const server = try gpa.create(Server);
    errdefer gpa.destroy(server);

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

        if (socket_owner == .embeded) {
            agce_dir.createDir(io, socket_owner.embeded, .default_dir) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => {
                    log.err("{}", .{err});
                    return error.CouldNotCreateEmbededSocketDir;
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
            .embeded => |embeded| break :blk try std.fs.path.join(gpa, &.{
                runtime_path,
                constants.socket_dir_name,
                embeded,
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

    const win32_event_handle = try Win32EventHandle.create(net_server.socket, .accept);

    server.* = .{
        .io = io,
        .gpa = gpa,
        .rand = rand,

        .unix_path = unix_path,
        .server = net_server,
        .clients = .init,

        .win32_event_handle = win32_event_handle,
    };
    return server;
}

pub fn destroy(server: *Server) void {
    server.clients.deinit(server.io, server.gpa);

    server.win32_event_handle.close();
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

    server.gpa.free(server.unix_path);
    server.gpa.destroy(server);
}

pub fn process_incoming_messages(server: *Server, arena: std.mem.Allocator, poll_result: []const MessageSource) ![]const CompositorEvent {
    if (poll_result.len == 0)
        return &.{};

    const messages_raw = blk: {
        var messages_raw: std.ArrayList(RawMessage) = .empty;

        for (poll_result) |source| {
            const connection: *ClientConnection = switch (source) {
                .known => |id| &server.clients.known.get(id).?.connection,
                .unknown => |index| &server.clients.unknown.items[index].connection,
                .local => |index| &server.clients.local.items[index].connection,
            };

            connection.receive_raw_all(server.io, arena, &messages_raw, source) catch |err|
                switch (err) {
                    error.OutOfMemory => continue,
                };
        }

        break :blk messages_raw.items;
    };

    const messages_parsed = blk: {
        var messages_parsed: std.ArrayList(ReceivedMessage) =
            try .initCapacity(arena, messages_raw.len);

        for (messages_raw) |raw| {
            const payload = raw.parse(arena) catch |err| switch (err) {
                error.ParseFailed => continue,
            };

            messages_parsed.appendAssumeCapacity(.{ .from = raw.from, .payload = payload });
        }

        break :blk messages_parsed.items;
    };

    var result: std.ArrayList(CompositorEvent) = try .initCapacity(arena, messages_parsed.len);
    for (messages_parsed) |parsed| {
        server.handle_message(parsed, &result);
    }

    return result.items;
}

pub fn connect_local(server: *Server) !zio.net.Stream {
    return try server.server.socket.address.connect(.{ .timeout = .none });
}

fn handle_message(server: *Server, message: ReceivedMessage, events: *std.ArrayList(CompositorEvent)) void {
    const @"error" = switch (message.from) {
        .known => server.handle_message_from_known(message, events),
        .unknown => server.handle_message_from_unknown(message),
        .local => server.handle_message_from_local(message),
    };

    @"error" catch |err| switch (err) {
        error.MisbehavingUnknownClient,
        error.ClientSentInvalidClientFullID,
        error.OutOfMemoryDuringRegister,
        error.ClientUUIDAlreadyExists,
        => |e| {
            switch (message.from) {
                .unknown => |index| server.mark_for_closing_unknown_client_with(index, e),
                .known => @panic("Not possible with a known client"),
                .local => @panic("Not possible with a local client"),
            }
        },

        error.ConnectionClosed,
        => |e| {
            switch (message.from) {
                .known => |id| server.mark_for_closing_known_client_with(id, e),
                .unknown => |index| server.mark_for_closing_unknown_client_with(index, e),
                .local => |index| server.mark_for_closing_local_client_with(index, e),
            }
        },

        error.UnsupportedMessageOnOs,
        => |e| {
            log.err("{} when handling client message", .{e});
        },
    };
}

pub fn events_handle(server: *Server, com: *Compositor) void {
    while (com.server_events.pop()) |node| {
        defer com.server_events.destroy(node);

        const event = node.event;
        server.handle_event(event) catch |err| {
            switch (event) {
                .unknown_client_connected => {},
                inline else => |v| {
                    switch (err) {
                        error.OutOfMemory => {
                            log.err("events_handle {}", .{err});
                            event.close_handles();
                        },

                        error.FailedToCreateWin32EventHandle,
                        error.FailedToSendFds,
                        error.FailedToSendHandle,
                        error.ConnectionClosed,
                        => |mark| {
                            event.close_handles();
                            server.mark_for_closing_known_client_with(v.client_uuid, mark);
                        },
                    }
                },
            }
        };

        event.close_handles();
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
    FailedToCreateWin32EventHandle,
}!void {
    switch (event) {
        .unknown_client_connected => |stream| {
            errdefer stream.close();

            try server.clients.prepare_for_new_client(server.gpa);
            try server.clients.new_unknown(server.gpa, stream);

            log.info("Unknown client connected", .{});
        },
        .buffer_created_cpu => |e| {
            const client = server.clients.known.get(e.client_uuid) orelse return;
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
                } else return err;
            };
        },
        .buffer_created_gbm_bo => |e| {
            if (!constants.os_has_gbm) {
                @panic("OS does not support gbm");
            }

            const client = server.clients.known.get(e.client_uuid) orelse return;
            try client.connection.send_buffer_created_gbm_bo(server.io, server.gpa, e.payload);
        },
        .texture_created_d3d => |e| {
            if (!constants.os_has_d3d) @panic("OS does not support d3d");

            const client = server.clients.known.get(e.client_uuid) orelse return;
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
            const client = server.clients.known.get(e.client_uuid) orelse return;

            const send = @field(ClientConnection, "send_" ++ @tagName(tag));
            send(&client.connection, server.io, server.gpa, e.payload) catch
                return error.ConnectionClosed;
        },
    }
}

fn handle_message_from_known(server: *Server, message: ReceivedMessage, events: *std.ArrayList(CompositorEvent)) !void {
    std.debug.assert(message.from == .known);

    const client_uuid = message.from.known;
    const msg = message.payload;

    switch (msg) {
        .register,
        .wake_up,
        => |_, tag| log.err("Received invalid message for client {s}", .{@tagName(tag)}),

        inline else => |_, tag| {
            const client = server.clients.known.get(client_uuid).?;
            const ce = try server.compositor_event_from_message(client, tag, msg);
            events.appendAssumeCapacity(ce);
        },
    }
}

pub const HandleMessageFromUnknownError = error{
    OutOfMemoryDuringRegister,
    MisbehavingUnknownClient,
    ClientSentInvalidClientFullID,
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

    if (register.is_local) {
        std.debug.assert(register.uuid == null);
        server.clients.promote_client_to_local(server.gpa, index);
        log.debug("Promoted unknown client to local", .{});
    } else {
        const id: ClientUUID = register.uuid orelse .new(server.io);
        if (server.clients.known.contains(id)) {
            return error.ClientUUIDAlreadyExists;
        }

        server.clients.promote_client_to_known(server.gpa, index, id, register.pid);
        log.debug("Promoted unknown client to {f}", .{id});

        //
        // Finalize registration
        //

        const client = server.clients.known.get(id).?;

        client.connection.send_registered(server.io, server.gpa, .{}) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemoryDuringRegister,
            else => return error.ConnectionClosed,
        };

        errdefer comptime unreachable;

        // broadcast the new client
        for (server.clients.known.values()) |other| {
            if (@intFromEnum(other.id) == @intFromEnum(client.id)) continue;

            other.connection.send_client_registered(server.io, server.gpa, .{ .client_uuid = client.id }) catch |err|
                log.err("{} from {f} during broadcast", .{ err, other.id });
        }
    }
}

fn handle_message_from_local(server: *Server, message: ReceivedMessage) !void {
    std.debug.assert(message.from == .local);

    const index = message.from.local;
    const msg = message.payload;

    _ = server;
    _ = index;
    switch (msg) {
        .wake_up => {
            log.debug("Received wake_up", .{});
        },
        else => {
            log.err("Received invalid message for local client", .{});
            return;
        },
    }
}

pub fn compositor_event_from_message(
    _: *Server,
    client: *Client,
    comptime payload_tag: client_to_server.MessageTag,
    payload: client_to_server.MessagePayload,
) error{UnsupportedMessageOnOs}!CompositorEvent {
    std.debug.assert(payload_tag == payload);
    switch (payload_tag) {
        .register,
        .wake_up,
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
                CompositorEvent,
                @tagName(payload_tag),
                .{ .client_uuid = client.id, .payload = msg },
            );
        },
    }
}

pub fn close_clients_marked_with_error(server: *Server) void {
    for (server.clients.known.values()) |client| {
        if (client.connection.close_with_error) |err| {
            client.connection.close();

            if (err == error.ConnectionClosed) {
                log.info("Closing client {} with {}", .{ client.id, err });
            } else {
                log.err("Closing client {} with {}", .{ client.id, err });
            }

            for (server.clients.known.values()) |c| {
                if (c.id == client.id or c.connection.closed) continue;

                c.connection.send_client_disconnected(server.io, server.gpa, .{ .client_uuid = client.id }) catch {};
            }
        }
    }

    for (server.clients.local.items) |client| {
        if (client.connection.close_with_error) |err| {
            client.connection.close();
            log.err("Closing client local with {}", .{err});

            switch (err) {
                error.MisbehavingUnknownClient => {
                    log.err("Expected only a register message during register phase", .{});
                },
                else => {},
            }
        }
    }

    for (server.clients.unknown.items) |client| {
        if (client.connection.close_with_error) |err| {
            client.connection.close();
            log.err("Closing client unknown with {}", .{err});

            switch (err) {
                error.MisbehavingUnknownClient => {
                    log.err("Expected only a register message during register phase", .{});
                },
                else => {},
            }
        }
    }
}

fn mark_for_closing_known_client_with(server: *Server, id: ClientUUID, err: ClientConnection.CloseError) void {
    const client = server.clients.known.get(id) orelse return;
    client.connection.close_with_error = err;
}

fn mark_for_closing_unknown_client_with(server: *Server, index: usize, err: ClientConnection.CloseError) void {
    const client = server.clients.unknown.items[index];
    client.connection.close_with_error = err;
}

fn mark_for_closing_local_client_with(server: *Server, index: usize, err: ClientConnection.CloseError) void {
    const client = server.clients.local.items[index];
    client.connection.close_with_error = err;
}

fn ReturnType(comptime func: anytype) type {
    return @typeInfo(@TypeOf(func)).@"fn".return_type.?;
}

pub const UnixSocketOwner = union(enum) {
    mux,
    embeded: []const u8,
};

const ReceivedMessage = struct {
    payload: Payload,
    from: MessageSource,

    const Payload = client_to_server.MessagePayload;
};

pub const RawMessage = struct {
    header: client_to_server.MessageHeader,
    raw: []const u8,
    from: MessageSource,

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

pub const MessageSource = union(enum) {
    known: ClientUUID,
    unknown: usize,
    local: usize,
};

pub const Event = union(enum) {
    unknown_client_connected: zio.net.Stream,

    viewport_create: server_to_client.WithClientUUID(server_to_client.ViewportCreate),
    viewport_created: server_to_client.WithClientUUID(server_to_client.ViewportCreated),
    viewport_resize: server_to_client.WithClientUUID(server_to_client.ViewportResize),
    viewport_close: server_to_client.WithClientUUID(server_to_client.ViewportClose),
    viewport_display_state: server_to_client.WithClientUUID(server_to_client.ViewportDisplayState),

    remote_viewport_embeded: server_to_client.WithClientUUID(server_to_client.RemoteViewportEmbeded),
    remote_viewport_display_state: server_to_client.WithClientUUID(server_to_client.RemoteViewportDisplayState),
    remote_viewport_closed: server_to_client.WithClientUUID(server_to_client.RemoteViewportClosed),

    frame_render: server_to_client.WithClientUUID(server_to_client.FrameRender),

    buffer_released: server_to_client.WithClientUUID(server_to_client.BufferReleased),
    buffer_created_cpu: server_to_client.WithClientUUID(server_to_client.BufferCreatedCpu),
    buffer_created_gbm_bo: server_to_client.WithClientUUID(server_to_client.BufferCreatedGbmBo),
    texture_created_d3d: server_to_client.WithClientUUID(server_to_client.TextureCreatedD3D),

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

    pub fn close_handles(event: Event) void {
        switch (event) {
            .buffer_created_cpu => |e| {
                e.payload.handle.close();
            },
            .buffer_created_gbm_bo => |e| {
                if (os == .linux) {
                    e.payload.fds.buffer.close();
                    e.payload.fds.acquire_timeline.close();
                    e.payload.fds.release_timeline.close();
                }
            },
            .texture_created_d3d => |e| {
                if (os == .windows) {
                    e.payload.texture_handle.close();
                    e.payload.acquire_fence_handle.close();
                    e.payload.release_fence_handle.close();
                }
            },
            else => {},
        }
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
const CompositorEvent = @import("../Compositor.zig").Event;
const server_to_client = @import("protocol").server_to_client;
const client_to_server = @import("protocol").client_to_server;
const local_client = @import("protocol").local_client;
const ptypes = @import("protocol").types;
const ClientUUID = ptypes.ClientUUID;
const Client = Clients.Client;
const UnknownClient = Clients.UnknownClient;
const os = @import("builtin").os.tag;
const ClientConnection = @import("ClientConnection.zig");
const zio = @import("zio");
const win_sock = @import("win32").networking.win_sock;
const Win32EventHandle = @import("Win32EventHandle.zig");
const known_folders = @import("known-folders");
