pub fn parse_message_header(data: []const u8) !MessageHeader {
    return try common.parse_message_header(MessageHeader, data);
}

pub const MessageHeader = common.MessageHeaderGeneric(MessageTag);
pub const WithClientUUID = common.WithClientUUID;

pub const Message = struct {
    header: MessageHeader,
    payload: []const u8,
};

pub const MessageTag = std.meta.Tag(MessagePayload);
pub const MessagePayload = union(enum(u32)) {
    register: Register,

    wake_up: Void,
    queue_pop: Void,

    buffer_create_cpu: BufferCreateCpu,
    buffer_create_gbm_bo: BufferCreateGbmBo,
    texture_create_d3d: TextureCreateD3D,

    buffer_destroy: BufferDestroy,

    buffer_present: BufferPresent,
    buffer_present_with_sync: BufferPresentWithSync,

    viewport_create: ViewportCreate,
    viewport_destroy: ViewportDestroy,
    viewport_pos_set: ViewportPosSet,
    viewport_size_set: ViewportSizeSet,
    viewport_display_state_set: ViewportDisplayStateSet,
    viewport_close: RemoteViewportClose,

    remote_viewport_create: RemoteViewportCreate,

    cursor_shape_set: CursorShape,
};

pub const Register = struct {
    uuid: types.ClientUUID,
    pid: ?types.PID,
    is_local: bool,
};

pub const Void = struct {};

pub const ViewportDisplayStateSet = struct {
    viewport_key: types.ViewportKey,
    state: types.ViewportDisplayState,
};

pub const ViewportCreate = struct {
    parent_id: ?types.ViewportID,
    request_id: types.RequestID,
    viewport_id: types.ViewportID,
    format: types.BufferFormat,
    buffer_type: types.BufferType,

    rect: types.Rect,
};

pub const ViewportDestroy = struct {
    viewport_id: types.ViewportID,
};

pub const RemoteViewportCreate = struct {
    client_uuid_to_embed: types.ClientUUID,
    remote_viewport_id: types.RemoteViewportID,
    rect: types.Rect,
    embeder_viewport_id: types.ViewportID,
};

pub const ViewportPosSet = struct {
    viewport_key: types.ViewportKey,
    pos: types.Pos,
};

pub const ViewportSizeSet = struct {
    viewport_key: types.ViewportKey,
    size: types.Size,
};

pub const RemoteViewportClose = struct {
    viewport_key: types.ViewportKey,
};

pub const BufferCreateCpuWithFd = struct {
    buffer_id: types.BufferID,

    fd: types.CpuBufferHandle,

    size: types.Size,
    format: types.BufferFormat,
};

pub const BufferCreateCpu = struct {
    request_id: types.RequestID,
    size: types.Size,
    format: types.BufferFormat,
};

pub const BufferCreateGbmBo = struct {
    request_id: types.RequestID,
    size: types.Size,
    format: types.BufferFormat,
};

pub const TextureCreateD3D = struct {
    request_id: types.RequestID,
    size: types.Size,
    format: types.BufferFormat,
    version: types.D3DVersion,
};

pub const BufferPresent = struct {
    buffer_id: types.BufferID,
    viewport_id: types.ViewportID,
    viewport_size: types.Size,
};

pub const BufferPresentWithSync = struct {
    buffer_id: types.BufferID,
    viewport_id: types.ViewportID,
    acquire_point: types.AcquireTimelinePoint,
    release_point: types.ReleaseTimelinePoint,
    viewport_size: types.Size,
};

pub const BufferDestroy = struct {
    buffer_id: types.BufferID,
};

pub const CursorShape = struct {
    shape: types.CursorShape,
};

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const c_linux = @import("c_linux");
const os_tag = @import("builtin").os.tag;
const types = @import("types.zig");
const common = @import("common.zig");
const utils = @import("utils");
const constants = @import("constants");
