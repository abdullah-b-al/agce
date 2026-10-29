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

    var mux: *Mux = try .create(io, gpa, &environ_map);
    defer mux.destroy();

    var tick: compositor.Tick = .init(mux.compositor);
    defer tick.deinit();

    while (!exit) {
        const poll_result = try compositor.poll(
            tick.arena.allocator(),
            mux.compositor,
            .none,
        );

        if (poll_result.dispatch) {
            mux.dispatch();
        }

        try compositor.tick(&tick, poll_result);

        mux.flush();
        mux.windows_destroy_if_closed();
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
const compositor = @import("compositor");
const Compositor = compositor.Compositor;
const Server = compositor.Server;
const zio = @import("zio");
const cwl = @import("wayland").client.wl;
const Mux = @import("Mux.zig");
