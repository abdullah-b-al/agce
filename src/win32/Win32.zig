const Win32 = @This();

gpa: std.mem.Allocator,

instance: win32_foundation.HINSTANCE,
class_window: win32_win.WNDCLASSA,
class_viewport: win32_win.WNDCLASSA,

pub fn create(ws: *WindowSystem, instance: win32_foundation.HINSTANCE) !*Win32 {
    const ptr = try ws.gpa.create(Win32);
    errdefer ws.gpa.destroy(ptr);

    const class_window: win32_win.WNDCLASSA = .{
        .style = .{},
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .lpszMenuName = null,
        .hIcon = null,
        .hCursor = null,
        .hbrBackground = null,
        .lpfnWndProc = window_proc,
        .hInstance = instance,
        .lpszClassName = ws.class_of_window,
    };

    const class_viewport: win32_win.WNDCLASSA = .{
        .style = .{},
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .lpszMenuName = null,
        .hIcon = null,
        .hCursor = null,
        .hbrBackground = null,
        .lpfnWndProc = viewport_proc,
        .hInstance = instance,
        .lpszClassName = ws.class_of_viewport,
    };

    if (win32_win.RegisterClassA(&class_window) == 0) {
        const err = win32_foundation.GetLastError();
        log.err("{}", .{err});
        return error.FailedToRegisterClass;
    }

    if (win32_win.RegisterClassA(&class_viewport) == 0) {
        const err = win32_foundation.GetLastError();
        log.err("{}", .{err});
        return error.FailedToRegisterClass;
    }

    ptr.* = .{
        .gpa = ws.gpa,
        .instance = instance,
        .class_window = class_window,
        .class_viewport = class_viewport,
    };

    return ptr;
}

pub fn destroy(win32: *Win32) void {
    win32.gpa.destroy(win32);
}

fn window_proc(
    hwnd: win32_foundation.HWND,
    msg: u32,
    wparam: win32_foundation.WPARAM,
    lparam: win32_foundation.LPARAM,
) callconv(.winapi) win32_foundation.LRESULT {
    const long: usize = @intCast(win32_win.GetWindowLongPtrA(hwnd, .P_USERDATA));

    // Window has not been created yet. Pass through msg
    if (long == 0) {
        return win32_win.DefWindowProcA(hwnd, msg, wparam, lparam);
    }

    const ws: *WindowSystem = @ptrFromInt(long);

    if (ws.destroy_started) {
        return win32_win.DefWindowProcA(hwnd, msg, wparam, lparam);
    }

    const win = blk: {
        for (ws.windows.values()) |win| {
            if (hwnd == win.win32.handle) break :blk win;
        }

        // Window has been removed. Pass through msg
        return win32_win.DefWindowProcA(hwnd, msg, wparam, lparam);
    };

    switch (msg) {
        win32_win.WM_SIZE => {
            const low: isize = lparam & 0xFFFF;
            const high: isize = (lparam >> 16) & 0xFFFF;
            const w: i16 = @truncate(low);
            const h: i16 = @truncate(high);

            ws.deferred_events.appendAssumeCapacity(.{
                .window_resize_by_display_server = .{
                    .id = win.id,
                    .size = .{ .width = w, .height = h },
                },
            });
            return 0;
        },

        else => {},
    }

    return win32_win.DefWindowProcA(hwnd, msg, wparam, lparam);
}

fn viewport_proc(
    hwnd: win32_foundation.HWND,
    msg: u32,
    wparam: win32_foundation.WPARAM,
    lparam: win32_foundation.LPARAM,
) callconv(.winapi) win32_foundation.LRESULT {
    const long: usize = @intCast(win32_win.GetWindowLongPtrA(hwnd, .P_USERDATA));

    // Window has not been created yet. Pass through msg
    if (long == 0) {
        return win32_win.DefWindowProcA(hwnd, msg, wparam, lparam);
    }

    const ws: *WindowSystem = @ptrFromInt(long);

    if (ws.destroy_started) {
        return win32_win.DefWindowProcA(hwnd, msg, wparam, lparam);
    }

    const win, const vp, const vp_key = blk: {
        for (ws.windows.values()) |win| {
            const vp = ws.viewport_from_key(win.viewport_key) orelse continue;
            if (vp.win32.child_window_handle == hwnd) break :blk .{ win, vp, win.viewport_key };
        }

        // Window has been removed. Pass through msg
        return win32_win.DefWindowProcA(hwnd, msg, wparam, lparam);
    };

    switch (msg) {
        win32_win.WM_PAINT => {
            return win32_win.DefWindowProcA(hwnd, msg, wparam, lparam);
        },
        win32_win.WM_CLOSE => {
            ws.server_events.appendAssumeCapacity(.{
                .viewport_close = .{
                    .client_id = vp_key.client_id,
                    .payload = .{
                        .viewport_id = vp_key.viewport_id,
                    },
                },
            });
            return 0;
        },

        win32_win.WM_KEYDOWN => {
            const truncate: @typeInfo(kbm.VIRTUAL_KEY).@"enum".tag_type = @truncate(wparam);
            const key: kbm.VIRTUAL_KEY = @enumFromInt(truncate);
            switch (key) {
                else => {},
            }
            return 0;
        },

        // Child window should not get these events
        win32_win.WM_SIZING, win32_win.WM_SIZE => {},

        inline win32_win.WM_MOUSEMOVE,
        win32_win.WM_LBUTTONDOWN,
        win32_win.WM_LBUTTONUP,
        win32_win.WM_RBUTTONDOWN,
        win32_win.WM_RBUTTONUP,
        => |tag| {
            ws.deferred_events.appendAssumeCapacity(.{
                .mouse_enter = .{
                    .client_id = vp_key.client_id,
                    .viewport_id = vp_key.viewport_id,
                    .window_id = win.id,
                },
            });

            if (!vp.win32.mouse_tracking) {
                vp.win32.mouse_tracking = true;
                var arg: kbm.TRACKMOUSEEVENT = .{
                    .cbSize = @sizeOf(kbm.TRACKMOUSEEVENT),
                    .dwFlags = .{ .LEAVE = 1 },
                    .hwndTrack = hwnd,
                    .dwHoverTime = 0,
                };
                const result = kbm.TrackMouseEvent(&arg);
                if (result == 0) {
                    log.err("TrackMouseEvent failed", .{});
                }
            }

            const event: WindowSystem.Event = blk: switch (tag) {
                win32_win.WM_MOUSEMOVE => {
                    const x: i32 = @truncate(lparam & 0xFFFF);
                    const y: i32 = @truncate((lparam >> 16) & 0xFFFF);

                    break :blk .{
                        .mouse_motion = .{ .x = @floatFromInt(x), .y = @floatFromInt(y) },
                    };
                },
                win32_win.WM_LBUTTONDOWN => .{
                    .mouse_button = .{ .button = .left, .state = .pressed },
                },
                win32_win.WM_LBUTTONUP => .{
                    .mouse_button = .{ .button = .left, .state = .released },
                },
                win32_win.WM_RBUTTONDOWN => .{
                    .mouse_button = .{ .button = .right, .state = .pressed },
                },
                win32_win.WM_RBUTTONUP => .{
                    .mouse_button = .{ .button = .right, .state = .released },
                },
                else => comptime unreachable,
            };

            ws.deferred_events.appendAssumeCapacity(event);

            return 0;
        },

        win32_controls.WM_MOUSELEAVE => {
            vp.win32.mouse_tracking = false;
            ws.deferred_events.appendAssumeCapacity(.{
                .mouse_leave = .{
                    .client_id = vp_key.client_id,
                    .viewport_id = vp_key.viewport_id,
                    .window_id = win.id,
                },
            });
            return 0;
        },

        else => {},
    }

    return win32_win.DefWindowProcA(hwnd, msg, wparam, lparam);
}
pub fn render_buffer_cpu(
    _: *Win32,
    hdc: win32_gdi.HDC,
    vp: *WindowSystem.Viewport,
    cpu: *const Buffer.Cpu,
) void {
    var bitmap_info: win32_gdi.BITMAPINFO = undefined;

    bitmap_info.bmiHeader.biSize = @sizeOf(win32_gdi.BITMAPINFOHEADER);
    bitmap_info.bmiHeader.biWidth = cpu.size.width;
    bitmap_info.bmiHeader.biHeight = -cpu.size.height;
    bitmap_info.bmiHeader.biPlanes = 1;

    switch (cpu.format) {
        .argb8888 => {
            bitmap_info.bmiHeader.biBitCount = 32;
            bitmap_info.bmiHeader.biCompression = win32_gdi.BI_RGB;
        },
    }

    // zig fmt: off
    _ = win32_gdi.StretchDIBits(
        hdc,
        0, 0, vp.render_size.width, vp.render_size.height,
        0, 0, vp.render_size.width, vp.render_size.height,

        cpu.pixels,
        &bitmap_info,
        win32_gdi.DIB_RGB_COLORS,
        win32_gdi.SRCCOPY,
    );
    // zig fmt: on

}

pub const Buffer = union(enum) {
    cpu: Cpu,

    pub fn deinit(buffer: *Buffer) void {
        switch (buffer.*) {
            .cpu => |cpu| {
                _ = win32_memory.UnmapViewOfFile(cpu.pixels);
                _ = win32_foundation.CloseHandle(@ptrFromInt(@intFromEnum(cpu.handle)));
            },
        }
    }

    pub const Cpu = struct {
        handle: ptypes.CpuBufferHandle,
        pixels: *anyopaque,
        size: ptypes.Size,
        format: ptypes.BufferFormat,
    };
};

pub const HINSTANCE = win32_foundation.HINSTANCE;
pub const Window = @import("Window.zig");
pub const Viewport = @import("Viewport.zig");

const std = @import("std");
const Io = std.Io;
const win32_win = @import("win32").ui.windows_and_messaging;
const win32_foundation = @import("win32").foundation;
const win32_memory = @import("win32").system.memory;
const kbm = @import("win32").ui.input.keyboard_and_mouse;
const win32_controls = @import("win32").ui.controls;
const WindowSystem = @import("../WindowSystem.zig");
const ViewportKey = WindowSystem.ViewportKey;
const BufferID = ptypes.BufferID;
const ptypes = @import("protocol").types;
const win32_gdi = @import("win32").graphics.gdi;
const log = std.log.scoped(.win32);
