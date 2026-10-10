const Win32 = @This();

gpa: std.mem.Allocator,

instance: win32_foundation.HINSTANCE,
class_window: win32_win.WNDCLASSA,
class_viewport: win32_win.WNDCLASSA,

d11_device: *d11.ID3D11Device,
d11_device_context: *d11.ID3D11DeviceContext,
dxgi_device: *dxgi.IDXGIDevice,
dxgi_adapter: *dxgi.IDXGIAdapter,
dxgi_factory: *dxgi.IDXGIFactory2,

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

    var d11_device: *d11.ID3D11Device = undefined;
    var d11_device_context: *d11.ID3D11DeviceContext = undefined;
    var feature_level: d3d.D3D_FEATURE_LEVEL = undefined;

    const create_device_result = d11.D3D11CreateDevice(
        null,
        .HARDWARE,
        null,
        .{ .DEBUG = 0 },
        null,
        0,
        d11.D3D11_SDK_VERSION,
        &d11_device,
        &feature_level,
        &d11_device_context,
    );

    if (create_device_result != win32_foundation.S_OK) {
        log.err("FailedToCreateD3D11Device: 0x{x}", .{create_device_result});
        return error.FailedToCreateD3D11Device;
    }

    var dxgi_device: *dxgi.IDXGIDevice = undefined;
    if (d11_device.IUnknown.QueryInterface(dxgi.IID_IDXGIDevice, @ptrCast(&dxgi_device)) !=
        win32_foundation.S_OK)
    {
        return error.FailedToCreateDXGIDevice;
    }

    var dxgi_adapter: *dxgi.IDXGIAdapter = undefined;
    if (dxgi_device.GetAdapter(&dxgi_adapter) !=
        win32_foundation.S_OK)
    {
        return error.FailedToCreateDXGIAdapter;
    }

    var dxgi_factory: *dxgi.IDXGIFactory2 = undefined;
    if (dxgi_adapter.IDXGIObject.GetParent(dxgi.IID_IDXGIFactory2, @ptrCast(&dxgi_factory)) !=
        win32_foundation.S_OK)
    {
        return error.FailedToCreateDXGIFactory2;
    }

    ptr.* = .{
        .gpa = ws.gpa,
        .instance = instance,
        .class_window = class_window,
        .class_viewport = class_viewport,
        .d11_device = d11_device,
        .d11_device_context = d11_device_context,
        .dxgi_device = dxgi_device,
        .dxgi_adapter = dxgi_adapter,
        .dxgi_factory = dxgi_factory,
    };

    return ptr;
}

pub fn destroy(win32: *Win32) void {
    _ = win32.dxgi_factory.IUnknown.Release();
    _ = win32.dxgi_adapter.IUnknown.Release();
    _ = win32.dxgi_device.IUnknown.Release();
    _ = win32.d11_device_context.IUnknown.Release();
    _ = win32.d11_device.IUnknown.Release();
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

            const pkey = to_protocol_key(key) orelse return 0;
            const flags: KeyDownLParam = .from_lparam(msg, lparam);

            const modifiers = get_modifires();
            ws.deferred_events.appendAssumeCapacity(.{
                .keyboard_key = .{
                    .key = pkey,
                    .state = if (flags.previous_state == 1) .repeat else .pressed,
                    .modifiers = modifiers,
                    .char = null,
                },
            });
            return 0;
        },

        win32_win.WM_KEYUP => {
            const truncate: @typeInfo(kbm.VIRTUAL_KEY).@"enum".tag_type = @truncate(wparam);
            const key: kbm.VIRTUAL_KEY = @enumFromInt(truncate);
            const pkey = to_protocol_key(key) orelse return 0;
            ws.deferred_events.appendAssumeCapacity(.{
                .keyboard_key = .{
                    .key = pkey,
                    .state = .released,
                    .modifiers = get_modifires(),
                    .char = null,
                },
            });
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

            const mouse_event: WindowSystem.Event = blk: switch (tag) {
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

            switch (tag) {
                win32_win.WM_LBUTTONDOWN, win32_win.WM_RBUTTONDOWN => {
                    ws.deferred_events.appendAssumeCapacity(
                        .{ .keyboard_enter = .{ .window_id = win.id } },
                    );
                },
                else => {},
            }

            ws.deferred_events.appendAssumeCapacity(mouse_event);

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

pub fn from_protocol_cursor_shape(shape: ptypes.CursorShape) ?[*:0]align(1) const u16 {
    return switch (shape) {
        .none => null,
        .default => win32_win.IDC_ARROW,
        .context_menu => win32_win.IDC_ARROW,
        .help => win32_win.IDC_HELP,
        .pointer => win32_win.IDC_HAND,
        .progress => win32_win.IDC_APPSTARTING,
        .wait => win32_win.IDC_WAIT,

        .cell => win32_win.IDC_CROSS,
        .crosshair => win32_win.IDC_CROSS,
        .text => win32_win.IDC_IBEAM,
        .vertical_text => win32_win.IDC_IBEAM,

        .alias => win32_win.IDC_ARROW,
        .copy => win32_win.IDC_ARROW,
        .move => win32_win.IDC_SIZEALL,
        .no_drop => win32_win.IDC_NO,
        .not_allowed => win32_win.IDC_NO,

        .grab => win32_win.IDC_HAND,
        .grabbing => win32_win.IDC_HAND,

        .e_resize => win32_win.IDC_SIZEWE,
        .w_resize => win32_win.IDC_SIZEWE,
        .ew_resize => win32_win.IDC_SIZEWE,

        .n_resize => win32_win.IDC_SIZENS,
        .s_resize => win32_win.IDC_SIZENS,
        .ns_resize => win32_win.IDC_SIZENS,

        .ne_resize => win32_win.IDC_SIZENESW,
        .sw_resize => win32_win.IDC_SIZENESW,

        .nw_resize => win32_win.IDC_SIZENWSE,
        .se_resize => win32_win.IDC_SIZENWSE,

        .nesw_resize => win32_win.IDC_SIZENESW,
        .nwse_resize => win32_win.IDC_SIZENWSE,

        .col_resize => win32_win.IDC_SIZEWE,
        .row_resize => win32_win.IDC_SIZENS,

        .all_scroll => win32_win.IDC_SIZEALL,

        .zoom_in => null,
        .zoom_out => null,
    };
}

pub const Buffer = union(enum) {
    cpu: Cpu,
    d11: D11,

    pub fn format(b: Buffer) ptypes.BufferFormat {
        return switch (b) {
            inline else => |v| v.format,
        };
    }

    pub fn deinit(buffer: *Buffer) void {
        switch (buffer.*) {
            .cpu => |cpu| {
                _ = win32_memory.UnmapViewOfFile(cpu.pixels);
                _ = win32_foundation.CloseHandle(@ptrFromInt(@intFromEnum(cpu.handle)));
            },
            .d11 => |d| {
                _ = d.texture.IUnknown.Release();
            },
        }
    }

    pub const Cpu = struct {
        handle: ptypes.CpuBufferHandle,
        pixels: *anyopaque,
        size: ptypes.Size,
        format: ptypes.BufferFormat,
    };

    pub const D11 = struct {
        texture: *d11.ID3D11Texture2D,
        format: ptypes.BufferFormat,
    };
};

pub fn to_protocol_key(key: kbm.VIRTUAL_KEY) ?pinput.Key {
    return switch (key) {
        .SPACE => .space,
        .OEM_7 => .apostrophe,
        .OEM_COMMA => .comma,
        .OEM_MINUS => .minus,
        .OEM_PERIOD => .period,
        .OEM_2 => .slash,

        .@"0" => .zero,
        .@"1" => .one,
        .@"2" => .two,
        .@"3" => .three,
        .@"4" => .four,
        .@"5" => .five,
        .@"6" => .six,
        .@"7" => .seven,
        .@"8" => .eight,
        .@"9" => .nine,

        .OEM_1 => .semicolon,
        .OEM_PLUS => .equal,

        .A => .a,
        .B => .b,
        .C => .c,
        .D => .d,
        .E => .e,
        .F => .f,
        .G => .g,
        .H => .h,
        .I => .i,
        .J => .j,
        .K => .k,
        .L => .l,
        .M => .m,
        .N => .n,
        .O => .o,
        .P => .p,
        .Q => .q,
        .R => .r,
        .S => .s,
        .T => .t,
        .U => .u,
        .V => .v,
        .W => .w,
        .X => .x,
        .Y => .y,
        .Z => .z,

        .OEM_4 => .left_bracket,
        .OEM_5 => .backslash,
        .OEM_6 => .right_bracket,
        .OEM_3 => .grave_accent,

        .ESCAPE => .escape,
        .RETURN => .enter,
        .TAB => .tab,
        .BACK => .backspace,

        .INSERT => .insert,
        .DELETE => .delete,

        .RIGHT => .right,
        .LEFT => .left,
        .DOWN => .down,
        .UP => .up,

        .PRIOR => .page_up,
        .NEXT => .page_down,
        .HOME => .home,
        .END => .end,

        .CAPITAL => .caps_lock,
        .SCROLL => .scroll_lock,
        .NUMLOCK => .num_lock,
        .PAUSE => .pause,

        .F1 => .f1,
        .F2 => .f2,
        .F3 => .f3,
        .F4 => .f4,
        .F5 => .f5,
        .F6 => .f6,
        .F7 => .f7,
        .F8 => .f8,
        .F9 => .f9,
        .F10 => .f10,
        .F11 => .f11,
        .F12 => .f12,
        .F13 => .f13,
        .F14 => .f14,
        .F15 => .f15,
        .F16 => .f16,
        .F17 => .f17,
        .F18 => .f18,
        .F19 => .f19,
        .F20 => .f20,
        .F21 => .f21,
        .F22 => .f22,
        .F23 => .f23,
        .F24 => .f24,

        .NUMPAD0 => .kp_0,
        .NUMPAD1 => .kp_1,
        .NUMPAD2 => .kp_2,
        .NUMPAD3 => .kp_3,
        .NUMPAD4 => .kp_4,
        .NUMPAD5 => .kp_5,
        .NUMPAD6 => .kp_6,
        .NUMPAD7 => .kp_7,
        .NUMPAD8 => .kp_8,
        .NUMPAD9 => .kp_9,

        .DECIMAL => .kp_decimal,
        .DIVIDE => .kp_divide,
        .MULTIPLY => .kp_multiply,
        .SUBTRACT => .kp_minus,
        .ADD => .kp_plus,
        .SEPARATOR => .kp_enter,

        .LSHIFT => .left_shift,
        .RSHIFT => .right_shift,
        .LCONTROL => .left_control,
        .RCONTROL => .right_control,
        .LMENU => .left_alt,
        .RMENU => .right_alt,

        .LWIN => .left_gui,
        .RWIN => .right_gui,

        .APPS => .menu,

        else => null,
    };
}

// https://learn.microsoft.com/en-us/windows/win32/inputdev/wm-keydown#parameters
const KeyDownLParam = packed struct(i32) {
    repeat_count: u16, // 0-15
    scan_code: u8, // 16-23
    extended: u1, // 24
    _reserved: u4, // 25-28
    context_code: u1, // 29
    previous_state: u1, // 30
    transition_state: u1, // 31

    pub fn from_lparam(msg: u32, lparam: win32_foundation.LPARAM) KeyDownLParam {
        std.debug.assert(msg == win32_win.WM_KEYDOWN);

        const bits: i32 = @truncate(lparam);
        return @bitCast(bits);
    }
};

fn get_modifires() pinput.Modifiers {
    const KeyState = packed struct(i16) {
        _: u15,
        down: u1,

        pub fn get(key: kbm.VIRTUAL_KEY) @This() {
            return @bitCast(kbm.GetKeyState(@intFromEnum(key)));
        }
    };

    // zig fmt: off
    return .{
        .alt = 
            KeyState.get(.LMENU).down == 1 or
            KeyState.get(.RMENU).down == 1 or
            KeyState.get(.MENU).down == 1,
        .shift =
            KeyState.get(.LSHIFT).down == 1 or
            KeyState.get(.RSHIFT).down == 1 or
            KeyState.get(.SHIFT).down == 1,
        .control = 
            KeyState.get(.LCONTROL).down == 1 or
            KeyState.get(.RCONTROL).down == 1 or
            KeyState.get(.CONTROL).down == 1,
    };
    // zig fmt: on
}

pub fn buffer_format_to_dxgi_format(format: ptypes.BufferFormat) dxgi.common.DXGI_FORMAT {
    return switch (format) {
        .argb8888 => .R8G8B8A8_UNORM,
    };
}

pub fn log_d3d11_errors(win32: *Win32) !void {
    {
        var info_queue: *d11.ID3D11InfoQueue = undefined;

        const hr = win32.d11_device.IUnknown.QueryInterface(
            d11.IID_ID3D11InfoQueue,
            @ptrCast(&info_queue),
        );
        std.debug.assert(hr == win32_foundation.S_OK);
        const count = info_queue.GetNumStoredMessages();
        for (0..count) |i| {
            var size: usize = 0;
            _ = info_queue.GetMessage(i, null, &size);

            const buf = try win32.gpa.alloc(u8, size);
            defer win32.gpa.free(buf);

            const msg: *d11.D3D11_MESSAGE = @ptrCast(@alignCast(buf.ptr));

            _ = info_queue.GetMessage(i, msg, &size);

            const ptr: [*]const u8 = @ptrCast(msg.pDescription.?);
            log.err("{s}", .{ptr[0..msg.DescriptionByteLength]});
        }
    }

    {
        var info_queue: *dxgi.IDXGIInfoQueue = undefined;
        const hr = dxgi.DXGIGetDebugInterface1(0, dxgi.IID_IDXGIInfoQueue, @ptrCast(&info_queue));

        std.debug.assert(hr == win32_foundation.S_OK);
        const count = info_queue.GetNumStoredMessages(dxgi.DXGI_DEBUG_ALL);
        for (0..count) |i| {
            var size: usize = 0;

            _ = info_queue.GetMessage(dxgi.DXGI_DEBUG_ALL, i, null, &size);

            const buf = try win32.gpa.alloc(u8, size);
            defer win32.gpa.free(buf);

            const msg: *dxgi.DXGI_INFO_QUEUE_MESSAGE = @ptrCast(@alignCast(buf.ptr));

            _ = info_queue.GetMessage(dxgi.DXGI_DEBUG_ALL, i, msg, &size);

            const ptr: [*]const u8 = @ptrCast(msg.pDescription.?);
            log.err("{s}", .{ptr[0..msg.DescriptionByteLength]});
        }
    }
}

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
const ptypes = @import("protocol").types;
const pinput = @import("protocol").input;
const BufferID = ptypes.BufferID;
const win32_gdi = @import("win32").graphics.gdi;
const log = std.log.scoped(.win32);
const d11 = @import("win32").graphics.direct3d11;
const d3d = @import("win32").graphics.direct3d;
const dxgi = @import("win32").graphics.dxgi;
const g = @import("win32").graphics;
