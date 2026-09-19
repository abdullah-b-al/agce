const Viewport = @This();

base: *const WindowSystem.Viewport,
child_window_handle: win32_foundation.HWND,

pub fn init(
    ws: *WindowSystem,
    win32: *Win32,
    base: *const WindowSystem.Viewport,
    parent: ParentOfViewport,
    client_id: ClientID,
) !Viewport {
    _ = client_id;

    const parent_handle = switch (parent) {
        .window => |win| win.win32.handle,
        .viewport => |vp| vp.win32.child_window_handle,
    };
    const handle = win32_win.CreateWindowExA(
        .{},

        win32.class.lpszClassName,
        "agce-child-window",

        .{
            .CHILD = 1,
            .VISIBLE = 1,
        },

        base.clipping_rect.x,
        base.clipping_rect.y,
        base.clipping_rect.width,
        base.clipping_rect.height,

        parent_handle,
        null,
        win32.instance,
        null,
    ) orelse {
        const err = win32_foundation.GetLastError();
        log.err("{}", .{err});
        return error.FailedToCreateChildWindow;
    };

    const ilong: isize = @bitCast(@intFromPtr(ws));

    // TODO: Check return value
    _ = win32_win.SetWindowLongPtrA(handle, .P_USERDATA, ilong);


    return .{
        .base = base,
        .child_window_handle = handle,
    };
}

const std = @import("std");
const WindowSystem = @import("../WindowSystem.zig");
const ParentOfViewport = WindowSystem.ParentOfViewport;
const ViewportKey = WindowSystem.ViewportKey;
const ptypes = @import("protocol").types;
// const win32 = @import("win32");
const Win32 = @import("Win32.zig");
const ClientID = ptypes.ClientID;
const win32_foundation = @import("win32").foundation;
const win32_win = @import("win32").ui.windows_and_messaging;
const log = std.log.scoped(.Win32);
