const WindowSystem = @This();

io: Io,
gpa: std.mem.Allocator,

event_queue: *events.WindowSystemQueue,
server_event_queue: *events.ServerQueue,

window_next_id: WindowBase.WindowID,

native: NativeWindowSystem,

pub fn init_wayland(
    io: Io,
    gpa: std.mem.Allocator,
    ws_event_queue: *events.WindowSystemQueue,
    server_event_queue: *events.ServerQueue,
) !*WindowSystem {
    const ws: *WindowSystem = try .init_undefined_native(
        io,
        gpa,
        ws_event_queue,
        server_event_queue,
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
    ws_event_queue: *events.WindowSystemQueue,
    server_event_queue: *events.ServerQueue,
) !*WindowSystem {
    const ws: *WindowSystem = try .init_undefined_native(
        io,
        gpa,
        ws_event_queue,
        server_event_queue,
    );

    const win32 = try gpa.create(Win32);
    win32.* = try .init(gpa, instance, cmd_show);
    ws.native = .{ .win32 = win32 };

    return ws;
}

fn init_undefined_native(
    io: Io,
    gpa: std.mem.Allocator,
    ws_event_queue: *events.WindowSystemQueue,
    server_event_queue: *events.ServerQueue,
) !*WindowSystem {
    const ws = try gpa.create(WindowSystem);
    errdefer gpa.destroy(ws);
    ws.* = .{
        .io = io,
        .gpa = gpa,
        .event_queue = ws_event_queue,
        .server_event_queue = server_event_queue,

        .window_next_id = .first,

        .native = undefined,
    };

    return ws;
}

pub fn event_handle(ws: *WindowSystem, event: events.WindowSystem) !void {
    switch (event) {
        inline .viewport_create_with_fds_gpu,
        .viewport_create_with_fds_cpu,
        => |e, tag| {
            const key: ViewportKey = .{
                .client_id = e.client_id,
                .viewport_id = e.viewport_id,
            };

            switch (ws.native) {
                .wayland => |wl| {
                    if (wl.buffers.viewport_exists(key)) {
                        switch (tag) {
                            .viewport_create_with_fds_cpu => {
                                const cpu = @field(event, @tagName(tag));
                                const vp: Viewport = .init_cpu(
                                    key,
                                    e.fds.front,
                                    e.fds.back,
                                    @intCast(cpu.width),
                                    @intCast(cpu.height),
                                    cpu.format,
                                );
                                try wl.buffers.double_buffer_update_cpu(wl, vp);
                            },
                            .viewport_create_with_fds_gpu => {
                                const gpu = @field(event, @tagName(tag));
                                const vp: Viewport = .init_gpu(
                                    key,
                                    e.fds.front,
                                    e.fds.back,
                                    @intCast(gpu.width),
                                    @intCast(gpu.height),
                                    gpu.format,
                                    gpu.gbm_bo_modifier,
                                );
                                try wl.buffers.double_buffer_update_gpu(wl, vp);
                            },
                            else => comptime unreachable,
                        }
                    } else {
                        switch (tag) {
                            .viewport_create_with_fds_cpu => {
                                const cpu = @field(event, @tagName(tag));
                                const vp: Viewport = .init_cpu(
                                    key,
                                    e.fds.front,
                                    e.fds.back,
                                    @intCast(cpu.width),
                                    @intCast(cpu.height),
                                    cpu.format,
                                );
                                _ = try wl.buffers.double_buffer_create_cpu(wl, vp);
                            },
                            .viewport_create_with_fds_gpu => {
                                const gpu = @field(event, @tagName(tag));
                                const vp: Viewport = .init_gpu(
                                    key,
                                    e.fds.front,
                                    e.fds.back,
                                    @intCast(gpu.width),
                                    @intCast(gpu.height),
                                    gpu.format,
                                    gpu.gbm_bo_modifier,
                                );
                                _ = try wl.buffers.double_buffer_create_gpu(wl, vp);
                            },
                            else => comptime unreachable,
                        }
                    }
                },
                .win32 => @panic("TODO"),
            }
        },
        .viewport_buffers_swap => |key| {
            switch (ws.native) {
                .wayland => |wl| {
                    for (wl.windows.values()) |win| {
                        const buffer = wl.buffers.double_buffers.get(win.subsurface.buffer_id) orelse {
                            continue;
                        };
                        if (!std.meta.eql(buffer.viewport.key, key))
                            continue;

                        win.subsurface.damaged = true;
                        wl.buffers.double_buffer_swap(win.subsurface.buffer_id);

                        wl.window_commit(win);
                    }

                    _ = wl.display.flush();
                },
                .win32 => @panic("TODO"),
            }
        },
        .window_create => |key| {
            switch (ws.native) {
                .wayland => |wl| {
                    const id = ws.window_next_id;
                    ws.window_next_id = @enumFromInt(@intFromEnum(id) + 1);

                    const window = try wl.window_create(ws, id, key);
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
                        win.buffer.bytes_per_pixel,
                    );
                    wl.window_commit(win);
                    _ = wl.display.flush();

                    const vp_key = wl.buffers.double_buffer_viewport_key(
                        win.subsurface.buffer_id,
                    ) orelse {
                        return;
                    };

                    ws.server_event_queue.put(
                        .{
                            .viewport_resize = .{
                                .client_id = vp_key.client_id,
                                .resize = .{
                                    .viewport_id = vp_key.viewport_id,
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

                    dis.result_queue.put(.{ .wayland_dispatch = true });
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

pub const NativeWindowSystem = union(enum) {
    wayland: *Wayland,
    win32: *Win32,
};

const std = @import("std");
const Io = std.Io;
const events = @import("../events.zig");
const Viewport = @import("Viewport.zig");
const ClientID = @import("../server/Clients.zig").ClientID;
const ViewportID = @import("../protocol/types.zig").ViewportID;
const Wayland = @import("Wayland.zig");
const Win32 = @import("Win32.zig");
const WindowBase = @import("WindowBase.zig");
const os_tag = @import("builtin").os.tag;
const log = std.log.scoped(.WindowSystem);
