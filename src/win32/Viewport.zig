const Viewport = @This();

base: *const WindowSystem.Viewport,
child_window_handle: win32_foundation.HWND,
swap_chain: *dxgi.IDXGISwapChain1,

mouse_tracking: bool = false,

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

        win32.class_viewport.lpszClassName,
        "agce-child-window",

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

    const ilong: isize = @bitCast(@intFromPtr(ws));

    // TODO: Check return value
    _ = win32_win.SetWindowLongPtrA(handle, .P_USERDATA, ilong);

    var swap_chain: *dxgi.IDXGISwapChain1 = undefined;

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

    const swap_chain_result = win32.dxgi_factory.CreateSwapChainForHwnd(
        @ptrCast(win32.d11_device),
        handle,
        &desc,
        null,
        null,
        &swap_chain,
    );

    if (swap_chain_result != win32_foundation.S_OK) {
        return error.FailedToCreateDXGISwapChain1;
    }

    return .{
        .base = base,
        .child_window_handle = handle,
        .swap_chain = swap_chain,
    };
}

pub fn deinit(vp: *Viewport) void {
    _ = vp.swap_chain.IUnknown.Release();
    _ = win32_win.DestroyWindow(vp.child_window_handle);
}

const std = @import("std");
const WindowSystem = @import("../WindowSystem.zig");
const ParentOfViewport = WindowSystem.ParentOfViewport;
const ViewportKey = WindowSystem.ViewportKey;
const ptypes = @import("protocol").types;
const Win32 = @import("Win32.zig");
const ClientID = ptypes.ClientID;
const win32_foundation = @import("win32").foundation;
const win32_win = @import("win32").ui.windows_and_messaging;
const dxgi = @import("win32").graphics.dxgi;
const log = std.log.scoped(.win32);
