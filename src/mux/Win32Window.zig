const Window = @This();

handle: win32_foundation.HWND,

pub fn init(
    mux: *Mux,
    requested_size: ptypes.Size,
) !Window {
    const handle = win32_win.CreateWindowExW(
        .{},

        mux.win32.window_class.lpszClassName,
        std.unicode.utf8ToUtf16LeStringLiteral("agce"),

        .{
            .TABSTOP = 1,
            .GROUP = 1,
            .THICKFRAME = 1,
            .SYSMENU = 1,
            .DLGFRAME = 1,
            .BORDER = 1,
            .VISIBLE = 1,
            .CLIPCHILDREN = 1,
        },

        win32_win.CW_USEDEFAULT,
        win32_win.CW_USEDEFAULT,
        requested_size.width,
        requested_size.height,

        null,
        null,
        mux.win32.hinstance,
        null,
    ) orelse {
        const err = win32_foundation.GetLastError();
        log.err("{}", .{err});
        return error.FailedToCreateWindow;
    };

    const ilong: isize = @bitCast(@intFromPtr(mux));

    _ = win32_win.SetWindowLongPtrW(handle, .P_USERDATA, ilong);

    return .{ .handle = handle };
}

pub fn deinit(win: *Window) void {
    _ = win32_win.DestroyWindow(win.handle);
}

pub fn window_proc(
    hwnd: win32_foundation.HWND,
    msg: u32,
    wparam: win32_foundation.WPARAM,
    lparam: win32_foundation.LPARAM,
) callconv(.winapi) win32_foundation.LRESULT {
    const long: usize = @intCast(win32_win.GetWindowLongPtrW(hwnd, .P_USERDATA));

    // Window has not been created yet. Pass through msg
    if (long == 0) {
        return win32_win.DefWindowProcW(hwnd, msg, wparam, lparam);
    }

    const mux: *Mux = @ptrFromInt(long);

    if (mux.destroy_started) {
        return win32_win.DefWindowProcW(hwnd, msg, wparam, lparam);
    }

    const win = blk: {
        for (mux.windows.values()) |win| {
            if (hwnd == win.win32.handle) break :blk win;
        }

        // Window has been removed. Pass through msg
        return win32_win.DefWindowProcW(hwnd, msg, wparam, lparam);
    };

    switch (msg) {
        win32_win.WM_SETFOCUS => {
            // Never focus the window, reset focus to the viewport.
            if (mux.compositor.key_of_focused_viewport_keyboard()) |focused| {
                const child_handle = mux.compositor.backend_handle_from_viewport_key(focused).?;
                _ = win32_kbm.SetFocus(@ptrCast(child_handle));
            }

            mux.compositor.window_focused_by_keyboard(win.viewport_key);
            return 0;
        },
        win32_win.WM_SIZE => {
            const low: isize = lparam & 0xFFFF;
            const high: isize = (lparam >> 16) & 0xFFFF;
            const w: i16 = @truncate(low);
            const h: i16 = @truncate(high);
            const size: ptypes.Size = .{ .width = w, .height = h };

            mux.compositor.viewport_resize(win.viewport_key, size) catch {};
            return win32_win.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        win32_win.WM_CLOSE => {
            mux.compositor.viewport_should_close(win.viewport_key) catch return 0;
            return 0;
        },

        else => {},
    }

    return win32_win.DefWindowProcW(hwnd, msg, wparam, lparam);
}
const std = @import("std");
const log = std.log.scoped(.Mux);
const ptypes = @import("protocol").types;
const win32_foundation = @import("win32").foundation;
const win32_win = @import("win32").ui.windows_and_messaging;
const Mux = @import("Mux.zig");
const win32_kbm = @import("win32").ui.input.keyboard_and_mouse;
