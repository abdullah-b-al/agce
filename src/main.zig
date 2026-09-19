var exit = false;

pub fn main(init: std.process.Init.Minimal) !void {
    var debug: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug.deinit();
    const gpa = debug.allocator();

    var environ_map = try init.environ.createMap(gpa);
    defer environ_map.deinit();
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();

    switch (os) {
        .linux => {
            const sigaction: std.os.linux.Sigaction = .{
                .handler = .{ .handler = &interrupt_handler },
                .mask = @splat(0),
                .flags = 0,
            };
            const result = std.os.linux.errno(std.os.linux.sigaction(.INT, &sigaction, null));
            switch (result) {
                .SUCCESS => {},
                else => |e| log.err("{t}: Sigaction interrupt handler failure!", .{e}),
            }
        },
        else => {},
    }

    const ws: *WindowSystem = try .create(io, gpa);
    defer ws.destroy();

    const server = try Server.create(io, &environ_map, gpa);
    defer server.destroy();

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    if (!arena.reset(.{ .retain_with_limit = 1024 * 1024 })) {
        return error.OutOfMemory;
    }

    while (!exit) {
        _ = arena.reset(.{ .retain_with_limit = 1024 * 1024 });
        try tick(arena.allocator(), ws, server, .none);
    }
}

const Poll = struct {
    compositor: bool,
    accept: bool,
    clients: []Server.MessageSource,
};

fn poll(arena: std.mem.Allocator, ws: *WindowSystem, server: *const Server, timeout: Io.Timeout) !Poll {
    std.debug.assert(timeout != .deadline);

    const Pollfd, const POLL = switch (os) {
        .linux => .{ std.os.linux.pollfd, std.os.linux.POLL },
        .windows => .{ zio.os.windows.pollfd, zio.os.windows.POLL },
        else => comptime unreachable,
    };

    const fds_len = switch (os) {
        .linux => server.clients.count() + 2,
        .windows => server.clients.count() + 1,
        else => comptime unreachable,
    };
    const fds = try arena.alloc(Pollfd, fds_len);
    var clients: std.ArrayList(Server.MessageSource) = try .initCapacity(arena, server.clients.count());

    const events = switch (os) {
        .linux => POLL.IN | POLL.HUP,
        .windows => POLL.IN,
        else => comptime unreachable,
    };

    for (fds) |*fd| {
        fd.* = .{
            .fd = undefined,
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
        else => {},
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
        .none => if (os == .windows) -1 else std.math.maxInt(i32),
        .duration => |d| @truncate(d.raw.toMilliseconds()),
        .deadline => unreachable,
    };
    const poll_result: isize = switch (os) {
        .linux => @bitCast(std.os.linux.poll(fds.ptr, fds.len, ms)),
        .windows => zio.os.windows.WSAPoll(fds.ptr, @intCast(fds.len), ms),
        else => comptime unreachable,
    };

    if (poll_result == 0) return error.Timeout;

    if (poll_result < 0) {
        if (os == .windows) {
            log.err("WSA {}", .{win_sock.WSAGetLastError()});
        }
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

    const compositor = if (ws.native_tag() == .wayland)
        (fds[display_i].revents & POLL.IN) != 0
    else
        false;

    const accept = (fds[server_socket_i].revents & POLL.IN) != 0;
    return .{
        .compositor = compositor,
        .accept = accept,
        .clients = clients.items,
    };
}

pub fn tick(arena: std.mem.Allocator, ws: *WindowSystem, server: *Server, poll_timeout: Io.Timeout) !void {
    const server_events_len =
        @typeInfo(Server.Event).@"union".fields.len *
        server.clients.known.count() * 4;

    const ws_events_len =
        @typeInfo(WindowSystem.Event).@"union".fields.len *
        server.clients.known.count() * 4;

    try ws.server_events.ensureTotalCapacityPrecise(ws.gpa, server_events_len);
    try ws.deferred_events.ensureTotalCapacityPrecise(ws.gpa, ws_events_len);

    const poll_result = try poll(arena, ws, server, poll_timeout);

    const messages = try server.messages_receive(arena, poll_result.clients);
    const ws_events = try server.messages_handle(arena, messages);
    ws.events_handle(ws_events);

    switch (ws.native_tag()) {
        .wayland => |tag| {
            const wl = tag.window_system(ws);

            if (poll_result.compositor) {
                wl.display_dispatch(ws);
            }
        },
        .win32 => |tag| {
            tag.guard();
            var msg: win32_win.MSG = undefined;

            while (win32_win.PeekMessageA(&msg, null, 0, 0, win32_win.PM_REMOVE) > 0) {
                _ = win32_win.TranslateMessage(&msg);
                _ = win32_win.DispatchMessageA(&msg);
            }
        },
    }

    ws.events_handle(ws.deferred_events.items);
    ws.deferred_events.clearRetainingCapacity();

    server.events_handle(ws.server_events.items);
    ws.server_events.clearRetainingCapacity();

    if (poll_result.accept) {
        if (server.server.accept(.{})) |stream| {
            try server.handle_event(.{ .unknown_client_connected = stream });
        } else |err| {
            log.err("Accept client failed {}", .{err});
        }
    }

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
}

pub fn interrupt_handler(sig: std.os.linux.SIG) callconv(.c) void {
    switch (sig) {
        .INT => {
            exit = true;
        },
        else => unreachable,
    }
}

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const Wayland = @import("wayland/Wayland.zig");
const Win32 = @import("win32/Win32.zig");
const WindowSystem = @import("WindowSystem.zig");
const win32_win = @import("win32").ui.windows_and_messaging;
const Server = @import("server/Server.zig");
const utils = @import("utils");
const c_linux = @import("c_linux");
const log = std.log.scoped(.main);
const os = @import("builtin").os.tag;
const Clients = @import("server/Clients.zig");
const ClientID = Clients.ClientID;
const win32_threading = @import("win32").system.threading;
const zio = @import("zio");
const win_sock = @import("win32").networking.win_sock;
