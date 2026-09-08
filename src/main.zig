var global_dispatch: *Dispatch = undefined;

pub fn main(init: std.process.Init) !void {
    global_dispatch = try .create(init.io, init.gpa);
    defer global_dispatch.destroy();

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

            break :blk try .create_wayland(init.io, init.gpa, global_dispatch);
        },
        WindowSystem.W32 => {
            const hinstance = @import("win32").system.library_loader.GetModuleHandleW(null).?;
            break :blk try .create_win32(
                init.io,
                init.gpa,
                hinstance,
                global_dispatch,
            );
        },
        else => @compileError("Unsupported OS"),
    };

    defer ws.destroy();

    const server = try Server.create(init.io, init.environ_map, init.gpa, global_dispatch);
    defer server.destroy();

    var group: Io.Group = .init;

    try group.concurrent(init.io, main_server, .{server});

    switch (WindowSystem.Native) {
        WindowSystem.Linux => {
            try group.concurrent(init.io, notify_when_wayland_event_arrives, .{
                ws.native.wayland.display.getFd(),
            });

            main_wayland(ws) catch |err| switch (err) {
                error.Canceled => {},
            };
        },
        WindowSystem.W32 => {
            try group.await(init.io);
        },
        else => comptime unreachable,
    }

    group.cancel(init.io);
}

fn notify_when_wayland_event_arrives(fd: c_int) error{Canceled}!void {
    defer log.info("{s} exited", .{@src().fn_name});

    var msg_buf: [1]net.IncomingMessage = undefined;
    var buf: [1]u8 = undefined;

    const op: Io.Operation = .{
        .net_receive = .{
            .socket_handle = fd,
            .message_buffer = &msg_buf,
            .data_buffer = &buf,
            .flags = .{ .peek = true },
        },
    };

    while (true) {
        const maybe_err, _ = (try global_dispatch.io.operate(op)).net_receive;
        if (maybe_err) |err| {
            switch (err) {
                error.Canceled => |canceled| return canceled,
                else => continue,
            }
        } else {
            var signal: Io.Event = .unset;
            try global_dispatch.window_system_put(@src(), .{
                .wayland_dispatch = .{ .signal = &signal },
            });

            // Wait for the main thread to finish processing the compositer's events
            try signal.wait(global_dispatch.io);
        }
    }
}

fn main_wayland(ws: *WindowSystem) error{Canceled}!void {
    defer log.info("{s} exited", .{@src().fn_name});

    while (true) {
        const e = try ws.dispatch.window_system_get();
        ws.event_handle(e) catch |err| switch (err) {
            error.Canceled => |canceled| return canceled,
            error.Exit => return,
            else => {
                log.err("event_handle {}", .{err});
            },
        };
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
    defer log.info("{s} exited", .{@src().fn_name});

    var accept_thread = server.io.concurrent(
        accept_new_clients,
        .{ global_dispatch, &server.server },
    ) catch |err| std.process.fatal("{}", .{err});
    defer accept_thread.cancel(server.io) catch {};

    var exit = false;
    while (!exit) {
        var select_buffer: [2]Server.Task = undefined;
        var select: Io.Select(Server.Task) = .init(server.io, &select_buffer);

        select.concurrent(
            .get_events,
            Server.Task.fn_get_events,
            .{ server, server.arena_acquire() },
        ) catch |err| std.process.fatal("{}", .{err});

        if (server.clients.count() > 0) {
            select.concurrent(
                .get_client_messages,
                Server.Task.fn_get_client_messages,
                .{ server, server.arena_acquire() },
            ) catch |err| std.process.fatal("{}", .{err});
        }

        // These tasks modify the state of the server.
        // Cancel before handling to prevent race conditions
        const first = select.await();
        const second = select.cancel();
        std.debug.assert(select.cancel() == null);

        // delay handling errors as to not leak resources of the second
        if (first) |f| {
            f.handle(server) catch |err| switch (err) {
                error.Canceled, error.Exit => exit = true,
                error.OutOfMemory => {},
            };
        } else |err| switch (err) {
            error.Canceled => exit = true,
        }

        if (second) |s| {
            s.handle(server) catch |err| switch (err) {
                error.Exit => exit = true,
                error.Canceled, // always canceled
                error.OutOfMemory,
                => {},
            };
        }
    }
}

pub fn interrupt_handler(sig: std.os.linux.SIG) callconv(.c) void {
    switch (sig) {
        .INT => {
            global_dispatch.window_system_put(@src(), .exit) catch {};
            global_dispatch.server_put(@src(), .exit) catch {};
        },
        else => unreachable,
    }
}

fn accept_new_clients(dispatch: *Dispatch, server: *net.Server) error{Canceled}!void {
    while (true) {
        const stream = server.accept(dispatch.io) catch |err| switch (err) {
            error.Canceled => |e| return e,
            else => {
                log.err("Accept client failed {}", .{err});
                continue;
            },
        };

        try dispatch.server_put(@src(), .{ .unknown_client_connected = stream });
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
const Dispatch = @import("Dispatch.zig");
const Clients = @import("server/Clients.zig");
const ClientID = Clients.ClientID;
