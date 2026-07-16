pub const WindowSystemResultQueue = IoQueue(WindowSystemResult);
pub const WindowSystemQueue = IoQueue(WindowSystem);
pub const WindowSystem = union(enum) {
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
    buffer_released: WindowSystem.BufferPresent,
};

const IoQueue = @import("io_queue.zig").IoQueue;
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
