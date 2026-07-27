const WindowSystem = @This();

io: Io,
gpa: std.mem.Allocator,
dispatch: *Dispatch,

window_next_id: WindowID,

native: NativeWindowSystem,

pub fn init_wayland(
    io: Io,
    gpa: std.mem.Allocator,
    dispatch: *Dispatch,
) !*WindowSystem {
    const ws: *WindowSystem = try .init_undefined_native(
        io,
        gpa,
        dispatch,
    );

    const wl: *Wayland = try .create(gpa, io);
    ws.native = .{ .wayland = wl };

    try wl.set_listeners(ws);

    return ws;
}

pub fn init_win32(
    io: Io,
    gpa: std.mem.Allocator,
    instance: Win32.HINSTANCE,
    cmd_show: c_int,
    dispatch: *Dispatch,
) !*WindowSystem {
    const ws: *WindowSystem = try .init_undefined_native(
        io,
        gpa,
        dispatch,
    );

    const win32 = try gpa.create(Win32);
    win32.* = try .init(gpa, instance, cmd_show);
    ws.native = .{ .win32 = win32 };

    return ws;
}

fn init_undefined_native(
    io: Io,
    gpa: std.mem.Allocator,
    dispatch: *Dispatch,
) !*WindowSystem {
    const ws = try gpa.create(WindowSystem);
    errdefer gpa.destroy(ws);
    ws.* = .{
        .io = io,
        .gpa = gpa,
        .dispatch = dispatch,

        .window_next_id = .first,

        .native = undefined,
    };

    return ws;
}

pub fn event_handle(ws: *WindowSystem, event: Dispatch.WindowSystemEvent) !void {
    switch (event) {
        .client_connected => |id| {
            switch (ws.native) {
                .wayland => |wl| try wl.client_connected(id),
                .win32 => @panic("TODO"),
            }
        },
        .client_disconnected => |id| {
            switch (ws.native) {
                .wayland => |wl| wl.client_disconnected(id),
                .win32 => @panic("TODO"),
            }
        },
        .buffer_create_gpu_with_fds => |args| {
            switch (ws.native) {
                .wayland => |wl| try wl.buffer_create_gpu_with_fds(ws.dispatch, args),
                .win32 => @panic("TODO"),
            }
        },
        .buffer_create_cpu_with_fd => |args| {
            switch (ws.native) {
                .wayland => |wl| try wl.buffer_create_cpu_with_fd(ws.dispatch, args),
                .win32 => @panic("TODO"),
            }
        },

        .buffer_present => |args| {
            switch (ws.native) {
                .wayland => |wl| try wl.buffer_present(args),
                .win32 => @panic("TODO"),
            }
        },
        .buffer_present_with_sync => |args| {
            switch (ws.native) {
                .wayland => |wl| try wl.buffer_present_with_sync(args),
                .win32 => @panic("TODO"),
            }
        },

        .buffer_destroy => |args| {
            switch (ws.native) {
                .wayland => |wl| try wl.buffer_destroy(ws.dispatch, args),
                .win32 => @panic("TODO"),
            }
        },
        .viewport_resize => |args| {
            switch (ws.native) {
                .wayland => |wl| try wl.viewport_resize(args),
                .win32 => @panic("TODO"),
            }
        },
        .window_create => |args| {
            switch (ws.native) {
                .wayland => |wl| try wl.window_create(ws, args),
                .win32 => @panic("TODO"),
            }
        },
        .window_resize_by_display_server => |args| {
            const resize = switch (ws.native) {
                .wayland => |wl| try wl.window_resize_by_display_server(args),
                .win32 => @panic("TODO"),
            };

            try ws.dispatch.server_put(.{ .viewport_resize = resize });
        },
        .wayland_dispatch => |dis| {
            switch (ws.native) {
                .wayland => |wl| {
                    _ = wl.display.dispatch();
                    try dis.result_queue.queue.putOne(wl.io, .{ .wayland_dispatch = true });
                },
                else => {},
            }
        },
    }
}

pub const ViewportKey = struct {
    client_id: ClientID,
    viewport_id: ViewportID,
};

pub const BufferKey = struct {
    client_id: ClientID,
    buffer_id: BufferID,
};

pub const WindowID = enum(u32) {
    pub const first: @This() = @enumFromInt(1);

    _,

    pub fn increment(this: *@This()) @This() {
        const int = @intFromEnum(this.*);
        this.* = @enumFromInt(int + 1);
        return @enumFromInt(int);
    }
};

pub const NativeWindowSystem = union(enum) {
    wayland: *Wayland,
    win32: *Win32,
};

const std = @import("std");
const Io = std.Io;
const ClientID = @import("server/Clients.zig").ClientID;
const ViewportID = @import("protocol/types.zig").ViewportID;
const Wayland = @import("wayland/Wayland.zig");
const Win32 = @import("win32/Win32.zig");
const os_tag = @import("builtin").os.tag;
const log = std.log.scoped(.WindowSystem);
const BufferID = @import("protocol/types.zig").BufferID;
const Dispatch = @import("Dispatch.zig");
