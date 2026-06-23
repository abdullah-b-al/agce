const WindowSystem = @This();

io: Io,
gpa: std.mem.Allocator,

event_queue: *EventQueue,

viewports: std.array_hash_map.Auto(ViewportKey, Viewport),
window_next_id: WindowBase.WindowID,

native: NativeWindowSystem,

pub fn init_wayland(io: Io, gpa: std.mem.Allocator) !*WindowSystem {
    const event_queue = try gpa.create(EventQueue);
    errdefer gpa.destroy(event_queue);
    event_queue.* = try .init(io, gpa);

    const wl: *Wayland = try .init(gpa, io);
    const ws = try gpa.create(WindowSystem);
    errdefer gpa.destroy(ws);
    ws.* = .{
        .io = io,
        .gpa = gpa,
        .event_queue = event_queue,

        .viewports = .empty,
        .window_next_id = .first,

        .native = .{ .wayland = wl },
    };

    try wl.set_listeners(ws);

    return ws;
}

pub fn event_handle(ws: *WindowSystem, event: Event) !void {
    switch (event) {
        .viewport_create_with_fds => |e| {
            const key: ViewportKey = .{
                .client_id = e.client_id,
                .viewport_id = e.viewport_id,
            };

            // Should this be an error or should we override the buffer, freeing the old one ?
            if (ws.viewports.contains(key)) {
                return error.SharedBufferAlreadyExist;
            }
            try ws.viewports.putNoClobber(ws.gpa, key, e.viewport);
        },
        .viewport_buffers_swap => |key| {
            const viewport = ws.viewports.getPtr(key) orelse return error.ViewportDoesNotExist;
            viewport.swap();

            switch (ws.native) {
                .wayland => |wl| {
                    for (wl.windows.values()) |win| {
                        if (!std.meta.eql(win.base.viewport_key, key))
                            continue;

                        wl.window_buffer_copy_from_back_buffer(ws, win) catch |err| switch (err) {
                            error.ViewportDoesNotExist => unreachable,
                        };

                        wl.window_commit(win);
                    }

                    wl.dispatch();
                },
                .win32 => @panic("TODO"),
            }
        },
        .window_create => |key| {
            switch (ws.native) {
                .wayland => |wl| {
                    const id = ws.window_next_id;
                    ws.window_next_id = @enumFromInt(@intFromEnum(id) + 1);

                    const window = try wl.window_create(ws, .{
                        .id = id,
                        .viewport_key = key,
                    });
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

                    wl.window_buffer_resize(win, args.width, args.height);
                    try wl.window_buffer_copy_from_back_buffer(ws, win);

                    wl.window_commit(win);
                    wl.dispatch();
                    // TODO: Inform the client of the resize

                },
                .win32 => @panic("TODO"),
            }
        },
        .wayland_dispatch => {
            switch (ws.native) {
                .wayland => |wl| _ = wl.display.dispatch(),
                else => {},
            }
        },
    }
}

pub const ViewportKey = struct {
    client_id: ClientID,
    viewport_id: protocol.ViewportID,
};

pub const NativeWindowSystem = union(enum) {
    wayland: *Wayland,
    win32: *win32.State,
};

const std = @import("std");
const Io = std.Io;
const EventQueue = @import("event.zig").EventQueue;
const Event = @import("event.zig").Event;
const Viewport = @import("Viewport.zig");
const ClientID = @import("../server/Clients.zig").ClientID;
const protocol = @import("../server/protocol.zig");
const Wayland = @import("Wayland.zig");
const win32 = @import("win32.zig");
const WindowBase = @import("WindowBase.zig");
