const Win32 = @This();

gpa: std.mem.Allocator,

instance: win32_foundation.HINSTANCE,
class: win32_win.WNDCLASSA,

pub fn create(ws: *WindowSystem, instance: win32_foundation.HINSTANCE) !*Win32 {
    const ptr = try ws.gpa.create(Win32);
    errdefer ws.gpa.destroy(ptr);

    const wc: win32_win.WNDCLASSA = .{
        .style = .{},
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .lpszMenuName = null,
        .hIcon = null,
        .hCursor = null,
        .hbrBackground = null,
        .lpfnWndProc = window_proc,
        .hInstance = instance,
        .lpszClassName = ws.class,
    };

    if (win32_win.RegisterClassA(&wc) == 0) {
        const err = win32_foundation.GetLastError();
        log.err("{}", .{err});
        return error.FailedToRegisterClass;
    }

    ptr.* = .{
        .gpa = ws.gpa,
        .instance = instance,
        .class = wc,
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
    const win = blk: {
        for (ws.windows.values()) |win| {
            if (win.win32.handle == hwnd) break :blk win;
        }

        log.debug("Maybe the handle refers to a child window, a viewport.\n", .{});
        // Window has been removed. Pass through msg
        return win32_win.DefWindowProcA(hwnd, msg, wparam, lparam);
    };

    switch (msg) {
        win32_win.WM_CLOSE => {
            ws.server_events.appendAssumeCapacity(.{
                .viewport_close = .{
                    .client_id = win.input_focus_keyboard.client_id,
                    .payload = .{
                        .viewport_id = win.input_focus_keyboard.viewport_id,
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

        win32_win.WM_SIZE => {
            const low: isize = lparam & 0xFFFF;
            const high: isize = (lparam >> 16) & 0xFFFF;
            const w: i16 = @truncate(low);
            const h: i16 = @truncate(high);

            log.debug("New width and height {}x{}\n", .{ w, h });
            return 0;
        },
        else => {},
    }

    return win32_win.DefWindowProcA(hwnd, msg, wparam, lparam);
}

pub fn render_buffer_cpu(
    _: *Win32,
    ws: *WindowSystem,
    vp_key: ViewportKey,
    vp: *WindowSystem.Viewport,
    buffer_id: BufferID,
    cpu: *const Buffer.Cpu,
) void {
    const nvp = &vp.win32;
    var bitmap_info: win32_gdi.BITMAPINFO = undefined;

    bitmap_info.bmiHeader.biSize = @sizeOf(win32_gdi.BITMAPINFOHEADER);
    bitmap_info.bmiHeader.biWidth = vp.render_size.width;
    bitmap_info.bmiHeader.biHeight = -vp.render_size.height;
    bitmap_info.bmiHeader.biPlanes = 1;
    bitmap_info.bmiHeader.biBitCount = 32;
    bitmap_info.bmiHeader.biCompression = win32_gdi.BI_RGB;

    const hdc = win32_gdi.GetDC(nvp.child_window_handle);
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

    _ = win32_gdi.ReleaseDC(nvp.child_window_handle, hdc);

    ws.server_events.appendAssumeCapacity(.{ .buffer_released = .{
        .client_id = vp_key.client_id,
        .payload = .{
            .viewport_id = vp_key.viewport_id,
            .buffer_id = buffer_id,
        },
    } });
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
const WindowSystem = @import("../WindowSystem.zig");
const ViewportKey = WindowSystem.ViewportKey;
const BufferID = ptypes.BufferID;
const ptypes = @import("protocol").types;
const win32_gdi = @import("win32").graphics.gdi;
const log = std.log.scoped(.win32);
