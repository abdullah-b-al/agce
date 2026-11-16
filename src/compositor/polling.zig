pub fn poll(
    arena: std.mem.Allocator,
    com: *Compositor,
    server: *const Server,
    timeout: Io.Timeout,
) !Poll {
    std.debug.assert(timeout != .deadline);

    const pollable_len_add: usize = switch (com.native_tag()) {
        .wayland => 2, // +2 for the display fd and server socket
        .win32 => 1, // +1 only for the server socket
    };

    const pollable_len = server.clients.count() + pollable_len_add;
    var pollable: std.MultiArrayList(Pollable) = try .initCapacity(arena, pollable_len);

    var clients: std.ArrayList(ClientResult) =
        try .initCapacity(arena, server.clients.count());

    switch (com.native_tag()) {
        .wayland => |tag| {
            const wl = tag.compositor(com);
            const display_fd = wl.display.getFd();
            pollable.appendAssumeCapacity(.from_fd(display_fd, .display));
        },
        else => {},
    }

    pollable.appendAssumeCapacity(.from_server(server));

    for (server.clients.list.items, 0..) |c, j| {
        pollable.appendAssumeCapacity(
            .from_connection(c.connection, j),
        );
    }

    std.debug.assert(pollable.len == pollable_len);

    const poll_result = poll_targets(pollable.items(.target), timeout);
    switch (poll_result) {
        .timeout => return error.Timeout,
        .failed => return error.PollFailed,

        .win32_window_event, .ok => {},
    }

    var dispatch = poll_result == .win32_window_event;
    var accept = false;

    for (0..pollable.len) |i| {
        const p = pollable.get(i);
        switch (p.source) {
            .display => {
                std.debug.assert(com.native_tag() != .win32);
                dispatch = p.event() == .read;
            },
            .server => accept = p.event() == .read,
            .client => |client| {
                const event = p.event();
                clients.appendAssumeCapacity(.{ .index = client, .event = event });
            },
        }
    }

    return .{
        .accept = accept,
        .dispatch = dispatch,
        .clients = clients.items,
    };
}

const PollResult = enum {
    timeout,
    failed,
    win32_window_event,
    ok,
};

fn poll_targets(target: []Pollable.Target, timeout: Io.Timeout) PollResult {
    switch (os) {
        .linux => {
            const to: i32 = switch (timeout) {
                .none => std.math.maxInt(i32),
                .duration => |d| @truncate(d.raw.toMilliseconds()),
                .deadline => unreachable,
            };

            const poll_result: isize = @bitCast(
                std.os.linux.poll(target.ptr, target.len, to),
            );

            if (poll_result == 0) return .timeout;

            if (poll_result < 0) {
                return .failed;
            }

            return .ok;
        },
        .windows => {
            const to: u32 = switch (timeout) {
                .none => win32_programming.INFINITE,
                .duration => |d| @intCast(d.raw.toMilliseconds()),
                .deadline => unreachable,
            };

            const ptr: [*]const *anyopaque = @ptrCast(target.ptr);
            const result = win32_win.MsgWaitForMultipleObjectsEx(
                @intCast(target.len),
                ptr,
                to,
                win32_win.QS_ALLINPUT,
                win32_win.MWMO_INPUTAVAILABLE,
            );

            if (result == @intFromEnum(win32_foundation.WAIT_TIMEOUT))
                return .timeout
            else if (result == @intFromEnum(win32_foundation.WAIT_FAILED)) {
                const err = win32_foundation.GetLastError();
                log.err("Wait failed {}", .{err});
                return .failed;
            }

            const WAIT_OBJECT_0: u32 = @intFromEnum(win32_foundation.WAIT_OBJECT_0);
            if (result == WAIT_OBJECT_0 + target.len)
                return .win32_window_event;

            return .ok;
        },
        else => comptime unreachable,
    }
}

const Pollable = switch (os) {
    .linux => PollableLinux,
    .windows => PollableWindows,
    else => unreachable,
};

const PollableLinux = struct {
    target: Target,

    source: Source,

    const Target = std.os.linux.pollfd;
    const POLL = std.os.linux.POLL;
    const event_flags = POLL.IN | POLL.HUP;

    fn event(p: PollableLinux) Event {
        if (p.target.revents & POLL.HUP != 0) return .closed;
        if (p.target.revents & POLL.IN != 0) return .read;

        return .none;
    }

    fn from_connection(c: ClientConnection, index: usize) PollableLinux {
        return .from_fd(c.stream.socket.handle, .{ .client = index });
    }

    fn from_server(server: *const Server) PollableLinux {
        return .from_fd(server.server.socket.handle, .server);
    }

    fn from_fd(fd: i32, source: Source) PollableLinux {
        return .{
            .target = .{
                .fd = fd,
                .events = event_flags,
                .revents = 0,
            },
            .source = source,
        };
    }
};

const PollableWindows = struct {
    target: Target,

    source: Source,
    socket_handle: *anyopaque,

    const Target = Win32SocketEvent;

    fn event(p: PollableWindows) Event {
        var ne = std.mem.zeroes(win_sock.WSANETWORKEVENTS);
        _ = win_sock.WSAEnumNetworkEvents(
            @ptrCast(p.socket_handle),
            p.target.handle,
            &ne,
        );

        if (ne.lNetworkEvents & win_sock.FD_CLOSE != 0) {
            return .closed;
        }

        if (ne.lNetworkEvents & win_sock.FD_READ != 0) {
            return .read;
        }

        if (ne.lNetworkEvents & win_sock.FD_ACCEPT != 0) {
            return .read;
        }

        return .none;
    }

    fn from_connection(c: ClientConnection, index: usize) PollableWindows {
        return .from_handle(c.win32_socket_event, .{ .client = index }, c.stream.socket.handle);
    }

    fn from_server(server: *const Server) PollableWindows {
        return .from_handle(server.win32_socket_event, .server, server.server.socket.handle);
    }

    fn from_handle(event_handle: Win32SocketEvent, source: Source, socket_handle: *anyopaque) PollableWindows {
        return .{
            .target = event_handle,
            .source = source,
            .socket_handle = socket_handle,
        };
    }
};

pub const Poll = struct {
    dispatch: bool,
    accept: bool,
    clients: []const ClientResult,
};

pub const ClientResult = struct {
    event: Event,
    index: usize,
};

pub const Event = enum {
    read,
    closed,
    none,
};

const Source = union(enum) {
    server,
    display,
    client: usize,
};

const std = @import("std");
const Io = std.Io;
const log = std.log.scoped(.agce);
const cwl = @import("wayland").client.wl;
const win32_win = @import("win32").ui.windows_and_messaging;
const win32_foundation = @import("win32").foundation;
const win32_programming = @import("win32").system.windows_programming;
const win32_threading = @import("win32").system.threading;
const win_sock = @import("win32").networking.win_sock;
const os = @import("builtin").os.tag;
const ptypes = @import("protocol").types;
const ClientConnection = @import("server/ClientConnection.zig");
const Server = @import("server/Server.zig");
const Compositor = @import("Compositor.zig");
const zio = @import("zio");
const Win32SocketEvent = @import("server/Win32SocketEvent.zig");
