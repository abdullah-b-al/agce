var exit = false;

pub fn main(init: std.process.Init) !void {
    const ws: *WindowSystem = blk: switch (WindowSystem.Native) {
        WindowSystem.Linux => {
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

            break :blk try .create_wayland(init.io, init.gpa);
        },
        WindowSystem.W32 => {
            const hinstance = @import("win32").system.library_loader.GetModuleHandleW(null).?;
            break :blk try .create_win32(
                init.io,
                init.gpa,
                hinstance,
            );
        },
        else => @compileError("Unsupported OS"),
    };
    defer ws.destroy();

    const server = try Server.create(init.io, init.environ_map, init.gpa);
    defer server.destroy();

    const display_fd = ws.native.wayland.display.getFd();
    var arena: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena.deinit();

    if (!arena.reset(.{ .retain_with_limit = 1024 * 1024 })) {
        return error.OutOfMemory;
    }

    while (!exit) {
        _ = arena.reset(.{ .retain_with_limit = 1024 * 1024 });

        const server_events_len =
            @typeInfo(Server.Event).@"union".fields.len *
            server.clients.known.count() * 4;

        const ws_events_len =
            @typeInfo(WindowSystem.Event).@"union".fields.len *
            server.clients.known.count() * 4;

        try ws.server_events.ensureUnusedCapacity(ws.gpa, server_events_len);
        try ws.deferred_events.ensureUnusedCapacity(ws.gpa, ws_events_len);

        const poll = try poll_linux_wayland(arena.allocator(), server, display_fd);

        const messages = try server.messages_receive(arena.allocator(), poll.clients);
        const ws_events = try server.messages_handle(arena.allocator(), messages);
        ws.events_handle(ws_events);

        if (poll.compositor) {
            ws.native.wayland.display_dispatch(ws);
        }

        ws.events_handle(ws.deferred_events.items);
        ws.deferred_events.clearRetainingCapacity();

        server.handle_events(ws.server_events.items);
        ws.server_events.clearRetainingCapacity();

        if (poll.accept) {
            if (server.server.accept(init.io)) |stream| {
                try server.handle_event(.{ .unknown_client_connected = stream });
            } else |err| switch (err) {
                error.Canceled => |e| return e,
                else => {
                    log.err("Accept client failed {}", .{err});
                },
            }
        }

        server.clients.remove_closed_known_clients();
        server.clients.remove_promoted_or_closed_unknown_clients();
    }
}

const PollLinuxWayland = struct {
    compositor: bool,
    accept: bool,
    clients: []Server.MessageSource,
};
fn poll_linux_wayland(arena: std.mem.Allocator, server: *const Server, display_fd: c_int) !PollLinuxWayland {
    const fds_len = server.clients.count() + 2;
    const fds = try arena.alloc(std.os.linux.pollfd, fds_len);
    var clients: std.ArrayList(Server.MessageSource) = try .initCapacity(arena, server.clients.count());

    for (fds) |*fd| {
        fd.* = .{ .fd = -1, .events = std.os.linux.POLL.IN, .revents = 0 };
    }

    var i: usize = 0;

    const display_i = i;
    {
        fds[i].fd = display_fd;
        i += 1;
    }

    const server_socket_i = i;
    {
        fds[i].fd = server.server.socket.handle;
        i += 1;
    }

    const known_i = i;
    for (server.clients.known.values()) |c| {
        fds[i].fd = c.stream.socket.handle;
        i += 1;
    }

    const unknown_i = i;
    for (server.clients.unknown.items) |c| {
        fds[i].fd = c.stream.socket.handle;
        i += 1;
    }

    std.debug.assert(i == fds.len);

    const poll_result = std.os.linux.poll(fds.ptr, fds.len, std.math.maxInt(i32));
    std.debug.assert(poll_result != 0); // timeout
    if (poll_result < 0) return;

    for (server.clients.known.values(), 0..) |client, ci| {
        const fd = fds[known_i + ci];
        if ((fd.revents & std.os.linux.POLL.IN) != 0) {
            clients.appendAssumeCapacity(.{ .known = client.id });
        }
    }

    for (server.clients.unknown.items, 0..) |_, ci| {
        const fd = fds[unknown_i + ci];
        if ((fd.revents & std.os.linux.POLL.IN) != 0) {
            clients.appendAssumeCapacity(.{ .unknown = ci });
        }
    }

    const compositor = (fds[display_i].revents & std.os.linux.POLL.IN) != 0;
    const accept = (fds[server_socket_i].revents & std.os.linux.POLL.IN) != 0;
    return .{
        .compositor = compositor,
        .accept = accept,
        .clients = clients.items,
    };
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
const os_tag = @import("builtin").os.tag;
const Clients = @import("server/Clients.zig");
const ClientID = Clients.ClientID;
