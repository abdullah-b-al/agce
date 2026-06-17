pub fn main(init: std.process.Init) !void {
    if (@import("builtin").os.tag != .linux) {
        @compileError("Unsupported OS");
    }

    const state = try wayland.init(init.gpa, init.io);
    defer wayland.deinit(state);
    try main_wayland(state);
}

pub fn wWinMain(
    instance: @import("win32").foundation.HINSTANCE,
    _: ?@import("win32").foundation.HINSTANCE,
    _: @import("win32").foundation.PWSTR,
    cmd_show: c_int,
) c_int {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();

    var state = win32.init(debug_allocator.allocator(), instance, cmd_show) catch return 1;
    defer win32.deinit(&state);

    var threaded = std.Io.Threaded.init(debug_allocator.allocator(), .{});
    defer threaded.deinit();
    main_win32(&state) catch return 1;

    return 0;
}

pub fn main_wayland(state: *wayland.State) !void {
    try wayland.window_create(state);
    try wayland.window_create(state);

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

pub fn main_win32(state: *win32.State) !void {
    try win32.window_create(state);
    try win32.window_create(state);

    while (state.windows.items.len != 0) {
        for (state.windows.items) |*window| {
            if (!window.shown) {
                win32.window_show(window, state.cmd_show);
            }
        }

        for (state.windows.items) |*window| {
            var msg: win.MSG = undefined;
            while (win.PeekMessageA(&msg, window.handle, 0, 0, .{ .REMOVE = 1 }) != 0) {
                _ = win.TranslateMessage(&msg);
                _ = win.DispatchMessageA(&msg);
            }
        }

        for (state.windows.items) |*window| {
            win32.render(window);
        }

        var i = state.windows.items.len;
        while (i > 0) {
            i -= 1;
            const window = &state.windows.items[i];
            if (window.exit) {
                _ = win.CloseWindow(window.handle);
                window.deinit(state.gpa);
                _ = state.windows.orderedRemove(i);
            }
        }
    }
}

const std = @import("std");
const Io = std.Io;
const wayland = @import("window_system/wayland.zig");
const win32 = @import("window_system/win32.zig");
const win = @import("win32").ui.windows_and_messaging;
