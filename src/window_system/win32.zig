pub fn init(gpa: std.mem.Allocator, instance: foundation.HINSTANCE, cmd_show: c_int) !State {
    const wc: win.WNDCLASSA = .{
        .style = .{},
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .lpszMenuName = null,
        .hIcon = null,
        .hCursor = null,
        .hbrBackground = null,
        .lpfnWndProc = window_proc,
        .hInstance = instance,
        .lpszClassName = "agce",
    };

    if (win.RegisterClassA(&wc) == 0) {
        const err = foundation.GetLastError();
        std.log.err("{}", .{err});
        return error.FailedToRegisterClass;
    }

    return .{
        .gpa = gpa,
        .instance = instance,
        .windows = .empty,
        .class = wc,
        .cmd_show = cmd_show,
    };
}

pub fn deinit(state: *State) void {
    state.deinit();
}

fn window_proc(
    hwnd: foundation.HWND,
    msg: u32,
    wparam: foundation.WPARAM,
    lparam: foundation.LPARAM,
) callconv(.winapi) foundation.LRESULT {
    const long: usize = @intCast(win.GetWindowLongPtrA(hwnd, .P_USERDATA));

    // Window has not been created yet. Pass through msg
    if (long == 0) {
        return win.DefWindowProcA(hwnd, msg, wparam, lparam);
    }

    const state: *State = @ptrFromInt(long);
    const window = blk: {
        for (state.windows.items) |*window| {
            if (window.handle == hwnd) break :blk window;
        }

        // Window has been removed. Pass through msg
        return win.DefWindowProcA(hwnd, msg, wparam, lparam);
    };

    if (msg == win.WM_CLOSE) {
        window.exit = true;
        return win.DefWindowProcA(hwnd, msg, wparam, lparam);
    } else if (msg == win.WM_KEYDOWN) {
        const truncate: @typeInfo(kbm.VIRTUAL_KEY).@"enum".tag_type = @truncate(wparam);
        const key: kbm.VIRTUAL_KEY = @enumFromInt(truncate);
        switch (key) {
            else => {},
        }
        return 0;
    } else if (msg == win.WM_SIZE) {
        const low: isize = lparam & 0xFFFF;
        const high: isize = (lparam >> 16) & 0xFFFF;
        const w: i16 = @truncate(low);
        const h: i16 = @truncate(high);

        window.resize(state.gpa, w, h) catch {};
    }

    return win.DefWindowProcA(hwnd, msg, wparam, lparam);
}

pub fn window_create(state: *State) !void {
    try state.windows.ensureUnusedCapacity(state.gpa, 1);
    const width = 400;
    const height = 400;
    const buffer_len = width * height * 4;
    const buffer = try state.gpa.alloc(u8, buffer_len);

    const hwnd = win.CreateWindowExA(
        .{},

        state.class.lpszClassName,
        "agce",

        win.WS_OVERLAPPEDWINDOW,

        win.CW_USEDEFAULT,
        win.CW_USEDEFAULT,
        win.CW_USEDEFAULT,
        win.CW_USEDEFAULT,

        null,
        null,
        state.instance,
        null,
    ) orelse {
        const err = foundation.GetLastError();
        std.log.err("{}", .{err});
        return error.FailedToCreateWindow;
    };

    var bitmap_info: win32.graphics.gdi.BITMAPINFO = undefined;

    bitmap_info.bmiHeader.biSize = @sizeOf(win32.graphics.gdi.BITMAPINFOHEADER);
    bitmap_info.bmiHeader.biWidth = width;
    bitmap_info.bmiHeader.biHeight = -height;
    bitmap_info.bmiHeader.biPlanes = 1;
    bitmap_info.bmiHeader.biBitCount = 32;
    bitmap_info.bmiHeader.biCompression = win32.graphics.gdi.BI_RGB;

    const window: Window = .{
        .handle = hwnd,
        .buffer = buffer,
        .width = @intCast(width),
        .height = @intCast(height),
        .exit = false,
        .bitmap_info = bitmap_info,
        .shown = false,
    };

    const long: usize = @intFromPtr(state);
    const ilong: isize = @intCast(long);
    std.debug.assert(long == ilong);
    // TODO: Check success
    _ = win.SetWindowLongPtrA(hwnd, .P_USERDATA, ilong);
    state.windows.appendAssumeCapacity(window);
}

pub fn window_show(window: *Window, cmd_show: c_int) void {
    std.debug.assert(!window.shown);
    _ = win.ShowWindow(window.handle, @bitCast(cmd_show));
    window.shown = true;
}

pub fn render(window: *Window) void {
    const hdc = win32.graphics.gdi.GetDC(window.handle);
    // zig fmt: off
        _ = win32.graphics.gdi.StretchDIBits(
            hdc,
            0, 0, window.width, window.height,
            0, 0, window.width, window.height,

            window.buffer.ptr,
            &window.bitmap_info,
            win32.graphics.gdi.DIB_RGB_COLORS,
            win32.graphics.gdi.SRCCOPY,
        );
    // zig fmt: on

    _ = win32.graphics.gdi.ReleaseDC(window.handle, hdc);
}

pub const State = struct {
    gpa: std.mem.Allocator,

    instance: foundation.HINSTANCE,
    windows: std.ArrayList(Window),
    cmd_show: c_int,
    class: win.WNDCLASSA,

    pub fn deinit(state: *State) void {
        for (state.windows.items) |*window| {
            window.deinit(state.gpa);
        }
        state.windows.deinit(state.gpa);
    }
};

pub const Window = struct {
    handle: foundation.HWND,
    buffer: []u8,
    bitmap_info: win32.graphics.gdi.BITMAPINFO,
    width: i32,
    height: i32,
    exit: bool,
    shown: bool,

    pub fn deinit(window: *Window, gpa: std.mem.Allocator) void {
        gpa.free(window.buffer);
    }

    pub fn resize(window: *Window, gpa: std.mem.Allocator, width: i32, height: i32) !void {
        const old_size = window.width * window.height * 4;
        const new_size: usize = @intCast(width * height * 4);
        if (new_size > old_size) {
            const new_buffer = try gpa.alloc(u8, new_size);
            gpa.free(window.buffer);
            window.buffer = new_buffer;
        }

        window.width = width;
        window.height = height;
        window.bitmap_info.bmiHeader.biWidth = width;
        window.bitmap_info.bmiHeader.biHeight = -height;
    }
};

const std = @import("std");
const Io = std.Io;
const win32 = @import("win32");
const win = win32.ui.windows_and_messaging;
const foundation = @import("win32").foundation;
const kbm = win32.ui.input.keyboard_and_mouse;
