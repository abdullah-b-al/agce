fn main_common(
    io: Io,
    gpa: std.mem.Allocator,
    environ_map: *std.process.Environ.Map,
    ws: *WindowSystem,
) !void {
    var group: Io.Group = .init;
    const server = Server.create(io, environ_map, gpa, ws.event_queue) catch |err| switch (err) {
        else => {
            var path_buf: [constants.socket_max_path]u8 = undefined;
            const path = utils.unix_address_path(environ_map, &path_buf);
            log.err("{}: {s}", .{ err, path });
            return err;
        },
    };
    defer server.destroy();

    try group.concurrent(io, main_server, .{server});
    try group.concurrent(io, accept_clients, .{server});

    switch (ws.native) {
        .wayland => {
            if (os_tag == .linux) {
                try group.concurrent(io, notify_when_wayland_event_arrives, .{
                    ws.event_queue,
                    ws.native.wayland.display.getFd(),
                });

                main_wayland(ws);
            }
        },
        .win32 => {
            try group.await(io);
        },
    }
}

pub fn main(init: std.process.Init) !void {
    if (@import("builtin").os.tag != .linux) {
        @compileError("Unsupported OS");
    }

    const ws: *WindowSystem = try .init_wayland(init.io, init.gpa);
    try main_common(init.io, init.gpa, init.environ_map, ws);
}

pub fn wWinMain(
    instance: @import("win32").foundation.HINSTANCE,
    _: ?@import("win32").foundation.HINSTANCE,
    _: @import("win32").foundation.PWSTR,
    cmd_show: c_int,
) c_int {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    // defer _ = debug_allocator.deinit();
    const gpa = debug_allocator.allocator();

    var threaded: Io.Threaded = .init(gpa, .{});
    const io = threaded.io();

    const environ = threaded.environ.process_environ;
    var environ_map = std.process.Environ.createMap(environ, gpa) catch return 1;
    defer environ_map.deinit();

    const ws: *WindowSystem = WindowSystem.init_win32(io, gpa, instance, cmd_show) catch |err| {
        log.err("{}", .{err});
        return 1;
    };
    defer ws.native.win32.deinit();

    main_common(io, gpa, &environ_map, ws) catch return 1;

    return 0;
}

fn notify_when_wayland_event_arrives(event_queue: *event.EventQueue, fd: c_int) void {
    var polls = [_]std.os.linux.pollfd{
        .{
            .fd = fd,
            .events = std.os.linux.POLL.IN,
            .revents = 0,
        },
    };

    var result = event.EventResultQueue.init(event_queue.io, event_queue.gpa) catch unreachable;

    while (true) {
        const poll = std.os.linux.poll(&polls, @intCast(polls.len), -1);
        if (poll > 0) {
            event_queue.put(.{ .wayland_dispatch = .{ .result_queue = &result } });
            // Wait for the main thread to finish processing the compositers events
            _ = result.get();
        }
    }
}

fn main_wayland(ws: *WindowSystem) void {
    const wl = ws.native.wayland;
    while (true) {
        const e = ws.event_queue.get();
        ws.event_handle(e) catch |err| {
            log.err("event_handle {}", .{err});
        };

        var i: usize = wl.windows.count();
        while (i > 0) {
            i -= 1;
            const win = wl.windows.values()[i];
            if (win.configured and !win.running) {
                // TODO: Proper deinit
                win.destroy();
                _ = wl.windows.orderedRemove(win.base.id);
            }
        }
    }
}

fn main_win32(ws: *WindowSystem) !void {
    const win32 = ws.native.win32;

    while (win32.windows.items.len != 0) {
        for (win32.windows.items) |*window| {
            if (!window.shown) {
                win32.window_show(window, win32.cmd_show);
            }
        }

        for (win32.windows.items) |*window| {
            var msg: win32_win.MSG = undefined;
            while (win32_win.PeekMessageA(&msg, window.handle, 0, 0, .{ .REMOVE = 1 }) != 0) {
                _ = win32_win.TranslateMessage(&msg);
                _ = win32_win.DispatchMessageA(&msg);
            }
        }

        for (win32.windows.items) |*window| {
            win32.render(window);
        }

        var i = win32.windows.items.len;
        while (i > 0) {
            i -= 1;
            const window = &win32.windows.items[i];
            if (window.exit) {
                _ = win32_win.CloseWindow(window.handle);
                window.deinit(win32.gpa);
                _ = win32.windows.orderedRemove(i);
            }
        }
    }
}

fn accept_clients(server: *Server) void {
    while (true) {
        // TODO: Better error handling
        server.clients.ensure_unused_capacity(server.io, server.gpa, 1) catch continue;
        const stream = server.server.accept(server.io) catch |err| {
            log.err("Failed to accept client {}\n", .{err});
            continue;
        };

        server.clients.add_assume_capacity(server.io, stream);
    }
}

fn main_server(server: *Server) void {
    const io = server.io;

    var arena_instance: std.heap.ArenaAllocator = .init(server.gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    while (true) {
        _ = arena_instance.reset(.free_all);

        server.clients.lock(io);
        defer server.clients.unlock(io);

        var i = server.clients.map.count();
        while (i > 0) {
            i -= 1;

            const id, const client = .{
                server.clients.map.keys()[i], &server.clients.map.values()[i],
            };

            const timeout: Io.Timeout =
                .{ .duration = .{ .raw = .fromMilliseconds(1), .clock = .awake } };

            const maybe_message = messaging.message_receive(io, arena, client.stream, timeout) catch |err|
                switch (err) {
                    error.HeaderInvalidFormat,
                    error.HeaderInvalidMessageTag,
                    error.ConnectionClosed,
                    => {
                        log.err("{} closing client\n", .{err});
                        client.stream.close(io);
                        _ = server.clients.map.orderedRemove(id);
                        continue;
                    },
                    else => {
                        log.err("Failed to receive message {}\n", .{err});
                        continue;
                    },
                };

            if (maybe_message) |message| {
                if (server.window_system_event_from_message(client, message)) |e| {
                    server.ws_event_queue.put(e);
                    log.debug("Server dispatched event {}", .{e});
                } else |err| {
                    log.err("{}", .{err});
                }
            }
        }
    }
}

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const Wayland = @import("window_system/Wayland.zig");
const Win32 = @import("window_system/Win32.zig");
const WindowSystem = @import("window_system/WindowSystem.zig");
const win32_win = @import("win32").ui.windows_and_messaging;
const Server = @import("server/Server.zig");
const constants = @import("constants.zig");
const utils = @import("server/utils.zig");
const messaging = @import("server/messaging.zig");
const Message = messaging.Message;
const c_linux = @import("c_linux");
const event = @import("window_system/event.zig");
const log = std.log.scoped(.main);
const os_tag = @import("builtin").os.tag;
