pub const MessageHeader = common.MessageHeaderGeneric(MessageTag);
pub const WithClientUUID = common.WithClientUUID;

pub const Message = struct {
    header: MessageHeader,
    data: []const u8,
};

pub const MessageTag = std.meta.Tag(MessagePayload);
pub const MessagePayload = union(enum(u32)) {
    registered: Void,

    viewport_create: ViewportCreate,
    viewport_created: ViewportCreated,
    viewport_resize: ViewportResize,
    viewport_close: ViewportClose,
    viewport_display_state: ViewportDisplayState,

    remote_viewport_created: RemoteViewportCreated,
    remote_viewport_display_state: RemoteViewportDisplayState,
    remote_viewport_render_size: RemoteViewportRenderSize,
    remote_viewport_closed: RemoteViewportClosed,

    client_registered: ClientRegistered,
    client_disconnected: ClientDisconnected,

    buffer_released: BufferReleased,
    buffer_created_cpu: BufferCreatedCpu,
    buffer_created_gbm_bo: BufferCreatedGbmBo,

    texture_created_d3d: TextureCreatedD3D,

    frame_render: FrameRender,

    keyboard_enter: KeyboardEnter,
    keyboard_leave: KeyboardLeave,
    keyboard_char: KeyboardChar,
    keyboard_key: KeyboardKey,
    mouse_enter: MouseEnter,
    mouse_leave: MouseLeave,
    mouse_motion: MouseMotion,
    mouse_button: MouseButton,
    mouse_scroll: MouseScroll,

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        switch (self) {
            inline else => |v, tag| {
                try utils.format_active_union_field(v, @tagName(tag), writer);
            },
        }
    }
};

pub const Void = struct {};

pub fn MayFail(comptime T: type, comptime R: type) type {
    std.debug.assert(@typeInfo(R) == .@"enum");
    return union(enum) {
        pub const Success = T;
        pub const FailureReason = R;

        success: T,
        failure: struct {
            request_id: types.RequestID,
            reason: FailureReason,
        },

        pub fn ok(v: Success) @This() {
            return .{ .success = v };
        }

        pub fn failed(rid: types.RequestID, v: FailureReason) @This() {
            return .{ .failure = .{ .request_id = rid, .reason = v } };
        }

        pub fn request_id(self: @This()) types.RequestID {
            return switch (self) {
                inline else => |v| v.request_id,
            };
        }
    };
}

pub const RequestFailed = struct {
    request_id: types.RequestID,
    reason: types.RequestFailureReason,
};

pub const BufferCreatedCpu = MayFail(struct {
    request_id: types.RequestID,
    buffer_id: types.BufferID,
    handle: types.CpuBufferHandle,
    size: types.Size,
    format: types.BufferFormat,
}, enum { failed_to_create_system_resources });

pub const BufferCreatedGbmBo = MayFail(struct {
    request_id: types.RequestID,
    buffer_id: types.BufferID,
    fds: types.BufferAndTimelineFds,
    size: types.Size,
    stride: u32,
    format: types.BufferFormat,
}, enum {
    invalid_size,
    failed_to_create_system_resources,
});

pub const TextureCreatedD3D = MayFail(struct {
    request_id: types.RequestID,
    buffer_id: types.BufferID,
    texture_handle: types.D3DTextureSharedHandle,
    acquire_fence_handle: types.D3DAcquireFenceSharedHandle,
    release_fence_handle: types.D3DReleaseFenceSharedHandle,
    size: types.Size,
    format: types.BufferFormat,
    version: types.D3DVersion,
}, enum {
    invalid_size,
    failed_to_create_system_resources,
});

pub const ViewportResize = struct {
    viewport_id: types.ViewportID,
    size: types.Size,
};

pub const RemoteViewportCreated = struct {
    remote_viewport_id: types.RemoteViewportID,
    status: types.Status,
    render_size: types.Size,
    viewport_key: types.ViewportKey,
};

pub const RemoteViewportClosed = struct {
    viewport_key: types.ViewportKey,
};

pub const ClientRegistered = struct {
    client_uuid: types.ClientUUID,
};

pub const ClientDisconnected = struct {
    client_uuid: types.ClientUUID,
};

pub const ViewportCreate = struct {
    viewport_id: types.ViewportID,
    size: types.Size,
};

pub const ViewportCreated = MayFail(struct {
    request_id: types.RequestID,
    viewport_id: types.ViewportID,
}, enum {
    parent_viewport_does_not_exist,
    invalid_viewport_id,
    failed_to_create_window,
    failed_to_create_system_resources,
    invalid_size,
});

pub const BufferReleased = struct {
    viewport_id: types.ViewportID,
    buffer_id: types.BufferID,
};

pub const FrameRender = struct {
    viewport_id: types.ViewportID,
    refresh_cycle: u32,
};

pub const ViewportClose = struct {
    viewport_id: types.ViewportID,
};

pub const ViewportDisplayState = struct {
    viewport_id: types.ViewportID,
    state: types.ViewportDisplayState,
};

pub const RemoteViewportDisplayState = struct {
    viewport_key: types.ViewportKey,
    state: types.ViewportDisplayState,
};

pub const RemoteViewportRenderSize = struct {
    viewport_key: types.ViewportKey,
    size: types.Size,
};

pub const KeyboardChar = struct {
    viewport_id: types.ViewportID,
    char: u32,
};

pub const KeyboardKey = struct {
    viewport_id: types.ViewportID,
    key: input.Key,
    state: input.KeyState,
    modifiers: input.Modifiers,
};

pub const KeyboardEnter = struct {
    viewport_id: types.ViewportID,
};

pub const KeyboardLeave = struct {
    viewport_id: types.ViewportID,
};

pub const MouseEnter = struct {
    viewport_id: types.ViewportID,
};

pub const MouseLeave = struct {
    viewport_id: types.ViewportID,
};

pub const MouseMotion = struct {
    viewport_id: types.ViewportID,
    x: f32,
    y: f32,
};

pub const MouseButton = struct {
    viewport_id: types.ViewportID,
    button: input.MouseButton,
    state: input.MouseState,
};

pub const MouseScroll = struct {
    viewport_id: types.ViewportID,
    axis: types.ScrollAxis,
    value: f32,
};

pub fn parse_message_header(data: []const u8) !MessageHeader {
    return try common.parse_message_header(MessageHeader, data);
}

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const utils = @import("utils");
const types = @import("types.zig");
const common = @import("common.zig");
const os = @import("builtin").os.tag;
const input = @import("input.zig");
const constants = @import("constants");
const c_linux = @import("c_linux");
