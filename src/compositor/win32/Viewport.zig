const Viewport = @This();

base: *const Compositor.Viewport,
child_window_handle: win32_foundation.HWND,
parent_tag: std.meta.Tag(ParentOfViewport),

swap_chain: ?*dxgi.IDXGISwapChain1,

mouse_tracking: bool = false,

pub const InitError = error{
    FailedToCreateChildWindow,
    FailedToCreateDXGISwapChain1,
};
pub fn init(
    com: *Compositor,
    win32: *Win32,
    base: *const Compositor.Viewport,
    parent: ParentOfViewport,
    client_uuid: ClientUUID,
) InitError!Viewport {
    _ = client_uuid;

    const parent_handle = switch (parent) {
        .window => |handle| handle.cast(.win32),
        .viewport => |vp| vp.win32.child_window_handle,
    };
    const handle = win32_win.CreateWindowExW(
        .{},

        win32.class_viewport.lpszClassName,
        std.unicode.utf8ToUtf16LeStringLiteral("agce-child-window"),

        .{
            .CHILD = 1,
            .VISIBLE = 1,
            .CLIPCHILDREN = 1,
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

    const ilong: isize = @bitCast(@intFromPtr(com));

    _ = win32_win.SetWindowLongPtrW(handle, .P_USERDATA, ilong);

    const swap_chain = blk: {
        if (base.buffer_type != .d11) break :blk null;

        var desc: dxgi.DXGI_SWAP_CHAIN_DESC1 = .{
            .Width = @intCast(base.clipping_rect.width),
            .Height = @intCast(base.clipping_rect.height),
            .Format = Win32.buffer_format_to_dxgi_format(base.format),
            .Stereo = 0,
            .SampleDesc = .{ .Count = 1, .Quality = 0 },
            .BufferUsage = dxgi.DXGI_USAGE_RENDER_TARGET_OUTPUT,
            .BufferCount = 2,
            .Scaling = .NONE,
            .SwapEffect = .FLIP_DISCARD,
            .AlphaMode = .IGNORE,
            .Flags = 0,
        };

        break :blk try win32.d11_context.create_swap_chain_for_hwnd(handle, &desc);
    };

    return .{
        .base = base,
        .child_window_handle = handle,
        .parent_tag = parent,
        .swap_chain = swap_chain,
    };
}

pub fn deinit(vp: *Viewport) void {
    if (vp.swap_chain) |swap_chain| {
        _ = swap_chain.IUnknown.Release();
    }

    switch (vp.parent_tag) {
        .window => {
            // HACK: Do not destroy the window if removing the parent fails.
            // In the `embedded` module where the parent is in a different thread,
            // calling DestroyWindow will cause a deadlock as the input threads are attached.
            // I could not find a way to detach them that prevented the deadlock.
            //
            // This only matters if the parent is in a different thread, which
            // is only possible when the parent is a window.

            const result = win32_win.SetParent(vp.child_window_handle, null);
            if (result == null) {
                const err = win32_foundation.GetLastError();
                log.err("Failed to SetParent to null {}. Leaking child window...", .{err});
            } else {
                _ = win32_win.DestroyWindow(vp.child_window_handle);
            }
        },
        .viewport => {
            _ = win32_win.DestroyWindow(vp.child_window_handle);
        },
    }
}

const std = @import("std");
const Compositor = @import("../Compositor.zig");
const ParentOfViewport = Compositor.ParentOfViewport;
const ViewportKey = ptypes.ViewportKey;
const ptypes = @import("protocol").types;
const Win32 = @import("Win32.zig");
const ClientUUID = ptypes.ClientUUID;
const win32_foundation = @import("win32").foundation;
const win32_win = @import("win32").ui.windows_and_messaging;
const dxgi = @import("win32").graphics.dxgi;
const log = std.log.scoped(.win32);
