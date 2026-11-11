const Buffers = @This();

gl_linux: std.array_hash_map.Auto(BufferID, GlLinux),
cpu: std.array_hash_map.Auto(BufferID, Cpu),
d11: std.array_hash_map.Auto(BufferID, D11),

allowed_buffers: std.EnumSet(Viewport.Renderer),

pub fn init_for_viewport(renderer: Viewport.Renderer) Buffers {
    return .{
        .allowed_buffers = .initOne(renderer),
        .gl_linux = .empty,
        .cpu = .empty,
        .d11 = .empty,
    };
}

pub fn deinit(buffers: *Buffers, gpa: std.mem.Allocator) void {
    inline for (.{
        &buffers.cpu,
        &buffers.gl_linux,
        &buffers.d11,
    }) |container| {
        for (container.values()) |*buffer| {
            buffer.deinit();
        }

        container.deinit(gpa);
    }
}

pub fn count(buffers: *const Buffers, tag: Viewport.Renderer) usize {
    std.debug.assert(buffers.allowed_buffers.contains(tag));
    std.debug.assert(buffers.allowed_buffers.count() == 1); // TODO: Allow more than one

    return switch (tag) {
        .cpu => buffers.cpu.count(),
        .gl => buffers.gl_linux.count(),
        .d11 => buffers.d11.count(),
    };
}

pub fn map(buffers: *Buffers, comptime tag: Viewport.Renderer) *tag.MapType() {
    std.debug.assert(buffers.allowed_buffers.contains(tag));
    return switch (tag) {
        .cpu => &buffers.cpu,
        .gl => &buffers.gl_linux,
        .d11 => &buffers.d11,
    };
}

pub fn get_cpu(buffers: *Buffers) ?*Cpu {
    std.debug.assert(buffers.allowed_buffers.contains(.cpu));

    for (buffers.cpu.values()) |*buffer| {
        if (buffer.released) return buffer;
    }

    return null;
}

pub fn get_d11(buffers: *Buffers) !*D11 {
    std.debug.assert(buffers.allowed_buffers.contains(.d11));

    for (buffers.d11.values()) |*b| {
        if (b.released) return b;
    }

    const buffers_len = 2;
    std.debug.assert(buffers_len == buffers.d11.count());

    defer {
        for (buffers.d11.values()) |b| {
            _ = win32_threading.ResetEvent(b.release.fence_event);
        }
    }

    var events: [buffers_len]*anyopaque = undefined;

    for (buffers.d11.values(), 0..) |b, i| {
        const hr = b.release.fence.release.SetEventOnCompletion(
            @intFromEnum(b.release.point),
            b.release.fence_event,
        );

        if (hr != win32_foundation.S_OK) {
            return error.FailedToWaitOnFence;
        }

        events[i] = b.release.fence_event;
    }

    const wait_result = win32_threading.WaitForMultipleObjects(
        events.len,
        &events,
        @intFromEnum(std.os.windows.BOOL.FALSE), // wait for at least one
        win32_programming.INFINITE,
    );
    const result = @intFromEnum(wait_result);
    const WAIT_OBJECT_0 = @intFromEnum(win32_foundation.WAIT_OBJECT_0);

    const buffer: *D11 =
        if (result >= WAIT_OBJECT_0 and
        result < WAIT_OBJECT_0 + events.len) blk: {
            const i = result - WAIT_OBJECT_0;
            break :blk &buffers.d11.values()[i];
        } else {
            return error.FailedToWaitOnFence;
        };

    buffer.released = true;

    return buffer;
}

pub fn get_gl_linux(buffers: *Buffers, gbm: Client.Gbm, timeout_ns: i64) error{Timeout}!*GlLinux {
    std.debug.assert(buffers.allowed_buffers.contains(.gl));

    const dri = gbm.dri;

    std.debug.assert(buffers.gl_linux.count() > 0);

    for (buffers.gl_linux.values()) |*buffer| {
        if (buffer.released) return buffer;
    }

    const buffer_len = 2;
    std.debug.assert(buffer_len >= buffers.gl_linux.values().len);

    var timelines_buffer: [buffer_len]u32 = undefined;
    var points_buffer: [buffer_len]u64 = undefined;
    var timelines: std.ArrayList(u32) = .initBuffer(&timelines_buffer);
    var points: std.ArrayList(u64) = .initBuffer(&points_buffer);

    for (buffers.gl_linux.values()) |buffer| {
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
    const buffer = &buffers.gl_linux.values()[index];

    buffer.released = true;

    return buffer;
}

pub const GlLinux = if (!constants.os_has_gbm) UnreachableBuffer else struct {
    bo: *c_linux.struct_gbm_bo,
    gbm_texture: opengl.GbmBackedTexture,
    gl_context: opengl.ContextLinux,
    fbo: glad.GLuint,

    size: ptypes.Size,

    format: ptypes.BufferFormat,
    id: ptypes.BufferID,
    released: bool,
    acquire: AcquireTimeline,
    release: ReleaseTimeline,

    pub fn init(gbm: Client.Gbm, gl_context: opengl.ContextLinux, created: BufferCreatedGbmBo) !GlLinux {
        defer {
            created.fds.acquire_timeline.close();
            created.fds.release_timeline.close();
            created.fds.buffer.close();
        }

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

        return .{
            .bo = bo,
            .gbm_texture = gbm_texture,
            .gl_context = gl_context,
            .fbo = fbo,
            .id = created.buffer_id,
            .size = .{
                .width = @intCast(c_linux.gbm_bo_get_width(bo)),
                .height = @intCast(c_linux.gbm_bo_get_height(bo)),
            },
            .format = created.format,
            .released = true,
            .acquire = .from_fd(gbm, created.fds.acquire_timeline),
            .release = .from_fd(gbm, created.fds.release_timeline),
        };
    }

    pub fn deinit(buffer: *GlLinux) void {
        glad.glDeleteTextures(1, &buffer.gbm_texture.texture);
        glad.glDeleteFramebuffers(1, &buffer.fbo);
        _ = glad.eglDestroyImageKHR(buffer.gl_context.egl_display, buffer.gbm_texture.image);
        c_linux.gbm_bo_destroy(buffer.bo);
    }

    pub fn frame_end(
        buffer: *GlLinux,
        gbm: Client.Gbm,
        egl_display: *anyopaque,
    ) void {
        const sync = glad.eglCreateSync(egl_display, glad.EGL_SYNC_NATIVE_FENCE_ANDROID, null);
        defer _ = glad.eglDestroySync(egl_display, sync);

        glad.glFlush();

        std.debug.assert(sync != glad.EGL_NO_SYNC);

        const egl_sync_fd = glad.eglDupNativeFenceFDANDROID(egl_display, sync);
        std.debug.assert(egl_sync_fd > 0);

        const tmp_syncobj = blk: {
            var syncobj: u32 = undefined;
            const create_result = c_linux.drmSyncobjCreate(gbm.dri.handle, 0, &syncobj);
            std.debug.assert(create_result == 0);
            break :blk syncobj;
        };

        defer _ = c_linux.drmSyncobjDestroy(gbm.dri.handle, tmp_syncobj);

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
    }

    pub const AcquireTimeline = struct {
        point: ptypes.AcquireTimelinePoint,
        handle: ptypes.DrmSyncobjAcquireTimelineHandle,

        pub fn from_fd(gbm: Client.Gbm, fd: ptypes.DrmSyncobjAcquireTimelineFd) AcquireTimeline {
            var handle: u32 = undefined;
            const result = c_linux.drmSyncobjFDToHandle(gbm.dri.handle, @intFromEnum(fd), &handle);
            std.debug.assert(result == 0);

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

            return .{
                .point = @enumFromInt(0),
                .handle = @enumFromInt(handle),
            };
        }
    };

    fn query_syncobj(
        buffer: *GlLinux,
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
};

pub const D11 = if (!constants.os_has_d3d) UnreachableBuffer else struct {
    id: BufferID,
    size: ptypes.Size,
    format: ptypes.BufferFormat,

    released: bool,

    acquire: Acquire,
    release: Release,
    texture: *d3d11.ID3D11Texture2D,
    rtv: *d3d11.ID3D11RenderTargetView,

    pub fn init(device: D11Device, created: server_to_client.TextureCreatedD3D) !D11 {
        std.debug.assert(created.version == .d3d11);
        defer {
            created.acquire_fence_handle.close();
            created.release_fence_handle.close();
            created.texture_handle.close();
        }

        const release_event = win32_threading.CreateEventA(
            null,
            @intFromEnum(std.os.windows.BOOL.TRUE), // manual reset
            @intFromEnum(std.os.windows.BOOL.FALSE),
            null,
        ) orelse return error.FailedToCreateFenceEvent;
        errdefer _ = win32_foundation.CloseHandle(release_event);

        const texture = blk: {
            var texture: *d3d11.ID3D11Texture2D = undefined;
            const open_result = device.device1.OpenSharedResource1(
                @ptrFromInt(@intFromEnum(created.texture_handle)),
                d3d11.IID_ID3D11Texture2D,
                @ptrCast(&texture),
            );
            std.debug.assert(open_result == win32_foundation.S_OK);
            break :blk texture;
        };

        const rtv = blk: {
            var rtv: *d3d11.ID3D11RenderTargetView = undefined;
            const hr = device.device.CreateRenderTargetView(
                @ptrCast(texture),
                null,
                &rtv,
            );
            std.debug.assert(hr == win32_foundation.S_OK);
            break :blk rtv;
        };

        const acquire_fence: AcquireFence = try .open_shared_handle(
            device.device5,
            created.acquire_fence_handle,
        );
        errdefer _ = acquire_fence.acquire.IUnknown.Release();

        const release_fence: ReleaseFence = try .open_shared_handle(
            device.device5,
            created.release_fence_handle,
        );

        return .{
            .id = created.buffer_id,
            .size = created.size,
            .format = created.format,
            .released = true,
            .texture = texture,
            .rtv = rtv,

            .acquire = .{
                .point = @enumFromInt(0),
                .fence = acquire_fence,
            },

            .release = .{
                .point = @enumFromInt(0),
                .fence = release_fence,
                .fence_event = release_event,
            },
        };
    }

    pub fn deinit(b: *D11) void {
        if (!constants.os_has_d3d) return;

        _ = b.acquire.fence.acquire.IUnknown.Release();
        _ = b.release.fence.release.IUnknown.Release();
        _ = b.rtv.IUnknown.Release();
        _ = b.texture.IUnknown.Release();
    }

    pub const Acquire = struct {
        point: ptypes.AcquireTimelinePoint,
        fence: AcquireFence,
    };

    pub const Release = struct {
        point: ptypes.ReleaseTimelinePoint,
        fence: ReleaseFence,
        fence_event: *anyopaque,
    };

    const AcquireFence = @import("d3d").d11.AcquireFence;
    const ReleaseFence = @import("d3d").d11.ReleaseFence;
};

pub const Cpu = switch (os) {
    .linux => CpuLinux,
    .windows => CpuWindows,
    else => unreachable,
};

const CpuLinux = struct {
    id: ptypes.BufferID,
    data: []align(std.heap.page_size_min) u8,
    released: bool,
    size: ptypes.Size,
    format: ptypes.BufferFormat,

    pub fn init(created: BufferCreatedCpu) !CpuLinux {
        defer created.handle.close();

        const s = created.size.width * created.size.height * created.format.bytes_per_pixel();

        const buffer = try std.posix.mmap(
            null,
            @intCast(s),
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED },
            @intFromEnum(created.handle),
            0,
        );

        return .{
            .id = created.buffer_id,
            .data = buffer,
            .released = true,
            .size = created.size,
            .format = created.format,
        };
    }

    pub fn deinit(buffer: *CpuLinux) void {
        std.posix.munmap(buffer.data);
    }
};

const CpuWindows = struct {
    id: ptypes.BufferID,
    data: []u8,
    released: bool,
    size: ptypes.Size,
    format: ptypes.BufferFormat,

    pub fn init(created: BufferCreatedCpu) !CpuWindows {
        defer created.handle.close();

        const size_bytes = created.size.width * created.size.height * created.format.bytes_per_pixel();

        const buffer = win32.system.memory.MapViewOfFile(
            @ptrFromInt(@intFromEnum(created.handle)),
            win32.system.memory.FILE_MAP_ALL_ACCESS,
            0,
            0,
            @intCast(size_bytes),
        ) orelse return error.FailedToMapViewOfFile;

        const ptr: [*]u8 = @ptrCast(buffer);

        return .{
            .id = created.buffer_id,
            .data = ptr[0..@intCast(size_bytes)],
            .released = true,
            .size = created.size,
            .format = created.format,
        };
    }

    pub fn deinit(buffer: *CpuWindows) void {
        _ = win32.system.memory.UnmapViewOfFile(buffer.data.ptr);
    }
};

/// Used to fulfill the Buffer interface.
/// Should only be used when a buffer type is not supported by the OS
const UnreachableBuffer = struct {
    id: ptypes.BufferID,
    size: ptypes.Size,

    pub fn deinit(_: *UnreachableBuffer) void {
        unreachable;
    }
};

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
const log = std.log.scoped(.agce_buffers);
const CreateStatus = Client.CreateStatus;
const Viewport = @import("Viewport.zig");
const utils = @import("utils");
const BufferCreatedCpu = server_to_client.BufferCreatedCpu;
const win32 = @import("win32");
const os = @import("builtin").os.tag;
const constants = @import("constants");
const D11Device = Client.D11Device;
const win32_foundation = @import("win32").foundation;
const win32_threading = @import("win32").system.threading;
const win32_programming = @import("win32").system.windows_programming;
const d3d11 = @import("win32").graphics.direct3d11;
const d3d = @import("win32").graphics.direct3d;
