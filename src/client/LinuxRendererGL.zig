const LinuxRendererGL = @This();

gbm: Client.Gbm,
gl: opengl.ContextLinux,
buffers: std.array_hash_map.Auto(BufferID, Buffer),

pub fn init(gbm: Client.Gbm, gl: opengl.ContextLinux) LinuxRendererGL {
    return .{
        .gbm = gbm,
        .gl = gl,
        .buffers = .empty,
    };
}

pub fn deinit(r: *LinuxRendererGL, gpa: std.mem.Allocator) void {
    r.buffers.deinit(gpa);
}

pub fn frame_end(r: *LinuxRendererGL, buffer: *Buffer) void {
    const sync = glad.eglCreateSync(r.gl.egl_display, glad.EGL_SYNC_NATIVE_FENCE_ANDROID, null);
    defer _ = glad.eglDestroySync(r.gl.egl_display, sync);

    glad.glFlush();

    std.debug.assert(sync != glad.EGL_NO_SYNC);

    const egl_sync_fd = glad.eglDupNativeFenceFDANDROID(r.gl.egl_display, sync);
    std.debug.assert(egl_sync_fd > 0);

    const tmp_syncobj = blk: {
        var syncobj: u32 = undefined;
        const create_result = c_linux.drmSyncobjCreate(r.gbm.dri.handle, 0, &syncobj);
        std.debug.assert(create_result == 0);
        break :blk syncobj;
    };

    defer _ = c_linux.drmSyncobjDestroy(r.gbm.dri.handle, tmp_syncobj);

    const import_result =
        c_linux.drmSyncobjImportSyncFile(r.gbm.dri.handle, tmp_syncobj, egl_sync_fd);
    std.debug.assert(import_result == 0);

    const transfer_result = c_linux.drmSyncobjTransfer(
        r.gbm.dri.handle,
        @intFromEnum(buffer.acquire.handle),
        @intFromEnum(buffer.acquire.point),
        tmp_syncobj,
        0,
        0,
    );
    std.debug.assert(transfer_result == 0);
}

pub fn buffer_size(r: *const LinuxRendererGL) ptypes.Size {
    const buffer = r.buffers.values()[0];
    return .{
        .width = buffer.width,
        .height = buffer.height,
    };
}

pub fn get_buffer(r: *LinuxRendererGL, timeout_ns: i64) error{Timeout}!*Buffer {
    const dri = r.gbm.dri;

    std.debug.assert(r.buffers.count() > 0);

    for (r.buffers.values()) |*buffer| {
        if (buffer.released) return buffer;
    }

    const buffer_len = 2;
    std.debug.assert(buffer_len >= r.buffers.count());

    var timelines_buffer: [buffer_len]u32 = undefined;
    var points_buffer: [buffer_len]u64 = undefined;
    var timelines: std.ArrayList(u32) = .initBuffer(&timelines_buffer);
    var points: std.ArrayList(u64) = .initBuffer(&points_buffer);

    for (r.buffers.values()) |buffer| {
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
    const buffer = &r.buffers.values()[index];

    buffer.released = true;

    return buffer;
}

pub const Buffer = struct {
    bo: *c_linux.struct_gbm_bo,
    gbm_texture: opengl.GbmBackedTexture,
    gl_context: opengl.ContextLinux,
    fbo: glad.GLuint,

    width: i32,
    height: i32,

    format: ptypes.BufferFormat,
    id: ptypes.BufferID,
    released: bool,
    acquire: AcquireTimeline,
    release: ReleaseTimeline,

    pub fn init(gbm: Client.Gbm, gl_context: opengl.ContextLinux, created: BufferCreatedGbmBo) !Buffer {
        var import_data: c_linux.gbm_import_fd_data = .{
            .fd = @intFromEnum(created.fds.buffer),
            .width = @intCast(created.size.width),
            .height = @intCast(created.size.height),
            .stride = created.stride,
            .format = switch (created.format) {
                .argb8888 => c_linux.DRM_FORMAT_ARGB8888,
            },
        };

        // FIXME: Handle null
        const bo = c_linux.gbm_bo_import(
            gbm.device,
            c_linux.GBM_BO_IMPORT_FD,
            &import_data,
            c_linux.GBM_BO_USE_RENDERING,
        ).?;
        const gbm_texture = try opengl.egl_image_from_gbm_bo(gl_context, bo);
        const fbo = try opengl.fbo_gen(gbm_texture.texture);

        // TODO: Do not close fds here
        std.debug.assert(std.os.linux.close(@intFromEnum(created.fds.buffer)) == 0);

        return .{
            .bo = bo,
            .gbm_texture = gbm_texture,
            .gl_context = gl_context,
            .fbo = fbo,
            .id = created.buffer_id,
            .width = @intCast(c_linux.gbm_bo_get_width(bo)),
            .height = @intCast(c_linux.gbm_bo_get_height(bo)),
            .format = created.format,
            .released = true,
            .acquire = .from_fd(gbm, created.fds.acquire_timeline),
            .release = .from_fd(gbm, created.fds.release_timeline),
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
    handle: ptypes.DrmSyncobjAcquireTimelineHandle,

    pub fn from_fd(gbm: Client.Gbm, fd: ptypes.DrmSyncobjAcquireTimelineFd) AcquireTimeline {
        var handle: u32 = undefined;
        const result = c_linux.drmSyncobjFDToHandle(gbm.dri.handle, @intFromEnum(fd), &handle);
        std.debug.assert(result == 0);

        std.debug.assert(std.os.linux.close(@intFromEnum(fd)) == 0);

        return .{
            .point = @enumFromInt(0),
            .handle = @enumFromInt(handle),
        };
    }
};

pub const ReleaseTimeline = struct {
    point: ptypes.ReleaseTimelinePoint,
    handle: ptypes.DrmSyncobjReleaseTimelineHandle,

    pub fn from_fd(gbm: Client.Gbm, fd: ptypes.DrmSyncobjReleaseTimelineFd) ReleaseTimeline {
        var handle: u32 = undefined;
        const result = c_linux.drmSyncobjFDToHandle(gbm.dri.handle, @intFromEnum(fd), &handle);
        std.debug.assert(result == 0);

        std.debug.assert(std.os.linux.close(@intFromEnum(fd)) == 0);

        return .{
            .point = @enumFromInt(0),
            .handle = @enumFromInt(handle),
        };
    }
};

fn query_syncobj(
    buffer: *LinuxRendererGL.Buffer,
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
        log.debug("acquire: point completed({}) submitted({}) success {}", .{
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
        log.debug("release: point completed({}) submitted({}) success {}", .{
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
const server_to_client = @import("protocol").server_to_client;
const BufferCreatedGbmBo = server_to_client.BufferCreatedGbmBo;
const ptypes = @import("protocol").types;
const ViewportID = ptypes.ViewportID;
const opengl = @import("opengl.zig");
const c_linux = @import("c_linux");
const glad = @import("glad");
const Client = @import("Client.zig");
const BufferID = ptypes.BufferID;
const log = std.log.scoped(.RendererGL);
const CreateStatus = Client.CreateStatus;
const Viewport = @import("Viewport.zig");
const utils = @import("utils");
