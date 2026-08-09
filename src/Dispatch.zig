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

pub fn destroy(dispatch: *Dispatch) void {
    dispatch.window_system.destroy(dispatch.io, dispatch.gpa);
    dispatch.server.destroy(dispatch.io, dispatch.gpa);

    dispatch.gpa.destroy(dispatch);
}

pub fn window_system_put(dispatch: *Dispatch, src: SourceLocation, event: WindowSystemEvent) error{Canceled}!void {
    log.debug("[{s}] <- {s}.{s}({f})", .{
        @src().fn_name,
        std.fs.path.stem(src.file),
        src.fn_name,
        event,
    });
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

pub fn server_put(dispatch: *Dispatch, src: SourceLocation, event: ServerEvent) error{Canceled}!void {
    log.debug("[{s}] <- {s}.{s}({f})", .{
        @src().fn_name,
        std.fs.path.stem(src.file),
        src.fn_name,
        event,
    });
    dispatch.server.queue.putOne(dispatch.io, event) catch |err| switch (err) {
        error.Closed => unreachable,
        error.Canceled => |e| return e,
    };
}

pub fn server_get(dispatch: *Dispatch) error{Canceled}!ServerEvent {
    return dispatch.server.queue.getOne(dispatch.io) catch |err| switch (err) {
        error.Closed => unreachable,
        error.Canceled => |e| return e,
    };
}

pub const WindowSystemResultQueue = IoQueue(WindowSystemResult);
pub const WindowSystemQueue = IoQueue(WindowSystemEvent);
pub const WindowSystemEvent = union(enum) {
    exit,
    client_connected: ClientID,
    client_disconnected: ClientID,

    buffer_create_cpu_with_fd: BufferCreateCpuWithFd,
    buffer_create_gpu_with_fds: BufferCreateGpuWithFds,
    buffer_present: BufferPresent,
    buffer_present_with_sync: BufferPresentWithSync,
    buffer_destroy: BufferDestroy,

    viewport_resize: ViewportResize,

    window_create: WindowCreate,
    window_resize_by_display_server: WindowResize,
    wayland_dispatch: struct {
        result_queue: *WindowSystemResultQueue,
    },

    mouse_enter: MouseEnter,
    mouse_leave: MouseLeave,
    mouse_motion: MouseMotion,
    mouse_button: MouseButton,
    mouse_scroll: MouseScroll,

    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .wayland_dispatch => |_, tag| {
                try writer.print("{s}", .{@tagName(tag)});
            },
            inline else => |v, tag| {
                try utils.format_active_union_field(v, @tagName(tag), writer);
            },
        }
    }

    pub const WindowResize = struct {
        id: WindowID,
        width: i32,
        height: i32,
    };

    pub const WindowCreate = struct {
        client_id: ClientID,
        viewport_id: ViewportID,
        width: u32,
        height: u32,
        create_sync_timeline: bool,
    };

    pub const BufferCreateCpuWithFd = struct {
        client_id: ClientID,
        buffer_id: BufferID,

        fd: ptypes.CpuBufferFd,

        width: u32,
        height: u32,
        format: BufferFormat,
    };

    pub const BufferCreateGpuWithFds = struct {
        client_id: ClientID,
        buffer_id: BufferID,

        fds: ptypes.BufferAndTimelineFds,

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

    pub const BufferPresentWithSync = struct {
        client_id: ClientID,
        viewport_id: ViewportID,
        buffer_id: BufferID,
        acquire_point: ptypes.AcquireTimelinePoint,
        release_point: ptypes.ReleaseTimelinePoint,
    };

    pub const BufferDestroy = struct {
        client_id: ClientID,
        buffer_id: BufferID,
    };

    pub const ViewportResize = struct {
        client_id: ClientID,
        viewport_id: ViewportID,
        width: u32,
        height: u32,
    };

    pub const MouseEnter = struct {
        client_id: ClientID,
        viewport_id: ptypes.ViewportID,
    };

    pub const MouseLeave = struct {
        client_id: ClientID,
        viewport_id: ptypes.ViewportID,
    };

    pub const MouseMotion = struct {
        x: f32,
        y: f32,
    };

    pub const MouseButton = struct {
        button: ptypes.MouseButton,
        state: ptypes.MouseButtonState,
    };

    pub const MouseScroll = struct {
        axis: ptypes.ScrollAxis,
        value: f32,
    };
};

pub const WindowSystemResult = union(enum) {
    wayland_dispatch: bool,
};

pub const ServerQueue = IoQueue(ServerEvent);
pub const ServerEvent = union(enum) {
    exit,

    viewport_resize: WithClientID(ptypes.ViewportResize),

    buffer_released: WithClientID(MessagePayload.BufferReleased),
    buffer_destroyed: WithClientID(MessagePayload.BufferDestroyed),
    buffer_created: WithClientID(MessagePayload.BufferCreated),

    mouse_enter: WithClientID(MessagePayload.MouseEnter),
    mouse_leave: WithClientID(MessagePayload.MouseLeave),
    mouse_motion: WithClientID(MessagePayload.MouseMotion),
    mouse_button: WithClientID(MessagePayload.MouseButton),
    mouse_scroll: WithClientID(MessagePayload.MouseScroll),

    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try utils.format_union(self, writer);
    }

    fn WithClientID(comptime T: type) type {
        return struct {
            client_id: ClientID,
            payload: T,
        };
    }
};

pub fn IoQueue(comptime T: type) type {
    return struct {
        buffer: []T,
        queue: Io.Queue(T),

        pub const Event = T;

        pub fn create(gpa: std.mem.Allocator) !*@This() {
            const queue = try gpa.create(@This());
            errdefer gpa.destroy(queue);
            const buffer = try gpa.alloc(T, 512);
            queue.* = .{
                .buffer = buffer,
                .queue = .init(buffer),
            };
            return queue;
        }

        pub fn destroy(queue: *@This(), io: Io, gpa: std.mem.Allocator) void {
            queue.queue.close(io);
            gpa.free(queue.buffer);
            gpa.destroy(queue);
        }
    };
}

const std = @import("std");
const Io = std.Io;
const ptypes = @import("protocol").types;
const server_to_client = @import("protocol").server_to_client;
const log = std.log.scoped(.Dispatch);
const SourceLocation = std.builtin.SourceLocation;
const ViewportFds = ptypes.ViewportFds;
const ViewportID = ptypes.ViewportID;
const BufferFormat = ptypes.BufferFormat;
const BufferID = ptypes.BufferID;
const ClientID = @import("server/Clients.zig").ClientID;
const ViewportKey = @import("WindowSystem.zig").ViewportKey;
const WindowID = @import("WindowSystem.zig").WindowID;
const utils = @import("utils");
const MessagePayload = server_to_client.MessagePayload;
