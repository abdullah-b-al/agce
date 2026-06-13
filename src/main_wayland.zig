pub fn main(init: std.process.Init) !void {
    const state = try wayland.init(init.gpa, init.io);
    try wayland.new_window(state);
    try wayland.new_window(state);
    defer wayland.deinit(state);

    while (state.windows.list.items.len > 0) {
        var i: usize = state.windows.list.items.len;
        while (i > 0) {
            i -= 1;
            const window = state.windows.list.items[i];
            if (window.configured and !window.running) {
                state.windows.remove(i);
            }
        }

        for (state.windows.list.items) |*window| {
            if (!window.configured) {
                window.surface.commit();
                while (!window.configured) {
                    if (state.display.dispatch() != .SUCCESS) return error.DispatchFailed;
                }

                window.surface.attach(window.buffer.buffer, 0, 0);
                window.surface.commit();
            }
        }

        if (state.display.dispatch() != .SUCCESS) return;
    }
}

const std = @import("std");
const Io = std.Io;
const wayland = @import("wayland.zig");
const wl = @import("wayland").client.wl;
const xdg = @import("wayland").client.xdg;
