pub const Event = union(enum) {
    viewport_create_with_fds: struct {
        client_id: ClientID,
        viewport_id: protocol.ViewportID,
        viewport: Viewport,
    },
    viewport_buffers_swap: ViewportKey,

    window_create: ViewportKey,
    window_resize_by_display_server: struct {
        id: WindowID,
        width: i32,
        height: i32,
    },
    wayland_dispatch,
};

pub const EventQueue = struct {
    io: Io,
    gpa: std.mem.Allocator,
    buffer: []Event,
    queue: Io.Queue(Event),

    pub fn init(io: Io, gpa: std.mem.Allocator) !EventQueue {
        const buffer = try gpa.alloc(Event, 1024);
        return .{
            .io = io,
            .gpa = gpa,
            .buffer = buffer,
            .queue = .init(buffer),
        };
    }

    pub fn put(queue: *EventQueue, event: Event) void {
        queue.queue.putOneUncancelable(queue.io, event) catch |err| switch (err) {
            error.Closed => unreachable,
        };
    }
};

const std = @import("std");
const Io = std.Io;
const protocol = @import("../server/protocol.zig");
const Viewport = @import("Viewport.zig");
const ClientID = @import("../server/Clients.zig").ClientID;
const ViewportKey = @import("WindowSystem.zig").ViewportKey;
const WindowBase = @import("WindowBase.zig");
const WindowID = WindowBase.WindowID;
