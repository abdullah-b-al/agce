const Win32RendererGL = @This();

buffers: std.array_hash_map.Auto(BufferID, Buffer),

pub fn init() Win32RendererGL {
    return .{ .buffers = .empty };
}

pub fn deinit(r: *Win32RendererGL, gpa: std.mem.Allocator) void {
    r.buffers.deinit(gpa);
}

pub fn frame_end(_: *Win32RendererGL, _: *Buffer) void {
    unreachable;
}

pub fn buffer_size(r: *const Win32RendererGL) ptypes.Size {
    const buffer = r.buffers.values()[0];
    return .{
        .width = buffer.width,
        .height = buffer.height,
    };
}

pub fn get_buffer(_: *Win32RendererGL, _: i64) error{Timeout}!*Buffer {
    unreachable;
}

pub const Buffer = struct {
    id: BufferID,
    width: i32,
    height: i32,

    format: ptypes.BufferFormat,
    released: bool,

    fbo: glad.GLuint,
    acquire: AcquireTimeline,
    release: ReleaseTimeline,

    pub fn init(_: *Client, _: i32, _: i32, _: ptypes.BufferFormat) !Buffer {
        unreachable;
    }

    pub fn create_on_server(_: Buffer, _: *Viewport, _: *Client) !void {}

    pub fn deinit(_: *Buffer) void {}
};

pub const AcquireTimeline = struct {
    point: ptypes.AcquireTimelinePoint,
    handle: ptypes.DrmSyncobjAcquireTimelineHandle,

    pub fn init() AcquireTimeline {
        unreachable;
    }
};

pub const ReleaseTimeline = struct {
    point: ptypes.ReleaseTimelinePoint,
    handle: ptypes.DrmSyncobjReleaseTimelineHandle,

    pub fn init() ReleaseTimeline {
        unreachable;
    }
};

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const client_to_server = @import("protocol").client_to_server;
const ptypes = @import("protocol").types;
const ViewportID = ptypes.ViewportID;
const opengl = @import("opengl.zig");
const glad = @import("glad");
const Client = @import("Client.zig");
const BufferID = ptypes.BufferID;
const log = std.log.scoped(.RendererGL);
const CreateStatus = Client.CreateStatus;
const Viewport = @import("Viewport.zig");
const utils = @import("utils");
