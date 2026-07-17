const Dispatch = @This();

io: Io,
gpa: std.mem.Allocator,
window_system: *WindowSystemQueue,
server: *ServerQueue,

pub fn create(io: Io, gpa: std.mem.Allocator) !*Dispatch {
    const dispatch = try gpa.create(Dispatch);
    const window_system = try WindowSystemQueue.create(gpa);
    const server = try ServerQueue.create(gpa);

    dispatch.* = .{
        .io = io,
        .gpa = gpa,
        .server = server,
        .window_system = window_system,
    };

    return dispatch;
}

pub fn window_system_put(dispatch: *Dispatch, event: WindowSystemEvent) error{Canceled}!void {
    dispatch.window_system.queue.putOne(dispatch.io, event) catch |err| switch (err) {
        error.Closed => unreachable,
        error.Canceled => |e| return e,
    };
}

pub fn window_system_get(dispatch: *Dispatch) error{Canceled}!WindowSystemEvent {
    return dispatch.window_system.queue.getOne(dispatch.io) catch |err| switch (err) {
        error.Closed => unreachable,
        error.Canceled => |e| return e,
    };
}

pub fn server_put(dispatch: *Dispatch, event: Server) error{Canceled}!void {
    dispatch.server.queue.putOne(dispatch.io, event) catch |err| switch (err) {
        error.Closed => unreachable,
        error.Canceled => |e| return e,
    };
}

pub fn server_get(dispatch: *Dispatch) error{Canceled}!Server {
    return dispatch.server.queue.getOne(dispatch.io) catch |err| switch (err) {
        error.Closed => unreachable,
        error.Canceled => |e| return e,
    };
}

pub const WindowSystemResultQueue = IoQueue(WindowSystemResult);
pub const WindowSystemQueue = IoQueue(WindowSystemEvent);
pub const WindowSystemEvent = union(enum) {
    buffer_create_cpu_with_fd: BufferCreateCpuWithFd,
    buffer_create_gpu_with_fd: BufferCreateGpuWithFd,
    buffer_present: BufferPresent,

    window_create: WindowCreate,
    window_resize_by_display_server: struct {
        id: WindowID,
        width: i32,
        height: i32,
    },
    wayland_dispatch: struct {
        result_queue: *WindowSystemResultQueue,
    },

    pub const WindowCreate = struct {
        client_id: ClientID,
        viewport_id: ViewportID,
        width: u32,
        height: u32,
    };

    pub const BufferCreateCpuWithFd = struct {
        client_id: ClientID,
        buffer_id: BufferID,

        fd: c_int,

        width: u32,
        height: u32,
        format: BufferFormat,
    };

    pub const BufferCreateGpuWithFd = struct {
        client_id: ClientID,
        buffer_id: BufferID,

        fd: c_int,

        width: u32,
        height: u32,
        format: BufferFormat,

        gbm_bo_modifier: u64,
    };

    pub const BufferPresent = struct {
        client_id: ClientID,
        viewport_id: ViewportID,
        buffer_id: BufferID,
    };
};

pub const WindowSystemResult = union(enum) {
    wayland_dispatch: bool,
};

pub const ServerQueue = IoQueue(Server);
pub const Server = union(enum) {
    viewport_resize: struct {
        client_id: ClientID,
        resize: ViewportResize,
    },
    buffer_released: WindowSystemEvent.BufferPresent,
};

pub fn IoQueue(comptime T: type) type {
    return struct {
        buffer: []T,
        queue: Io.Queue(T),

        pub const Event = T;

        pub fn create(gpa: std.mem.Allocator) !*@This() {
            const queue = try gpa.create(@This());
            errdefer gpa.destroy(queue);
            queue.* = try .init(gpa);
            return queue;
        }

        pub fn init(gpa: std.mem.Allocator) !@This() {
            const buffer = try gpa.alloc(T, 512);
            return .{
                .buffer = buffer,
                .queue = .init(buffer),
            };
        }
    };
}

const std = @import("std");
const Io = std.Io;
const ViewportResize = @import("protocol/types.zig").ViewportResize;
const ViewportFds = @import("protocol/types.zig").ViewportFds;
const ViewportID = @import("protocol/types.zig").ViewportID;
const BufferFormat = @import("protocol/types.zig").BufferFormat;
const BufferID = @import("protocol/types.zig").BufferID;
const Viewport = @import("window_system/Viewport.zig");
const ClientID = @import("server/Clients.zig").ClientID;
const ViewportKey = @import("window_system/WindowSystem.zig").ViewportKey;
const WindowBase = @import("window_system/WindowBase.zig");
const WindowID = WindowBase.WindowID;
