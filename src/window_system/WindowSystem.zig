const WindowSystem = @This();

io: Io,
gpa: std.mem.Allocator,
dispatch: *Dispatch,

window_next_id: WindowBase.WindowID,

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

    const wl: *Wayland = try .init(gpa, io);
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
        inline .buffer_create_gpu_with_fd,
        .buffer_create_cpu_with_fd,
        => |e, tag| {
            const key: BufferKey = .{
                .client_id = e.client_id,
                .buffer_id = e.buffer_id,
            };
            switch (ws.native) {
                .wayland => |wl| {
                    switch (tag) {
                        .buffer_create_cpu_with_fd => {
                            try wl.buffers.buffer_create_and_register_cpu(
                                ws.dispatch,
                                wl.gpa,
                                wl.shm,
                                key,
                                e.fd,
                                @intCast(e.width),
                                @intCast(e.height),
                                e.format,
                            );
                        },
                        .buffer_create_gpu_with_fd => {
                            try wl.buffers.buffer_create_and_register_gpu_async(
                                ws.dispatch,
                                wl,
                                key,
                                e.fd,
                                @intCast(e.width),
                                @intCast(e.height),
                                e.format,
                                e.gbm_bo_modifier,
                            );
                        },
                        else => comptime unreachable,
                    }
                },
                .win32 => @panic("TODO"),
            }
        },

        .buffer_present => |e| {
            const buffer_key: BufferKey = .{ .client_id = e.client_id, .buffer_id = e.buffer_id };
            const viewport_key: ViewportKey = .{ .client_id = e.client_id, .viewport_id = e.viewport_id };

            switch (ws.native) {
                .wayland => |wl| {
                    const result = wl.subsurface_and_window_from_viewport_key(viewport_key) orelse {
                        log.err("Viewport does not exist {}", .{viewport_key});
                        return;
                    };
                    const buffer = wl.buffers.buffer_get(buffer_key) orelse {
                        log.err("Buffer does not exist {}", .{buffer_key});
                        return;
                    };

                    try wl.buffers.viewport_mark_commit(ws, buffer_key, viewport_key.viewport_id);
                    result.subsurface.surface.damage(0, 0, buffer.width(), buffer.height());
                    result.subsurface.surface.attach(buffer.wl_buffer(), 0, 0);
                    result.subsurface.surface.commit();
                    log.debug("buffer_present: commited subsurface for {} {}", .{ buffer_key, viewport_key });

                    wl.window_commit(result.window);
                    _ = wl.display.flush();
                },
                .win32 => @panic("TODO"),
            }
        },
        .window_create => |e| {
            switch (ws.native) {
                .wayland => |wl| {
                    const id = ws.window_next_id;
                    ws.window_next_id = @enumFromInt(@intFromEnum(id) + 1);

                    const key: ViewportKey = .{ .client_id = e.client_id, .viewport_id = e.viewport_id };
                    const window = try wl.window_create(ws, id, key, @intCast(e.width), @intCast(e.height));
                    wl.window_ensure_configured(window);
                },
                .win32 => @panic("TODO"),
            }
        },
        .window_resize_by_display_server => |args| {
            switch (ws.native) {
                .wayland => |wl| {
                    const win = wl.windows.get(args.id) orelse {
                        return;
                    };

                    try win.buffer_resize(wl, args.width, args.height);
                    Wayland.fill_black(
                        win.buffer_pixels,
                        win.buffer.width,
                        win.buffer.height,
                        win.buffer.format.bytes_per_pixel(),
                    );
                    wl.window_commit(win);
                    _ = wl.display.flush();

                    try ws.dispatch.server_put(
                        .{
                            .viewport_resize = .{
                                .client_id = win.subsurface.viewport_key.client_id,
                                .resize = .{
                                    .viewport_id = win.subsurface.viewport_key.viewport_id,
                                    .width = @intCast(args.width),
                                    .height = @intCast(args.height),
                                },
                            },
                        },
                    );
                },
                .win32 => @panic("TODO"),
            }
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

pub const NativeWindowSystem = union(enum) {
    wayland: *Wayland,
    win32: *Win32,
};

const std = @import("std");
const Io = std.Io;
const Viewport = @import("Viewport.zig");
const ClientID = @import("../server/Clients.zig").ClientID;
const ViewportID = @import("../protocol/types.zig").ViewportID;
const Wayland = @import("Wayland.zig");
const Win32 = @import("Win32.zig");
const WindowBase = @import("WindowBase.zig");
const os_tag = @import("builtin").os.tag;
const log = std.log.scoped(.WindowSystem);
const BufferID = @import("../protocol/types.zig").BufferID;
const Buffers = @import("wayland/Buffers.zig");
const Dispatch = @import("../Dispatch.zig");
