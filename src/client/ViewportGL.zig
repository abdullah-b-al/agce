const ViewportGL = @This();

client: *Client,

id: ViewportID,
frame_number: usize,

width: u32,
height: u32,
format: ptypes.BufferFormat,

buffers: Buffers(Buffer),

pub fn init(client: *Client, width: u32, height: u32) !ViewportGL {
    const format: ptypes.BufferFormat = .argb8888;

    const id = client.next_viewport_id.increment_for_client();
    return .{
        .client = client,
        .id = id,
        .frame_number = 0,
        .width = width,
        .height = height,
        .format = format,

        .buffers = .empty,
    };
}

pub fn deinit(vp: *ViewportGL) void {
    vp.buffers.deinit(vp.client.gpa);
}

pub fn buffer_new(vp: *ViewportGL, width: u32, height: u32, format: ptypes.BufferFormat) !void {
    try vp.buffers.ensure_unused_capacity(vp.client.gpa, 1);

    var buffer = try Buffer.init(vp.client, width, height, format);
    const bytes = c_linux.gbm_bo_get_bpp(buffer.bo) / 8;
    std.debug.assert(bytes == 4);
    errdefer buffer.deinit();

    try vp.client.send_buffer_create_gpu_with_fds(buffer);

    vp.buffers.pending.appendAssumeCapacity(buffer);
}

pub fn has_buffer(vp: *ViewportGL, id: BufferID) bool {
    return vp.buffers.has(id);
}

pub fn end_frame(vp: *ViewportGL, buffer: *Buffer) !void {
    const gbm = vp.client.gbm.?;
    const gl = vp.client.gl_context.?;

    const sync = glad.eglCreateSync(gl.egl_display, glad.EGL_SYNC_NATIVE_FENCE_ANDROID, null);
    defer _ = glad.eglDestroySync(gl.egl_display, sync);

    glad.glFlush();

    std.debug.assert(sync != glad.EGL_NO_SYNC);

    const egl_sync_fd =
        glad.eglDupNativeFenceFDANDROID(
            vp.client.gl_context.?.egl_display,
            sync,
        );
    std.debug.assert(egl_sync_fd > 0);

    const tmp_syncobj = gbm.syncobj_create();
    defer _ = c_linux.drmSyncobjDestroy(gbm.dri.handle, tmp_syncobj);

    // NOTE: Could the tmp syncobj be reused ?
    const import_result =
        c_linux.drmSyncobjImportSyncFile(gbm.dri.handle, tmp_syncobj, egl_sync_fd);
    std.debug.assert(import_result == 0);

    const transfer_result = c_linux.drmSyncobjTransfer(
        gbm.dri.handle,
        @intFromEnum(buffer.acquire.handle),
        @intFromEnum(buffer.acquire.point),
        tmp_syncobj,
        0,
        0,
    );
    std.debug.assert(transfer_result == 0);

    vp.frame_number += 1;
}

pub fn buffer_present(vp: *ViewportGL, buffer: *Buffer) !void {
    std.debug.assert(buffer.released);
    buffer.released = false;

    try client_to_server.message_send_json(
        vp.client.io,
        vp.client.gpa,
        vp.client.connection,
        .{
            .buffer_present_with_sync = .{
                .viewport_id = vp.id,
                .buffer_id = buffer.id,
                .acquire_point = buffer.acquire.point,
                .release_point = buffer.release.point,
            },
        },
    );

    buffer.acquire.point.advance();
}

pub fn get_buffer(vp: *ViewportGL, timeout_ns: i64) error{ Timeout, NoAvaiableBuffer }!*Buffer {
    const dri = vp.client.gbm.?.dri;

    if (vp.buffers.available.items.len == 0)
        return error.NoAvaiableBuffer;

    for (vp.buffers.available.items) |*buffer| {
        if (buffer.released) return buffer;
    }

    const buffer_len = 2;
    std.debug.assert(buffer_len >= vp.buffers.available.items.len);

    var timelines_buffer: [buffer_len]u32 = undefined;
    var points_buffer: [buffer_len]u64 = undefined;
    var timelines: std.ArrayList(u32) = .initBuffer(&timelines_buffer);
    var points: std.ArrayList(u64) = .initBuffer(&points_buffer);

    for (vp.buffers.available.items) |buffer| {
        timelines.appendBounded(@intFromEnum(buffer.release.handle)) catch unreachable;
        points.appendBounded(@intFromEnum(buffer.release.point)) catch unreachable;
    }

    var index: u32 = undefined;
    const signaled = c_linux.drmSyncobjTimelineWait(
        dri.handle,
        timelines.items.ptr,
        points.items.ptr,
        @intCast(timelines.items.len),
        timeout_ns,
        c_linux.DRM_SYNCOBJ_WAIT_FLAGS_WAIT_AVAILABLE,
        &index,
    );

    if (@abs(signaled) == c_linux.ETIME) {
        return error.Timeout;
    }

    std.debug.assert(signaled == 0);
    const buffer = &vp.buffers.available.items[index];

    buffer.release.point.advance();
    buffer.released = true;

    return buffer;
}

pub fn resize(
    vp: *ViewportGL,
    requested_width: u32,
    requested_height: u32,
) !void {
    try vp.resize_buffers(requested_width, requested_height);

    vp.width = requested_width;
    vp.height = requested_height;

    try client_to_server.message_send_json(
        vp.client.io,
        vp.client.gpa,
        vp.client.connection,
        .{
            .viewport_resize = .{
                .viewport_id = vp.id,
                .width = vp.width,
                .height = vp.height,
            },
        },
    );
}

pub fn buffer_released(vp: *ViewportGL, id: BufferID) void {
    for (vp.buffers.old.items) |*old| {
        if (old.id == id) {
            old.released = true;
        }
    }

    for (vp.buffers.available.items) |*buffer| {
        if (buffer.id == id) {
            buffer.released = true;
        }
    }
}

pub fn buffer_destroyed(vp: *ViewportGL, id: BufferID) void {
    var i = vp.buffers.old.items.len;
    while (i > 0) {
        i -= 1;
        const old = &vp.buffers.old.items[i];
        if (old.id == id) {
            old.deinit();
            _ = vp.buffers.old.orderedRemove(i);
        }
    }
}

pub fn buffer_created(vp: *ViewportGL, id: BufferID) !void {
    vp.buffers.buffer_created(id);
}

fn resize_buffers(vp: *ViewportGL, requested_width: u32, requested_height: u32) !void {
    const new_width, const new_height = new_dimensions(requested_width, requested_height);

    const buffer = vp.buffers.available.getLastOrNull() orelse return error.NoBuffers;
    const current_width = c_linux.gbm_bo_get_width(buffer.bo);
    const current_height = c_linux.gbm_bo_get_height(buffer.bo);
    if (current_width >= new_width and current_height >= new_height) {
        return;
    }

    try vp.buffers.ensure_unused_capacity(vp.client.gpa, 2);
    try vp.buffer_new(new_width, new_height, vp.format);
    try vp.buffer_new(new_width, new_height, vp.format);

    while (vp.buffers.available.pop()) |b| {
        vp.buffers.old.appendAssumeCapacity(b);
        try vp.client.send_buffer_destroy(b.id);
    }
}

pub const Buffer = struct {
    bo: *c_linux.struct_gbm_bo,
    gbm_texture: opengl.GbmBackedTexture,
    gl_context: opengl.ContextLinux,
    fbo: glad.GLuint,

    format: ptypes.BufferFormat,
    id: ptypes.BufferID,
    released: bool,
    acquire: AcquireTimeline,
    release: ReleaseTimeline,

    pub fn init(client: *Client, width: u32, height: u32, format: ptypes.BufferFormat) !Buffer {
        const gbm = client.gbm.?;
        const bo = try gbm.bo_create(width, height);
        const gbm_texture = try opengl.egl_image_from_gbm_bo(client.gl_context.?, bo);
        const fbo = try opengl.fbo_gen(gbm_texture.texture);

        const id = client.next_buffer_id.increment();
        return .{
            .bo = bo,
            .gbm_texture = gbm_texture,
            .gl_context = client.gl_context.?,
            .fbo = fbo,
            .id = id,
            .format = format,
            .released = true,
            .acquire = .init(gbm),
            .release = .init(gbm),
        };
    }

    pub fn deinit(buffer: *Buffer) void {
        glad.glDeleteTextures(1, &buffer.gbm_texture.texture);
        glad.glDeleteFramebuffers(1, &buffer.fbo);
        _ = glad.eglDestroyImageKHR(buffer.gl_context.egl_display, buffer.gbm_texture.image);
        c_linux.gbm_bo_destroy(buffer.bo);
    }
};

pub const AcquireTimeline = struct {
    point: ptypes.AcquireTimelinePoint,
    handle: ptypes.AcquireTimelineHandle,

    pub fn init(gbm: Client.Gbm) AcquireTimeline {
        return .{
            .point = @enumFromInt(0),
            .handle = @enumFromInt(gbm.syncobj_create()),
        };
    }

    pub fn fd(t: AcquireTimeline, gbm: Client.Gbm) ptypes.AcquireTimelineFd {
        return @enumFromInt(
            gbm.syncobj_fd_from_handle(@intFromEnum(t.handle)),
        );
    }
};

pub const ReleaseTimeline = struct {
    point: ptypes.ReleaseTimelinePoint,
    handle: ptypes.ReleaseTimelineHandle,

    pub fn init(gbm: Client.Gbm) ReleaseTimeline {
        return .{
            .point = @enumFromInt(0),
            .handle = @enumFromInt(gbm.syncobj_create()),
        };
    }

    pub fn fd(t: ReleaseTimeline, gbm: Client.Gbm) ptypes.ReleaseTimelineFd {
        return @enumFromInt(
            gbm.syncobj_fd_from_handle(@intFromEnum(t.handle)),
        );
    }
};

fn new_dimensions(width: u32, height: u32) struct { u32, u32 } {
    return .{
        dimension_multiple_of(width, 640),
        dimension_multiple_of(height, 480),
    };
}

fn dimension_multiple_of(requested: u32, multiple_of: u32) u32 {
    var result: u32 = 0;

    while (result < requested) {
        result += multiple_of;
    }

    return result;
}

fn query_syncobj(
    buffer: *ViewportGL.Buffer,
    dri: Io.File,
) void {
    {
        var point: u64 = undefined;
        const result = c_linux.drmSyncobjQuery2(
            dri.handle,
            &buffer.sync_object_acquire,
            &point,
            1,
            0,
        );
        var submitted_point: u64 = undefined;
        const submitted_result = c_linux.drmSyncobjQuery2(
            dri.handle,
            &buffer.sync_object_acquire,
            &submitted_point,
            1,
            c_linux.DRM_SYNCOBJ_QUERY_FLAGS_LAST_SUBMITTED,
        );
        std.debug.print("acquire: point completed({}) submitted({}) success {}\n", .{
            point,
            submitted_point,
            result == 0 and submitted_result == 0,
        });
    }
    {
        var point: u64 = undefined;
        const result = c_linux.drmSyncobjQuery2(
            dri.handle,
            &buffer.sync_object_release,
            &point,
            1,
            0,
        );
        var submitted_point: u64 = undefined;
        const submitted_result = c_linux.drmSyncobjQuery2(
            dri.handle,
            &buffer.sync_object_release,
            &submitted_point,
            1,
            c_linux.DRM_SYNCOBJ_QUERY_FLAGS_LAST_SUBMITTED,
        );
        std.debug.print("release: point completed({}) submitted({}) success {}\n", .{
            point,
            submitted_point,
            result == 0 and submitted_result == 0,
        });
    }
}

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const client_to_server = @import("protocol").client_to_server;
const ptypes = @import("protocol").types;
const ViewportID = ptypes.ViewportID;
const opengl = @import("opengl.zig");
const c_linux = @import("c_linux");
const glad = @import("glad");
const Client = @import("Client.zig");
const BufferID = ptypes.BufferID;
const Buffers = @import("buffers.zig").Buffers;
