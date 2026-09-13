const Window = @This();

id: WindowID,

viewport_key: ViewportKey,
input_focus_keyboard: ViewportKey,
input_focus_mouse: ViewportKey,

win32: if (os == .windows) void else void,
linux: if (os == .linux) Linux else void,

pub fn create(
    ws: *WindowSystem,
    window_id: WindowID,
    viewport_key: ViewportKey,
    requested_size: ptypes.Size,
) !*Window {
    const win = try ws.gpa.create(Window);
    errdefer ws.gpa.destroy(win);

    win.* = .{
        .id = window_id,
        .viewport_key = viewport_key,
        .input_focus_keyboard = viewport_key,
        .input_focus_mouse = viewport_key,

        .win32 = undefined,
        .linux = undefined,
    };

    switch (ws.native_tag()) {
        .wayland => |tag| {
            const wl = tag.window_system(ws);
            win.linux = .{ .wayland = try .init(wl, ws, win, requested_size) };
        },
        .win32 => |tag| {
            tag.guard();
            @panic("TODO");
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
            tag.guard();
            @panic("TODO");
        },
    }

    gpa.destroy(win);
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

pub const Linux = union(enum) {
    wayland: Wayland.Window,
};

const std = @import("std");
const ClientID = @import("../server/Clients.zig").ClientID;
const Viewport = @import("Viewport.zig");
const WindowSystem = @import("../WindowSystem.zig");
const ViewportKey = WindowSystem.ViewportKey;
const WindowID = WindowSystem.WindowID;
const log = std.log.scoped(.Wayland);
const utils = @import("utils");
const c_linux = @import("c_linux");
const Wayland = @import("../wayland/Wayland.zig");
const ptypes = @import("protocol").types;
const ClientResources = @import("ClientResources.zig");
const os = @import("builtin").os.tag;
