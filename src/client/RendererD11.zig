const RendererD11 = @This();

buffers: std.array_hash_map.Auto(BufferID, Buffer),

pub fn init() RendererD11 {
    return .{ .buffers = .empty };
}

pub fn deinit(r: *RendererD11, gpa: std.mem.Allocator) void {
    r.buffers.deinit(gpa);
}

pub fn frame_end(_: *RendererD11, _: *Buffer) void {
    unreachable;
}

pub fn buffer_size(r: *const RendererD11) ptypes.Size {
    return r.buffers.values()[0].size;
}

pub fn get_buffer(r: *RendererD11) !*Buffer {
    for (r.buffers.values()) |*b| {
        if (b.released) return b;
    }

    const buffers_len = 2;
    std.debug.assert(buffers_len == r.buffers.count());

    defer {
        for (r.buffers.values()) |b| {
            _ = win32_threading.ResetEvent(b.release.fence_event);
        }
    }

    var events: [buffers_len]*anyopaque = undefined;

    for (r.buffers.values(), 0..) |b, i| {
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

    const buffer: *Buffer =
        if (result >= WAIT_OBJECT_0 and
        result < WAIT_OBJECT_0 + events.len) blk: {
            const i = result - WAIT_OBJECT_0;
            break :blk &r.buffers.values()[i];
        } else {
            return error.FailedToWaitOnFence;
        };

    buffer.released = true;

    return buffer;
}

pub const Buffer = struct {
    id: BufferID,
    size: ptypes.Size,
    format: ptypes.BufferFormat,

    released: bool,

    acquire: if (constants.os_has_d3d) Acquire else void,
    release: if (constants.os_has_d3d) Release else void,
    texture: if (constants.os_has_d3d) *d11.ID3D11Texture2D else void,
    rtv: if (constants.os_has_d3d) *d11.ID3D11RenderTargetView else void,

    pub fn init(device: D11Device, created: server_to_client.TextureCreatedD3D) !Buffer {
        std.debug.assert(created.version == .d3d11);

        const release_event = win32_threading.CreateEventA(
            null,
            @intFromEnum(std.os.windows.BOOL.TRUE), // manual reset
            @intFromEnum(std.os.windows.BOOL.FALSE),
            null,
        ) orelse return error.FailedToCreateFenceEvent;
        errdefer _ = win32_foundation.CloseHandle(release_event);

        const texture = blk: {
            var texture: *d11.ID3D11Texture2D = undefined;
            const open_result = device.device1.OpenSharedResource1(
                @ptrFromInt(@intFromEnum(created.texture_handle)),
                d11.IID_ID3D11Texture2D,
                @ptrCast(&texture),
            );
            std.debug.assert(open_result == win32_foundation.S_OK);
            break :blk texture;
        };

        const rtv = blk: {
            var rtv: *d11.ID3D11RenderTargetView = undefined;
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

    pub fn deinit(b: *Buffer) void {
        if (!constants.os_has_d3d) return;

        _ = b.acquire.fence.acquire.IUnknown.Release();
        _ = b.release.fence.release.IUnknown.Release();
        _ = b.rtv.IUnknown.Release();
        _ = b.texture.IUnknown.Release();
    }
};

pub const Acquire = struct {
    point: ptypes.AcquireTimelinePoint,
    fence: AcquireFence,
};

pub const Release = struct {
    point: ptypes.ReleaseTimelinePoint,
    fence: ReleaseFence,
    fence_event: *anyopaque,
};

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const client_to_server = @import("protocol").client_to_server;
const server_to_client = @import("protocol").server_to_client;
const ptypes = @import("protocol").types;
const ViewportID = ptypes.ViewportID;
const glad = @import("glad");
const Client = @import("Client.zig");
const BufferID = ptypes.BufferID;
const log = std.log.scoped(.RendererD11);
const CreateStatus = Client.CreateStatus;
const Viewport = @import("Viewport.zig");
const utils = @import("utils");
const d11 = @import("win32").graphics.direct3d11;
const d3d = @import("win32").graphics.direct3d;
const win32_foundation = @import("win32").foundation;
const win32_threading = @import("win32").system.threading;
const win32_programming = @import("win32").system.windows_programming;
const constants = @import("constants");
const AcquireFence = @import("d3d").d11.AcquireFence;
const ReleaseFence = @import("d3d").d11.ReleaseFence;
const D11Device = Client.D11Device;
