const ViewportGL = @This();

client: *Client,

id: ViewportID,
frame_number: usize,

width: u32,
height: u32,
format: ptypes.BufferFormat,
modifier: u64,

old_buffers: std.ArrayList(Buffer),
front_buffer: Buffer,
back_buffer: Buffer,

pub fn init(client: *Client, width: u32, height: u32) !ViewportGL {
    const format: ptypes.BufferFormat = .argb8888;
    const front_buffer = try Buffer.init(client, width, height, format);
    const back_buffer = try Buffer.init(client, width, height, format);
    const bytes = c_linux.gbm_bo_get_bpp(front_buffer.bo) / 8;
    std.debug.assert(bytes == 4);

    const id = client.next_viewport_id.increment_for_client();
    return .{
        .client = client,
        .id = id,
        .frame_number = 0,
        .width = width,
        .height = height,
        .modifier = c_linux.gbm_bo_get_modifier(front_buffer.bo),
        .format = format,

        .old_buffers = .empty,
        .front_buffer = front_buffer,
        .back_buffer = back_buffer,
    };
}

pub fn deinit(vp: *ViewportGL) void {
    const gl = vp.client.gl_context.?;
    vp.front_buffer.deinit(gl);
    vp.back_buffer.deinit(gl);

    for (vp.old_buffers.items) |*old| {
        // TODO: Add a check that the buffer must be released. Failure means a leaked buffer.
        old.deinit(gl);
    }
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

    buffer.released = false;
    buffer.acquire.point.advance();
}

pub fn get_buffer(vp: *ViewportGL) ?*Buffer {
    const dri = vp.client.gbm.?.dri;

    if (vp.back_buffer.released) {
        return &vp.back_buffer;
    } else if (vp.front_buffer.released) {
        return &vp.front_buffer;
    }

    var timelines: [2]u32 = .{
        @intFromEnum(vp.back_buffer.release.handle),
        @intFromEnum(vp.front_buffer.release.handle),
    };
    var points: [timelines.len]u64 = .{
        @intFromEnum(vp.back_buffer.release.point),
        @intFromEnum(vp.front_buffer.release.point),
    };

    const timeout: i64 = 0;
    var index: u32 = undefined;
    const signaled = c_linux.drmSyncobjTimelineWait(
        dri.handle,
        &timelines,
        &points,
        timelines.len,
        timeout,
        c_linux.DRM_SYNCOBJ_WAIT_FLAGS_WAIT_AVAILABLE,
        &index,
    );

    if (index == 0) {
        vp.back_buffer.release.point.advance();
        return &vp.back_buffer;
    }

    if (index == 1) {
        vp.front_buffer.release.point.advance();
        return &vp.front_buffer;
    }

    if (@abs(signaled) == c_linux.ETIME or signaled == 0) {
        return null;
    }

    unreachable;
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
    for (vp.old_buffers.items) |*old| {
        if (old.id == id) {
            old.released = true;
        }
    }

    inline for (&.{ &vp.back_buffer, &vp.front_buffer }) |buffer| {
        if (buffer.id == id) {
            buffer.released = true;
        }
    }
}

pub fn buffer_destroyed(vp: *ViewportGL, id: BufferID) void {
    var i = vp.old_buffers.items.len;
    while (i > 0) {
        i -= 1;
        const old = &vp.old_buffers.items[i];
        if (old.id == id) {
            old.deinit(vp.client.gl_context.?);
            _ = vp.old_buffers.orderedRemove(i);
        }
    }
}

fn resize_buffers(vp: *ViewportGL, requested_width: u32, requested_height: u32) !void {
    const new_width, const new_height = new_dimensions(requested_width, requested_height);

    const current_width = c_linux.gbm_bo_get_width(vp.front_buffer.bo);
    const current_height = c_linux.gbm_bo_get_height(vp.front_buffer.bo);
    if (current_width >= new_width and current_height >= new_height) {
        return;
    }

    const front_buffer = try Buffer.init(vp.client, new_width, new_height, vp.format);
    const back_buffer = try Buffer.init(vp.client, new_width, new_height, vp.format);

    try vp.old_buffers.append(vp.client.gpa, vp.front_buffer);
    try vp.old_buffers.append(vp.client.gpa, vp.back_buffer);

    try vp.client.send_buffer_destroy(vp.front_buffer.id);
    try vp.client.send_buffer_destroy(vp.back_buffer.id);

    vp.front_buffer = front_buffer;
    vp.back_buffer = back_buffer;

    try vp.client.send_buffer_create_gpu_with_fds(vp.back_buffer);
    try vp.client.send_buffer_create_gpu_with_fds(vp.front_buffer);
}

pub const Buffer = struct {
    bo: *c_linux.struct_gbm_bo,
    gbm_texture: opengl.GbmBackedTexture,
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
            .fbo = fbo,
            .id = id,
            .format = format,
            .released = true,
            .acquire = .init(gbm),
            .release = .init(gbm),
        };
    }

    pub fn deinit(buffer: *Buffer, gl: opengl.ContextLinux) void {
        glad.glDeleteTextures(1, &buffer.gbm_texture.texture);
        glad.glDeleteFramebuffers(1, &buffer.fbo);
        _ = glad.eglDestroyImageKHR(gl.egl_display, buffer.gbm_texture.image);
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
const constants = @import("../constants.zig");
const utils = @import("../utils.zig");
const client_to_server = @import("../protocol/client_to_server.zig");
const server_to_client = @import("../protocol/server_to_client.zig");
const common = @import("../protocol/common.zig");
const ptypes = @import("../protocol/types.zig");
const ViewportID = ptypes.ViewportID;
const opengl = @import("../opengl.zig");
const c_linux = @import("c_linux");
const glad = @import("glad");
const Client = @import("Client.zig");
const BufferID = ptypes.BufferID;
