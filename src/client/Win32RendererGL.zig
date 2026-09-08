const Win32RendererGL = @This();

buffers_collection: buffers.Collection(Buffer),

pub fn init() Win32RendererGL {
    return .{ .buffers_collection = .empty };
}

pub fn deinit(r: *Win32RendererGL, gpa: std.mem.Allocator) void {
    r.buffers_collection.deinit(gpa);
}

pub fn has_buffer(r: *Win32RendererGL, id: BufferID) bool {
    return r.buffers_collection.has(id);
}

pub fn frame_end(_: *Win32RendererGL, _: *Buffer) void {
    unreachable;
}

pub fn buffer_size(r: *const Win32RendererGL) ptypes.Size {
    const buffer = r.buffers_collection.available.values()[0];
    return .{
        .width = buffer.width,
        .height = buffer.height,
    };
}

pub fn get_buffer(_: *Win32RendererGL, _: i64) error{Timeout}!*Buffer {
    unreachable;
}

pub fn resize(
    r: *Win32RendererGL,
    vp: *Viewport,
    requested_size: ptypes.Size,
) !void {
    std.debug.assert(r.buffers_collection.available.count() > 0);
    const new_width, const new_height = utils.new_dimensions(
        requested_size.width,
        requested_size.height,
    );

    const buffer = r.buffers_collection.available.values()[0];
    if (buffer.width < new_width or buffer.height < new_height) {
        try buffers.buffers_resize(
            Win32RendererGL.Buffer,
            2,
            vp,
            vp.client,
            &r.buffers_collection,
            .{ vp.client, new_width, new_height, vp.format },
        );
    }
}

pub fn buffer_destroyed(r: *Win32RendererGL, id: BufferID) void {
    var i = r.buffers_collection.old.count();
    while (i > 0) {
        i -= 1;
        const old = &r.buffers_collection.old.values()[i];
        if (old.id == id) {
            old.deinit();
            _ = r.buffers_collection.old.orderedRemove(old.id);
        }
    }
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
    handle: ptypes.AcquireTimelineHandle,

    pub fn init() AcquireTimeline {
        unreachable;
    }
};

pub const ReleaseTimeline = struct {
    point: ptypes.ReleaseTimelinePoint,
    handle: ptypes.ReleaseTimelineHandle,

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
const buffers = @import("buffers.zig");
const BufferStatus = @import("buffers.zig").BufferStatus;
const log = std.log.scoped(.RendererGL);
const CreateStatus = Client.CreateStatus;
const Viewport = @import("Viewport.zig");
const utils = @import("utils");
