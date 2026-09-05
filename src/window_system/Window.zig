const Window = @This();

id: WindowID,

viewport_key: ViewportKey,
input_focus_keyboard: ViewportKey,
input_focus_mouse: ViewportKey,

native: Native,

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

        .native = undefined,
    };

    win.native = switch (WindowSystem.Native) {
        WindowSystem.Linux => switch (ws.native) {
            .wayland => |wl| .{
                .wayland = try .init(wl, ws, win, requested_size),
            },
        },
        else => unreachable,
    };

    return win;
}

pub fn destroy(win: *Window, gpa: std.mem.Allocator) void {
    switch (WindowSystem.Native) {
        WindowSystem.Linux => switch (win.native) {
            .wayland => |*wl_win| wl_win.deinit(),
        },
        else => unreachable,
    }

    gpa.destroy(win);
}

pub const Linux = union(enum) {
    wayland: Wayland.Window,
};

pub const Native = switch (WindowSystem.Native) {
    WindowSystem.Linux => Linux,
    WindowSystem.W32 => void,
    else => unreachable,
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
