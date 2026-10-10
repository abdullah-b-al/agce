const Server = @This();

io: Io,
gpa: std.mem.Allocator,

rand: std.Random.DefaultPrng,
unix_path: []const u8,
server: zio.net.Server,
clients: Clients,
generated_full_ids: std.array_hash_map.Auto(ptypes.ClientFullID, void),

win32_event_handle: Win32EventHandle,

pub fn create(
    io: Io,
    environ_map: *const std.process.Environ.Map,
    gpa: std.mem.Allocator,
) !*Server {
    const server = try gpa.create(Server);
    errdefer gpa.destroy(server);

    var path_buf: [constants.socket_max_path]u8 = undefined;
    const unix_path = blk: {
        const path = try utils.unix_address_path(io, gpa, environ_map, &path_buf);
        break :blk try gpa.dupe(u8, path);
    };
    const address = zio.net.UnixAddress.init(unix_path) catch |err| switch (err) {
        error.NameTooLong => unreachable,
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
        .rand = .init(0),
        .generated_full_ids = .empty,

        .unix_path = unix_path,
        .server = net_server,
        .clients = .init,

        .win32_event_handle = win32_event_handle,
    };
    return server;
}

pub fn destroy(server: *Server) void {
    server.clients.deinit(server.io, server.gpa);
    server.generated_full_ids.deinit(server.gpa);

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

pub fn handle_message(server: *Server, message: ReceivedMessage, events: *std.ArrayList(WindowSystemEvent)) void {
    const @"error" = switch (message.from) {
        .known => server.handle_message_from_known(message, events),
        .unknown => server.handle_message_from_unknown(message),
    };

    @"error" catch |err| switch (err) {
        error.MisbehavingUnknownClient,
        error.ClientSentInvalidClientFullID,
        error.OutOfMemoryDuringRegister,
        => |e| {
            switch (message.from) {
                .unknown => |index| server.mark_for_closing_unknown_client_with(index, e),
                .known => @panic("Not possiable with a known client"),
            }
        },

        error.ConnectionClosed,
        => |e| {
            switch (message.from) {
                .known => |id| {
                    server.mark_for_closing_known_client_with(id, e);
                },
                .unknown => |index| {
                    server.mark_for_closing_unknown_client_with(index, e);
                },
            }
        },

        error.UnsupportedMessageOnOs,
        error.OutOfMemory,
        => |e| {
            log.err("{} when handling client message", .{e});
        },
    };
}

pub fn events_handle(server: *Server, events: []const Event) void {
    for (events) |e| {
        server.handle_event(e) catch |err| {
            switch (e) {
                .unknown_client_connected => {},
                inline else => |v| {
                    switch (err) {
                        error.OutOfMemory => {
                            log.err("events_handle {}", .{err});
                        },

                        error.FailedToCreateWin32EventHandle,
                        error.FailedToSendFds,
                        error.FailedToSendHandle,
                        error.ConnectionClosed,
                        => |mark| {
                            server.mark_for_closing_known_client_with(v.client_id, mark);
                        },
                    }
                },
            }
        };
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
            defer {
                switch (os) {
                    .linux => {
                        std.debug.assert(std.os.linux.close(@intFromEnum(e.payload.handle)) == 0);
                    },
                    .windows => {},
                    else => comptime unreachable,
                }
            }

            const client = server.clients.known.get(e.client_id) orelse return;
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
            switch (os) {
                .linux => {
                    defer {
                        std.debug.assert(std.os.linux.close(@intFromEnum(e.payload.fds.buffer)) == 0);
                        std.debug.assert(std.os.linux.close(@intFromEnum(e.payload.fds.acquire_timeline)) == 0);
                        std.debug.assert(std.os.linux.close(@intFromEnum(e.payload.fds.release_timeline)) == 0);
                    }

                    const client = server.clients.known.get(e.client_id) orelse return;
                    try client.connection.send_buffer_created_gbm_bo(server.io, server.gpa, e.payload);
                },
                .windows => @panic("OS does not support gbm"),
                else => comptime unreachable,
            }
        },
        .texture_created_d3d => |e| {
            if (!constants.os_has_d3d) @panic("OS does not support d3d");

            const client = server.clients.known.get(e.client_id) orelse return;
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
            const client = server.clients.known.get(e.client_id) orelse return;

            const send = @field(ClientConnection, "send_" ++ @tagName(tag));
            send(&client.connection, server.io, server.gpa, e.payload) catch
                return error.ConnectionClosed;
        },
    }
}

fn handle_message_from_known(server: *Server, message: ReceivedMessage, events: *std.ArrayList(WindowSystemEvent)) !void {
    std.debug.assert(message.from == .known);

    const client_id = message.from.known;
    const msg = message.payload;

    switch (msg) {
        .generate_client_full_id => {
            const client = server.clients.known.get(client_id) orelse return;
            try server.generated_full_ids.ensureUnusedCapacity(server.gpa, 1);

            const full_id = server.generate_full_id();
            server.generated_full_ids.putAssumeCapacityNoClobber(full_id, {});
            log.debug("Generated {f}", .{full_id});

            client.connection.send_generated_client_full_id(server.io, server.gpa, .{ .full_id = full_id }) catch
                return error.ConnectionClosed;
        },
        else => {
            const client = server.clients.known.get(client_id).?;
            const wse = try server.window_system_event_from_message(client, msg);
            events.appendAssumeCapacity(wse);
        },
    }
}

pub const HandleMessageFromUnknownError = error{
    OutOfMemoryDuringRegister,
    MisbehavingUnknownClient,
    ClientSentInvalidClientFullID,
    ConnectionClosed,
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

        other.connection.send_client_registered(server.io, server.gpa, .{ .client_id = client.id }) catch |err|
            log.err("{} from {f} during broadcast", .{ err, other.id });
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
        .texture_create_d3d,
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
    if (poll_result.len == 0)
        return &.{};

    var list = try std.ArrayList(ReceivedMessage).initCapacity(
        arena,
        server.clients.count() * 32,
    );

    var reader_buffer: [4096]u8 = undefined;
    for (poll_result) |source| {
        const connection: *ClientConnection = switch (source) {
            .known => |id| &server.clients.known.get(id).?.connection,
            .unknown => |index| &server.clients.unknown.items[index].connection,
        };

        std.debug.assert(!connection.closed);
        var reader = connection.stream.reader(&reader_buffer);
        reader.setTimeout(.fromNanoseconds(0));

        var added_from_this_client: usize = 0;
        while (true) {
            const read = connection.receive_with_reader(server.io, arena, &reader.interface) catch |err|
                switch (err) {
                    error.EndOfStream => {
                        if (added_from_this_client == 0) {
                            connection.close_with_error = error.ConnectionClosed;
                        }
                        break;
                    },
                    error.ReadFailed => switch (reader.err.?) {
                        error.Timeout => break,
                        else => |e| {
                            connection.close_with_error = e;
                            break;
                        },
                    },
                    error.OutOfMemory,
                    error.ParseFailed,
                    error.InvalidHeader,
                    error.HeaderWithoutPayload,
                    => |e| {
                        log.err("{}", .{e});
                        continue;
                    },
                };

            try list.append(arena, .{ .from = source, .payload = read });
            added_from_this_client += 1;
        }
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

pub fn close_marked_clients(server: *Server) void {
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

                c.connection.send_client_disconnected(server.io, server.gpa, .{ .client_id = client.id }) catch {};
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

fn mark_for_closing_known_client_with(server: *Server, id: ClientID, err: ClientConnection.CloseError) void {
    const client = server.clients.known.get(id) orelse return;
    client.connection.close_with_error = err;
}

fn mark_for_closing_unknown_client_with(server: *Server, index: usize, err: ClientConnection.CloseError) void {
    const client = server.clients.unknown.items[index];
    client.connection.close_with_error = err;
}

fn ReturnType(comptime func: anytype) type {
    return @typeInfo(@TypeOf(func)).@"fn".return_type.?;
}

const ReceivedMessage = struct {
    payload: Payload,
    from: MessageSource,

    const Payload = client_to_server.MessagePayload;
};

pub const MessageSource = union(enum) {
    known: ClientID,
    unknown: usize,
};

pub const Event = union(enum) {
    unknown_client_connected: zio.net.Stream,

    viewport_create: server_to_client.WithClientID(server_to_client.ViewportCreate),
    viewport_created: server_to_client.WithClientID(server_to_client.ViewportCreated),
    viewport_resize: server_to_client.WithClientID(server_to_client.ViewportResize),
    viewport_close: server_to_client.WithClientID(server_to_client.ViewportClose),
    viewport_display_state: server_to_client.WithClientID(server_to_client.ViewportDisplayState),

    sub_viewport_embeded: server_to_client.WithClientID(server_to_client.SubViewportEmbeded),
    sub_viewport_display_state: server_to_client.WithClientID(server_to_client.SubViewportDisplayState),
    sub_viewport_closed: server_to_client.WithClientID(server_to_client.SubviewportClosed),

    frame_render: server_to_client.WithClientID(server_to_client.FrameRender),

    buffer_released: server_to_client.WithClientID(server_to_client.BufferReleased),
    buffer_created_cpu: server_to_client.WithClientID(server_to_client.BufferCreatedCpu),
    buffer_created_gbm_bo: server_to_client.WithClientID(server_to_client.BufferCreatedGbmBo),
    texture_created_d3d: server_to_client.WithClientID(server_to_client.TextureCreatedD3D),

    keyboard_key: server_to_client.WithClientID(server_to_client.KeyboardKey),
    keyboard_char: server_to_client.WithClientID(server_to_client.KeyboardChar),
    mouse_enter: server_to_client.WithClientID(server_to_client.MouseEnter),
    mouse_leave: server_to_client.WithClientID(server_to_client.MouseLeave),
    mouse_motion: server_to_client.WithClientID(server_to_client.MouseMotion),
    mouse_button: server_to_client.WithClientID(server_to_client.MouseButton),
    mouse_scroll: server_to_client.WithClientID(server_to_client.MouseScroll),

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
const WindowSystem = @import("../WindowSystem.zig");
const WindowSystemEvent = @import("../WindowSystem.zig").Event;
const server_to_client = @import("protocol").server_to_client;
const client_to_server = @import("protocol").client_to_server;
const ptypes = @import("protocol").types;
const ClientID = ptypes.ClientID;
const Client = Clients.Client;
const UnknownClient = Clients.UnknownClient;
const os = @import("builtin").os.tag;
const ClientConnection = @import("ClientConnection.zig");
const zio = @import("zio");
const win_sock = @import("win32").networking.win_sock;
const Win32EventHandle = @import("Win32EventHandle.zig");
