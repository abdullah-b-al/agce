const Window = @This();

base: *WindowSystem.Window,

handle: win32_foundation.HWND,

pub fn init(
    win32: *Win32,
    ws: *WindowSystem,
    base: *WindowSystem.Window,
    requested_size: ptypes.Size,
) !Window {
    const handle = win32_win.CreateWindowExA(
        .{},

        win32.class.lpszClassName,
        "agce",

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
        win32.instance,
        null,
    ) orelse {
        const err = win32_foundation.GetLastError();
        log.err("{}", .{err});
        return error.FailedToCreateWindow;
    };

    // const long: usize = @intFromPtr(ws);
    // const ilong: isize = @intCast(long);
    const ilong: isize = @bitCast(@intFromPtr(ws));

    // TODO: Check return value
    _ = win32_win.SetWindowLongPtrA(handle, .P_USERDATA, ilong);

    return .{
        .base = base,
        .handle = handle,
    };
}

pub fn deinit(win: *Window) void {
    _ = win32_win.DestroyWindow(win.handle);
}

const std = @import("std");
const ClientID = @import("../server/Clients.zig").ClientID;
const Viewport = @import("../window_system/Viewport.zig");
const WindowSystem = @import("../WindowSystem.zig");
const ViewportKey = WindowSystem.ViewportKey;
const WindowID = WindowSystem.WindowID;
const log = std.log.scoped(.win32);
const ptypes = @import("protocol").types;
const Win32 = @import("Win32.zig");
const win32_foundation = @import("win32").foundation;
const win32_win = @import("win32").ui.windows_and_messaging;
