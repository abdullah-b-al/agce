fn main_common(
    io: Io,
    gpa: std.mem.Allocator,
    environ_map: *std.process.Environ.Map,
    dispatch: *Dispatch,
    ws: *WindowSystem,
) !void {
    var group: Io.Group = .init;

    const server = try Server.create(io, environ_map, gpa, dispatch);
    defer server.destroy();

    try group.concurrent(io, main_server, .{server});

    switch (ws.native) {
        .wayland => {
            if (os_tag == .linux) {
                try group.concurrent(io, notify_when_wayland_event_arrives, .{
                    dispatch,
                    ws.native.wayland.display.getFd(),
                });

                main_wayland(ws) catch |err| switch (err) {
                    error.Canceled => {},
                };
            }
        },
        .win32 => {
            try group.await(io);
        },
    }

    group.cancel(io);
}

pub fn main(init: std.process.Init) !void {
    if (@import("builtin").os.tag != .linux) {
        @compileError("Unsupported OS");
    }

    const dispatch: *Dispatch = try .create(init.io, init.gpa);
    const ws: *WindowSystem = try .init_wayland(init.io, init.gpa, dispatch);
    try main_common(init.io, init.gpa, init.environ_map, dispatch, ws);
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

    const dispatch = Dispatch.create(io, gpa) catch return 1;
    const ws: *WindowSystem = WindowSystem.init_win32(
        io,
        gpa,
        instance,
        cmd_show,
        dispatch,
    ) catch |err| {
        log.err("{}", .{err});
        return 1;
    };
    defer ws.native.win32.deinit();

    main_common(io, gpa, &environ_map, dispatch, ws) catch return 1;

    return 0;
}

fn notify_when_wayland_event_arrives(dispatch: *Dispatch, fd: c_int) error{Canceled}!void {
    var polls = [_]std.os.linux.pollfd{
        .{
            .fd = fd,
            .events = std.os.linux.POLL.IN,
            .revents = 0,
        },
    };

    var result = Dispatch.WindowSystemResultQueue.init(dispatch.gpa) catch unreachable;

    while (true) {
        const poll = std.os.linux.poll(&polls, @intCast(polls.len), -1);
        if (poll > 0) {
            try dispatch.window_system_put(.{ .wayland_dispatch = .{ .result_queue = &result } });

            // Wait for the main thread to finish processing the compositer's events
            _ = result.queue.getOne(dispatch.io) catch |err| switch (err) {
                error.Closed => unreachable,
                error.Canceled => |e| return e,
            };
        }
    }
}

fn main_wayland(ws: *WindowSystem) error{Canceled}!void {
    const wl = ws.native.wayland;
    while (true) {
        const e = try ws.dispatch.window_system_get();
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
                _ = wl.windows.orderedRemove(win.id);
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

fn main_server(server: *Server) error{Canceled}!void {
    const tm = server.task_master;

    tm.start(server, .client_connected);
    tm.start(server, .server_has_event);
    tm.start(server, .client_has_message);

    while (true) {
        const selected = try tm.await();
        try tm.handle(server, selected);
        tm.start(server, selected); // restart
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
const constants = @import("constants.zig");
const utils = @import("server/utils.zig");
const c_linux = @import("c_linux");
const client_to_server = @import("protocol/client_to_server.zig");
const server_to_client = @import("protocol/server_to_client.zig");
const log = std.log.scoped(.main);
const os_tag = @import("builtin").os.tag;
const Dispatch = @import("Dispatch.zig");
const Clients = @import("server/Clients.zig");
const ClientID = Clients.ClientID;
