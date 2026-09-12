pub fn message_peek(io: Io, stream: net.Stream, timeout: Io.Timeout) !?net.IncomingMessage {
    var buf: [@sizeOf(MessageHeader)]u8 = undefined;
    const peek = common.operation_net_receive_peek(MessageHeader, io, stream, timeout, &buf) catch |err|
        switch (err) {
            error.Timeout => return null,
            else => |e| return e,
        };

    if (peek.data.len == 0) {
        return error.ConnectionClosed;
    }

    return peek;
}

pub fn read_and_parse_data_json(
    io: Io,
    arena: std.mem.Allocator,
    stream: net.Stream,
    header: MessageHeader,
    receive_buf: []u8,
) !MessagePayload {
    switch (header.message_tag) {
        inline else => |tag| {
            const T = utils.TypeOfField(MessagePayload, @tagName(tag));
            const parsed = try common.message_receive_and_parse_json(
                MessageHeader,
                T,
                io,
                arena,
                stream,
                header,
                receive_buf,
            );

            return @unionInit(MessagePayload, @tagName(tag), parsed);
        },
    }
}

pub fn parse_message_header(data: []const u8) !MessageHeader {
    return try common.parse_message_header(MessageHeader, data);
}

pub const MessageHeader = types.MessageHeaderGeneric(MessageTag);

pub const Message = struct {
    header: MessageHeader,
    payload: []const u8,
};

pub const MessageTag = std.meta.Tag(MessagePayload);
pub const MessagePayload = union(enum(u32)) {
    register: Register,
    generate_client_full_id: Void,

    buffer_create_cpu: BufferCreateCpu,
    buffer_create_gbm_bo: BufferCreateGbmBo,

    buffer_destroy: BufferDestroy,

    buffer_present: BufferPresent,
    buffer_present_with_sync: BufferPresentWithSync,

    viewport_create: ViewportCreate,
    viewport_destroy: ViewportDestroy,

    sub_viewport_embed: SubViewportEmbed,
    sub_viewport_pos_set: SubViewportPosSet,
    sub_viewport_size_set: SubViewportSizeSet,
    sub_viewport_display_state_set: SubViewportDisplayStateSet,

    cursor_shape_set: CursorShape,
};

pub const Register = struct {
    full_id: ?types.ClientFullID,
};

pub const Void = struct {};

pub const SubViewportDisplayStateSet = struct {
    sub_viewport_id: types.SubViewportID,
    state: types.ViewportDisplayState,
};

pub const ViewportCreate = struct {
    viewport_id: types.ViewportID,
    create_sync_timeline: bool,

    size: types.Size,
};

pub const ViewportDestroy = struct {
    viewport_id: types.ViewportID,
};

pub const SubViewportEmbed = struct {
    client_id_to_embed: types.ClientID,
    sub_viewport_id: types.SubViewportID,
    rect: types.Rect,
    embeder_viewport_id: types.ViewportID,
};

pub const SubViewportPosSet = struct {
    sub_viewport_id: types.SubViewportID,
    pos: types.Pos,
};

pub const SubViewportSizeSet = struct {
    sub_viewport_id: types.SubViewportID,
    size: types.Size,
};

pub const BufferCreateCpuWithFd = struct {
    buffer_id: types.BufferID,

    fd: types.CpuBufferHandle,

    size: types.Size,
    format: types.BufferFormat,
};

pub const BufferCreateCpu = struct {
    viewport_id: types.ViewportID,
    size: types.Size,
    format: types.BufferFormat,
};

pub const BufferCreateGbmBo = struct {
    viewport_id: types.ViewportID,
    size: types.Size,
    format: types.BufferFormat,
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
    viewport_id: types.ViewportID,
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
