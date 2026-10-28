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

    const ws: *WindowSystem = try .create(io, gpa, "agce-mux");
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
        try window_system.tick(arena.allocator(), ws, server, .none);
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
const win32_win = @import("win32").ui.windows_and_messaging;
const win32_foundation = @import("win32").foundation;
const win32_programming = @import("win32").system.windows_programming;
const utils = @import("utils");
const c_linux = @import("c_linux");
const log = std.log.scoped(.main);
const os = @import("builtin").os.tag;
const win32_threading = @import("win32").system.threading;
const win_sock = @import("win32").networking.win_sock;
const window_system = @import("window_system");
const WindowSystem = window_system.WindowSystem;
const Server = window_system.Server;
const zio = @import("zio");
