pub const Server = @import("server/Server.zig");
pub const WindowSystem = @import("WindowSystem.zig");
pub const zio = @import("zio");

pub fn tick(arena: std.mem.Allocator, ws: *WindowSystem, server: *Server, poll_timeout: Io.Timeout) !void {
    const poll_result = try poll(arena, ws, server, poll_timeout);

    const messages = try server.messages_receive(arena, poll_result.clients);
    const ws_events = try server.messages_handle(arena, messages);
    ws.events_handle(ws_events);
    try ws.present();

    if (poll_result.window_system) {
        ws.dispatch();
    }

    ws.events_handle(ws.deferred_events.items);
    ws.deferred_events.clearRetainingCapacity();

    server.events_handle(ws);

    if (poll_result.accept) {
        // FIXME: In windows, we must accept all connections as resetting the accept event
        // will result in ignoring new clients
        if (server.server.accept(.{})) |stream| {
            try server.handle_event(.{ .unknown_client_connected = stream });
        } else |err| {
            log.err("Accept client failed {}", .{err});
        }
    }

    server.close_marked_clients();
    server.clients.remove_closed_known_clients();
    server.clients.remove_promoted_or_closed_unknown_clients();

    var i = ws.resources.count();
    while (i > 0) {
        i -= 1;
        const client_id = ws.resources.keys()[i];
        if (!server.clients.known.contains(client_id)) {
            ws.client_disconnected(client_id);
        }
    }

    try ws.resources.ensureTotalCapacity(ws.gpa, server.clients.count());
    for (server.clients.known.keys()) |client_id| {
        if (!ws.resources.contains(client_id)) {
            ws.client_registered(client_id) catch |err| switch (err) {
                error.OutOfMemory => unreachable,
            };
        }
    }

    switch (ws.native_tag()) {
        .wayland => |tag| {
            _ = tag.window_system(ws).display.flush();
        },
        else => {},
    }
}

const Poll = struct {
    window_system: bool,
    accept: bool,
    clients: []Server.MessageSource,
};

fn poll(
    arena: std.mem.Allocator,
    ws: *WindowSystem,
    server: *const Server,
    timeout: Io.Timeout,
) error{ OutOfMemory, PollFailed, Timeout }!Poll {
    std.debug.assert(timeout != .deadline);

    return switch (os) {
        .linux => try poll_linux(arena, ws, server, timeout),
        .windows => try poll_windows(arena, ws, server, timeout),
        else => comptime unreachable,
    };
}

fn poll_windows(
    arena: std.mem.Allocator,
    _: *WindowSystem,
    server: *const Server,
    timeout: Io.Timeout,
) !Poll {
    const events_len = server.clients.count() + 1;
    const events = try arena.alloc(*anyopaque, events_len);
    var clients: std.ArrayList(Server.MessageSource) = try .initCapacity(arena, server.clients.count());
    var i: usize = 0;

    const server_socket_i = i;
    {
        events[i] = server.win32_event_handle.handle;
        i += 1;
    }

    const known_i = i;
    for (server.clients.known.values()) |c| {
        events[i] = c.connection.win32_event_handle.handle;
        i += 1;
    }

    const unknown_i = i;
    for (server.clients.unknown.items) |c| {
        events[i] = c.connection.win32_event_handle.handle;
        i += 1;
    }

    std.debug.assert(i == events.len);

    const to: u32 = switch (timeout) {
        .deadline => unreachable,
        .duration => |d| @intCast(d.raw.toMilliseconds()),
        .none => win32_programming.INFINITE,
    };

    const result = win32_win.MsgWaitForMultipleObjectsEx(
        @intCast(events.len),
        events.ptr,
        to,
        win32_win.QS_ALLINPUT,
        win32_win.MWMO_INPUTAVAILABLE,
    );

    const WAIT_OBJECT_0: u32 = @intFromEnum(win32_foundation.WAIT_OBJECT_0);
    const signaled: enum { socket, window } =
        if (result >= WAIT_OBJECT_0 and result < WAIT_OBJECT_0 + events.len)
            .socket
        else if (result == WAIT_OBJECT_0 + events.len)
            .window
        else if (result == @intFromEnum(win32_foundation.WAIT_TIMEOUT))
            return error.Timeout
        else if (result == @intFromEnum(win32_foundation.WAIT_FAILED)) {
            const err = win32_foundation.GetLastError();
            log.err("Wait failed {}", .{err});
            return error.PollFailed;
        } else @panic("Unknown value");

    switch (signaled) {
        .socket => {
            for (server.clients.known.values(), 0..) |client, ci| {
                const event = events[known_i + ci];
                if (@intFromEnum(win32_threading.WaitForSingleObject(event, 0)) == WAIT_OBJECT_0) {
                    clients.appendAssumeCapacity(.{ .known = client.id });
                    std.debug.assert(
                        win_sock.WSAResetEvent(event) == @intFromEnum(std.os.windows.BOOL.TRUE),
                    );
                }
            }

            for (server.clients.unknown.items, 0..) |_, ci| {
                const event = events[unknown_i + ci];
                if (@intFromEnum(win32_threading.WaitForSingleObject(event, 0)) == WAIT_OBJECT_0) {
                    clients.appendAssumeCapacity(.{ .unknown = ci });
                    std.debug.assert(
                        win_sock.WSAResetEvent(event) == @intFromEnum(std.os.windows.BOOL.TRUE),
                    );
                }
            }

            const accept = blk: {
                const event = events[server_socket_i];
                const accept = @intFromEnum(win32_threading.WaitForSingleObject(event, 0)) == WAIT_OBJECT_0;
                if (accept) {
                    std.debug.assert(
                        win_sock.WSAResetEvent(event) == @intFromEnum(std.os.windows.BOOL.TRUE),
                    );
                }
                break :blk accept;
            };

            return .{
                .clients = clients.items,
                .accept = accept,
                .window_system = false,
            };
        },
        .window => {
            return .{ .clients = &.{}, .accept = false, .window_system = true };
        },
    }
}

fn poll_linux(
    arena: std.mem.Allocator,
    ws: *WindowSystem,
    server: *const Server,
    timeout: Io.Timeout,
) !Poll {
    std.debug.assert(timeout != .deadline);

    const Pollfd, const POLL = .{ std.os.linux.pollfd, std.os.linux.POLL };

    const fds_len = server.clients.count() + 2;
    const fds = try arena.alloc(Pollfd, fds_len);
    var clients: std.ArrayList(Server.MessageSource) = try .initCapacity(arena, server.clients.count());

    const events = POLL.IN | POLL.HUP;

    for (fds) |*fd| {
        fd.* = .{
            .fd = -1,
            .events = events,
            .revents = 0,
        };
    }

    var i: usize = 0;

    const display_i = i;
    switch (ws.native_tag()) {
        .wayland => |tag| {
            const wl = tag.window_system(ws);
            const display_fd = wl.display.getFd();
            fds[i].fd = display_fd;
            i += 1;
        },
        else => unreachable,
    }

    const server_socket_i = i;
    {
        fds[i].fd = server.server.socket.handle;
        i += 1;
    }

    const known_i = i;
    for (server.clients.known.values()) |c| {
        fds[i].fd = c.connection.stream.socket.handle;
        i += 1;
    }

    const unknown_i = i;
    for (server.clients.unknown.items) |c| {
        fds[i].fd = c.connection.stream.socket.handle;
        i += 1;
    }

    std.debug.assert(i == fds.len);

    const ms: i32 = switch (timeout) {
        .none => std.math.maxInt(i32),
        .duration => |d| @truncate(d.raw.toMilliseconds()),
        .deadline => unreachable,
    };
    const poll_result: isize = @bitCast(std.os.linux.poll(fds.ptr, fds.len, ms));

    if (poll_result == 0) return error.Timeout;

    if (poll_result < 0) {
        return error.PollFailed;
    }

    for (server.clients.known.values(), 0..) |client, ci| {
        const fd = fds[known_i + ci];
        if ((fd.revents & events) != 0) {
            clients.appendAssumeCapacity(.{ .known = client.id });
        }
    }

    for (server.clients.unknown.items, 0..) |_, ci| {
        const fd = fds[unknown_i + ci];
        if ((fd.revents & events) != 0) {
            clients.appendAssumeCapacity(.{ .unknown = ci });
        }
    }

    const compositor = (fds[display_i].revents & POLL.IN) != 0;
    const accept = (fds[server_socket_i].revents & POLL.IN) != 0;
    return .{
        .window_system = compositor,
        .accept = accept,
        .clients = clients.items,
    };
}

const std = @import("std");
const Io = std.Io;
const log = std.log.scoped(.agce);
const win32_win = @import("win32").ui.windows_and_messaging;
const win32_foundation = @import("win32").foundation;
const win32_programming = @import("win32").system.windows_programming;
const win32_threading = @import("win32").system.threading;
const win_sock = @import("win32").networking.win_sock;
const os = @import("builtin").os.tag;
