pub const WindowSystemResultQueue = IoQueue(WindowSystemResult);
pub const WindowSystemQueue = IoQueue(WindowSystem);
pub const WindowSystem = union(enum) {
    viewport_create_with_fds_cpu: struct {
        client_id: ClientID,
        viewport_id: ViewportID,
        size: ViewportSize,
        fds: ViewportFds,
    },
    viewport_create_with_fds_gpu: struct {
        client_id: ClientID,
        viewport_id: ViewportID,
        fds: ViewportFds,

        width: u32,
        height: u32,
        format: ViewportFormat,

        gbm_bo_modifier: u64,
    },
    viewport_buffers_swap: ViewportKey,
    viewport_resize: struct {
        client_id: ClientID,
        resize: ViewportResize,
    },

    window_create: ViewportKey,
    window_resize_by_display_server: struct {
        id: WindowID,
        width: i32,
        height: i32,
    },
    wayland_dispatch: struct {
        result_queue: *WindowSystemResultQueue,
    },
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
};

const IoQueue = @import("io_queue.zig").IoQueue;
const std = @import("std");
const Io = std.Io;
const ViewportResize = @import("protocol/types.zig").ViewportResize;
const ViewportSize = @import("protocol/types.zig").ViewportSize;
const ViewportFds = @import("protocol/types.zig").ViewportFds;
const ViewportID = @import("protocol/types.zig").ViewportID;
const ViewportFormat = @import("protocol/types.zig").ViewportFormat;
const Viewport = @import("window_system/Viewport.zig");
const ClientID = @import("server/Clients.zig").ClientID;
const ViewportKey = @import("window_system/WindowSystem.zig").ViewportKey;
const WindowBase = @import("window_system/WindowBase.zig");
const WindowID = WindowBase.WindowID;
