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
    _ = src;
    // log.debug("[{s}] <- {s}.{s}({f})", .{
    //     @src().fn_name,
    //     std.fs.path.stem(src.file),
    //     src.fn_name,
    //     event,
    // });
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
    _ = src;
    // log.debug("[{s}] <- {s}.{s}({f})", .{
    //     @src().fn_name,
    //     std.fs.path.stem(src.file),
    //     src.fn_name,
    //     event,
    // });
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

pub fn server_get_many(dispatch: *Dispatch, buf: []ServerEvent) error{Canceled}!usize {
    return dispatch.server.queue.get(dispatch.io, buf, 1) catch |err| switch (err) {
        error.Closed => unreachable,
        error.Canceled => |e| return e,
    };
}

pub const WindowSystemResultQueue = IoQueue(WindowSystemResult);
pub const WindowSystemQueue = IoQueue(WindowSystemEvent);
pub const WindowSystemEvent = union(enum) {
    const Payload = client_to_server.MessagePayload;

    exit,
    client_registered: ClientRegistered,
    client_disconnected: ClientID,

    buffer_create_cpu_with_fd: WithClientID(Payload.BufferCreateCpuWithFd),
    buffer_create_gpu_with_fds: WithClientID(Payload.BufferCreateGpuWithFds),
    buffer_present: WithClientID(Payload.BufferPresent),
    buffer_present_with_sync: WithClientID(Payload.BufferPresentWithSync),
    buffer_destroy: WithClientID(Payload.BufferDestroy),

    viewport_create: WithClientID(Payload.ViewportCreate),
    viewport_destroy: WithClientID(Payload.ViewportDestroy),
    sub_viewport_embed: WithClientID(Payload.SubViewportEmbed),
    sub_viewport_pos_set: WithClientID(Payload.SubViewportPosSet),
    sub_viewport_size_set: WithClientID(Payload.SubViewportSizeSet),
    sub_viewport_display_state_set: WithClientID(Payload.SubViewportDisplayStateSet),

    window_resize_by_display_server: WindowResize,
    wayland_dispatch: struct {
        signal: *Io.Event,
    },

    cursor_shape_set: WithClientID(Payload.CursorShape),

    keyboard_key: KeyboardKey,
    keyboard_enter: KeyboardEnter,
    keyboard_leave: KeyboardLeave,

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

    pub const ClientRegistered = struct {
        client_id: ClientID,
    };

    pub const WindowResize = struct {
        id: WindowID,
        size: ptypes.Size,
    };

    pub fn TypeOf(comptime tag: std.meta.Tag(WindowSystemEvent)) type {
        return utils.TypeOfField(WindowSystemEvent, @tagName(tag));
    }

    pub const KeyboardChar = struct {
        char: u32,
    };

    pub const KeyboardKey = struct {
        key: pinput.Key,
        state: pinput.KeyState,
        char: ?u32,
    };

    pub const KeyboardEnter = struct {
        window_id: WindowID,
    };

    pub const KeyboardLeave = struct {
        window_id: WindowID,
    };

    pub const MouseEnter = struct {
        client_id: ClientID,
        viewport_id: ptypes.ViewportID,
        window_id: WindowID,
    };

    pub const MouseLeave = struct {
        client_id: ClientID,
        viewport_id: ptypes.ViewportID,
        window_id: WindowID,
    };

    pub const MouseMotion = struct {
        x: f32,
        y: f32,
    };

    pub const MouseButton = struct {
        button: pinput.MouseButton,
        state: pinput.MouseState,
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
    const Payload = server_to_client.MessagePayload;

    exit,

    unknown_client_connected: net.Stream,

    viewport_create: WithClientID(Payload.ViewportCreate),
    viewport_created: WithClientID(Payload.ViewportCreated),
    viewport_resize: WithClientID(Payload.ViewportResize),
    viewport_close: WithClientID(Payload.ViewportClose),
    viewport_display_state: WithClientID(Payload.ViewportDisplayState),

    sub_viewport_embeded: WithClientID(Payload.SubviewportCreated),
    sub_viewport_display_state: WithClientID(Payload.SubViewportDisplayState),
    sub_viewport_closed: WithClientID(Payload.SubviewportClosed),

    frame_render: WithClientID(Payload.FrameRender),

    buffer_released: WithClientID(Payload.BufferReleased),
    buffer_destroyed: WithClientID(Payload.BufferDestroyed),
    buffer_created: WithClientID(Payload.BufferCreated),

    keyboard_key: WithClientID(Payload.KeyboardKey),
    keyboard_char: WithClientID(Payload.KeyboardChar),
    mouse_enter: WithClientID(Payload.MouseEnter),
    mouse_leave: WithClientID(Payload.MouseLeave),
    mouse_motion: WithClientID(Payload.MouseMotion),
    mouse_button: WithClientID(Payload.MouseButton),
    mouse_scroll: WithClientID(Payload.MouseScroll),

    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try utils.format_union(self, writer);
    }
};

pub fn WithClientID(comptime T: type) type {
    return struct {
        client_id: ClientID,
        payload: T,
    };
}

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
const net = Io.net;
const ptypes = @import("protocol").types;
const pinput = @import("protocol").input;
const server_to_client = @import("protocol").server_to_client;
const client_to_server = @import("protocol").client_to_server;
const log = std.log.scoped(.Dispatch);
const SourceLocation = std.builtin.SourceLocation;
const ViewportFds = ptypes.ViewportFds;
const ViewportID = ptypes.ViewportID;
const BufferFormat = ptypes.BufferFormat;
const BufferID = ptypes.BufferID;
const ClientID = ptypes.ClientID;
const ViewportKey = @import("WindowSystem.zig").ViewportKey;
const WindowID = @import("WindowSystem.zig").WindowID;
const utils = @import("utils");
const constants = @import("constants");
