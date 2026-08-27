const WindowSystem = @This();

io: Io,
gpa: std.mem.Allocator,
dispatch: *Dispatch,

window_next_id: WindowID,

native: NativeWindowSystem,

pub fn create_wayland(
    io: Io,
    gpa: std.mem.Allocator,
    dispatch: *Dispatch,
) !*WindowSystem {
    const ws: *WindowSystem = try .create_undefined_native(
        io,
        gpa,
        dispatch,
    );

    const wl: *Wayland = try .create(dispatch);
    ws.native = .{ .wayland = wl };

    try wl.set_listeners(ws);

    return ws;
}

pub fn create_win32(
    io: Io,
    gpa: std.mem.Allocator,
    instance: Win32.HINSTANCE,
    cmd_show: c_int,
    dispatch: *Dispatch,
) !*WindowSystem {
    const ws: *WindowSystem = try .create_undefined_native(
        io,
        gpa,
        dispatch,
    );

    const win32 = try gpa.create(Win32);
    win32.* = try .init(gpa, instance, cmd_show);
    ws.native = .{ .win32 = win32 };

    return ws;
}

fn create_undefined_native(
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

pub fn destroy(ws: *WindowSystem) void {
    std.debug.assert(ws.native == .wayland);
    switch (ws.native) {
        .wayland => |wl| wl.destroy(),
        .win32 => @panic("TODO"),
    }

    ws.gpa.destroy(ws);
}

pub fn event_handle(ws: *WindowSystem, event: Dispatch.WindowSystemEvent) !void {
    switch (event) {
        .exit => return error.Exit,
        .client_registered => {
            var e = event.client_registered;
            defer if (e.info) |*info| {
                info.deinit();
            };

            switch (ws.native) {
                .wayland => |wl| try wl.client_registered(e.client_id, e.info),
                .win32 => @panic("TODO"),
            }
        },
        .client_disconnected => |id| {
            switch (ws.native) {
                .wayland => |wl| try wl.client_disconnected(id),
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
                .wayland => |wl| try wl.buffer_create_cpu_with_fd(args),
                .win32 => @panic("TODO"),
            }
        },

        .buffer_present => |args| {
            switch (ws.native) {
                .wayland => |wl| try wl.buffer_present(.{ .no_sync = args }),
                .win32 => @panic("TODO"),
            }
        },
        .buffer_present_with_sync => |args| {
            switch (ws.native) {
                .wayland => |wl| try wl.buffer_present(.{ .sync = args }),
                .win32 => @panic("TODO"),
            }
        },

        .buffer_destroy => |args| {
            switch (ws.native) {
                .wayland => |wl| try wl.buffer_destroy(args),
                .win32 => @panic("TODO"),
            }
        },
        .viewport_create => |args| {
            const result = switch (ws.native) {
                .wayland => |wl| try wl.viewport_create(ws, args),
                .win32 => @panic("TODO"),
            };

            switch (result) {
                .create_with_window => |key| {
                    try ws.dispatch.server_put(@src(), .{
                        .viewport_created = .{
                            .client_id = key.client_id,
                            .payload = .{
                                .viewport_id = key.viewport_id,
                                .status = .success,
                            },
                        },
                    });
                },
                .create_with_sub_viewport => |v| {
                    try ws.dispatch.server_put(@src(), .{
                        .viewport_created = .{
                            .client_id = v.embeded.client_id,
                            .payload = .{
                                .viewport_id = v.embeded.viewport_id,
                                .status = .success,
                            },
                        },
                    });

                    try ws.dispatch.server_put(@src(), .{
                        .sub_viewport_embeded = .{
                            .client_id = v.embeder.key.client_id,
                            .payload = .{
                                .sub_viewport_id = v.embeder.key.sub_viewport_id,
                                .status = .success,
                                .render_size = v.embeder.render_size,
                            },
                        },
                    });
                },
            }
        },
        .sub_viewport_embed => |args| {
            switch (ws.native) {
                .wayland => |wl| try wl.sub_viewport_embed(args),
                .win32 => @panic("TODO"),
            }
        },
        .sub_viewport_rect_set => |args| {
            switch (ws.native) {
                .wayland => |wl| try wl.sub_viewport_rect_set(args),
                .win32 => @panic("TODO"),
            }
        },
        .windows_destroy => {
            switch (ws.native) {
                .wayland => |wl| try wl.windows_destroy(),
                .win32 => @panic("TODO"),
            }
        },
        .window_resize_by_display_server => |args| {
            switch (ws.native) {
                .wayland => |wl| try wl.window_resize_by_display_server(args),
                .win32 => @panic("TODO"),
            }
        },
        .cursor_shape_set => |args| {
            switch (ws.native) {
                .wayland => |wl| try wl.cursor_shape_set(args),
                .win32 => @panic("TODO"),
            }
        },
        .keyboard_key => |args| {
            switch (ws.native) {
                .wayland => |wl| try wl.keyboard_key(args),
                .win32 => @panic("TODO"),
            }
        },
        .keyboard_enter => |args| {
            switch (ws.native) {
                .wayland => |wl| try wl.keyboard_enter(args),
                .win32 => @panic("TODO"),
            }
        },
        .keyboard_leave => |args| {
            switch (ws.native) {
                .wayland => |wl| try wl.keyboard_leave(args),
                .win32 => @panic("TODO"),
            }
        },
        .mouse_enter => |args| {
            switch (ws.native) {
                .wayland => |wl| try wl.mouse_enter(args),
                .win32 => @panic("TODO"),
            }
        },
        .mouse_leave => |args| {
            switch (ws.native) {
                .wayland => |wl| try wl.mouse_leave(args),
                .win32 => @panic("TODO"),
            }
        },
        .mouse_motion => |args| {
            switch (ws.native) {
                .wayland => |wl| try wl.mouse_motion(args),
                .win32 => @panic("TODO"),
            }
        },
        .mouse_button => |args| {
            switch (ws.native) {
                .wayland => |wl| try wl.mouse_button(args),
                .win32 => @panic("TODO"),
            }
        },
        .mouse_scroll => |args| {
            switch (ws.native) {
                .wayland => |wl| try wl.mouse_scroll(args),
                .win32 => @panic("TODO"),
            }
        },
        .wayland_dispatch => |dis| {
            switch (ws.native) {
                .wayland => |wl| {
                    wl.display_dispatch();
                    dis.signal.set(wl.io);
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

pub const SubViewportKey = struct {
    client_id: ClientID,
    sub_viewport_id: ptypes.SubViewportID,
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

    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("WindowID({})", .{@intFromEnum(self)});
    }
};

pub const ViewportCreateResult = union(enum) {
    create_with_window: ViewportKey,
    create_with_sub_viewport: struct {
        embeder: struct {
            key: SubViewportKey,
            render_size: ptypes.Size,
        },
        embeded: ViewportKey,
    },
};

pub const NativeWindowSystem = union(enum) {
    wayland: *Wayland,
    win32: *Win32,
};

const std = @import("std");
const Io = std.Io;
const ClientID = ptypes.ClientID;
const ptypes = @import("protocol").types;
const ViewportID = ptypes.ViewportID;
const Wayland = @import("wayland/Wayland.zig");
const Win32 = @import("win32/Win32.zig");
const os_tag = @import("builtin").os.tag;
const log = std.log.scoped(.WindowSystem);
const BufferID = ptypes.BufferID;
const Dispatch = @import("Dispatch.zig");
