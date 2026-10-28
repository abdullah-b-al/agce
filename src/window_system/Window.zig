const Window = @This();

id: WindowID,

win32: if (os == .windows) Win32.Window else void,
linux: if (os == .linux) LinuxWindow else void,

pub fn create(
    ws: *WindowSystem,
    window_id: WindowID,
    requested_size: ptypes.Size,
) !*Window {
    const win = try ws.gpa.create(Window);
    errdefer ws.gpa.destroy(win);

    win.* = .{
        .id = window_id,

        .win32 = undefined,
        .linux = undefined,
    };

    switch (ws.native_tag()) {
        .wayland => |tag| {
            const wl = tag.window_system(ws);
            win.linux = .{ .wayland = try .init(wl, ws, win, requested_size) };
        },
        .win32 => |tag| {
            const win32 = tag.window_system(ws);
            win.win32 = try .init(win32, ws, win, requested_size);
        },
    }

    return win;
}

pub fn destroy(win: *Window, gpa: std.mem.Allocator) void {
    switch (win.native_tag()) {
        .wayland => |tag| {
            const nwin = tag.window(win);
            nwin.deinit();
        },
        .win32 => |tag| {
            const nwin = tag.window(win);
            nwin.deinit();
        },
    }

    gpa.destroy(win);
}

pub fn handle(win: *Window) *WindowSystem.WindowHandle {
    return switch (win.native_tag()) {
        .wayland => |tag| @ptrCast(tag.window(win).surface),
        .win32 => |tag| @ptrCast(tag.window(win).handle),
    };
}

pub fn size(win: *Window) ptypes.Size {
    return switch (win.native_tag()) {
        .wayland => |tag| tag.window(win).buffer.size,
        .win32 => |tag| {
            const nw = tag.window(win);
            var rect: win32_foundation.RECT = undefined;
            if (win32_win.GetClientRect(nw.handle, &rect) != 0) {
                return .{
                    .width = rect.right - rect.left,
                    .height = rect.bottom - rect.top,
                };
            } else {
                return .{ .width = 0, .height = 0 };
            }
        },
    };
}

pub fn native_tag(win: *Window) WindowSystem.NativeTag {
    return switch (os) {
        .linux => switch (win.linux) {
            .wayland => .wayland,
        },
        .windows => .win32,
        else => comptime unreachable,
    };
}

pub const LinuxWindow = union(enum) {
    wayland: Wayland.Window,
};

const std = @import("std");
const ClientID = @import("server/Clients.zig").ClientID;
const Viewport = @import("Viewport.zig");
const WindowSystem = @import("WindowSystem.zig");
const ViewportKey = WindowSystem.ViewportKey;
const WindowID = WindowSystem.WindowID;
const log = std.log.scoped(.Wayland);
const utils = @import("utils");
const c_linux = @import("c_linux");
const Wayland = @import("wayland/Wayland.zig");
const Win32 = @import("win32/Win32.zig");
const ptypes = @import("protocol").types;
const ClientResources = @import("ClientResources.zig");
const os = @import("builtin").os.tag;
const win32_win = @import("win32").ui.windows_and_messaging;
const win32_foundation = @import("win32").foundation;
