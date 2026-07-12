const WindowSystem = @This();

io: Io,
gpa: std.mem.Allocator,

event_queue: *events.WindowSystemQueue,
server_event_queue: *events.ServerQueue,

viewports: std.array_hash_map.Auto(ViewportKey, Viewport),
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

        .viewports = .empty,
        .window_next_id = .first,

        .native = undefined,
    };

    return ws;
}

pub fn event_handle(ws: *WindowSystem, event: events.WindowSystem) !void {
    switch (event) {
        inline .viewport_create_with_fds_gpu,
        .viewport_create_with_fds_cpu,
        => |e| {
            const key: ViewportKey = .{
                .client_id = e.client_id,
                .viewport_id = e.viewport_id,
            };
            try ws.viewports.ensureUnusedCapacity(ws.gpa, 1);
            const viewport: Viewport = switch (event) {
                .viewport_create_with_fds_cpu,
                => |cpu| .init_cpu(
                    key,
                    e.fds.front,
                    e.fds.back,
                    @intCast(cpu.size.width),
                    @intCast(cpu.size.height),
                    cpu.size.format,
                ),
                .viewport_create_with_fds_gpu,
                => |gpu| .init_gpu(
                    key,
                    e.fds.front,
                    e.fds.back,
                    @intCast(gpu.width),
                    @intCast(gpu.height),
                    gpu.format,
                    gpu.gbm_bo_modifier,
                ),
                else => unreachable,
            };

            const gop = ws.viewports.getOrPutAssumeCapacity(key);
            if (gop.found_existing) {
                switch (ws.native) {
                    .wayland => |wl| try wl.viewport_overridden(viewport),
                    .win32 => @panic("TODO"),
                }

                gop.value_ptr.deinit();
            }

            gop.value_ptr.* = viewport;
        },
        .viewport_buffers_swap => |key| {
            switch (ws.native) {
                .wayland => |wl| {
                    for (wl.windows.values()) |win| {
                        const buffer = wl.buffers.double_buffers.get(win.subsurface.buffer_id).?;
                        if (!std.meta.eql(buffer.viewport_key, key))
                            continue;

                        wl.buffers_swap(&win.subsurface) catch |err| switch (err) {
                            error.ViewportDoesNotExist => unreachable,
                        };

                        wl.window_commit(win);
                    }

                    _ = wl.display.flush();
                },
                .win32 => @panic("TODO"),
            }
        },
        .viewport_resize => |e| {
            const key: ViewportKey = .{
                .client_id = e.client_id,
                .viewport_id = e.resize.viewport_id,
            };

            const vp = ws.viewports.getPtr(key) orelse return;

            vp.width = @intCast(e.resize.width);
            vp.height = @intCast(e.resize.height);
            switch (ws.native) {
                .wayland => |wl| {
                    wl.buffer_resize_to_viewport(vp.*);
                },
                .win32 => @panic("TODO"),
            }
        },
        .window_create => |key| {
            switch (ws.native) {
                .wayland => |wl| {
                    const viewport = ws.viewports.get(key) orelse return error.ViewportDoesNotExist;
                    const id = ws.window_next_id;
                    ws.window_next_id = @enumFromInt(@intFromEnum(id) + 1);

                    const window = try wl.window_create(ws, id, viewport);
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
                    ).?;

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
