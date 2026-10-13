pub const AcquireFence = struct {
    acquire: *d11.ID3D11Fence,

    pub fn create_shared_handle(f: AcquireFence) !ptypes.D3DAcquireFenceSharedHandle {
        const handle = try create_shared_handle_from_fence(f.acquire);
        return .from_HANDLE(handle);
    }

    pub fn open_shared_handle(
        device5: *d11.ID3D11Device5,
        acquire_handle: ptypes.D3DAcquireFenceSharedHandle,
    ) !AcquireFence {
        const fence = try open_shared_handle_from_fence(device5, acquire_handle.to_HANDLE());
        return .{ .acquire = fence };
    }
};

pub const ReleaseFence = struct {
    release: *d11.ID3D11Fence,

    pub fn create_shared_handle(f: ReleaseFence) !ptypes.D3DReleaseFenceSharedHandle {
        const handle = try create_shared_handle_from_fence(f.release);
        return .from_HANDLE(handle);
    }

    pub fn open_shared_handle(
        device5: *d11.ID3D11Device5,
        release_handle: ptypes.D3DReleaseFenceSharedHandle,
    ) !ReleaseFence {
        const fence = try open_shared_handle_from_fence(device5, release_handle.to_HANDLE());
        return .{ .release = fence };
    }
};

fn create_shared_handle_from_fence(fence: *d11.ID3D11Fence) !win32_foundation.HANDLE {
    var handle: ?win32_foundation.HANDLE = undefined;
    const hr = fence.CreateSharedHandle(
        null,
        win32_system.system_services.GENERIC_ALL,
        null,
        &handle,
    );
    if (hr != win32_foundation.S_OK) {
        return error.FailedToCreateSharedHandleForFence;
    }

    std.debug.assert(handle != null);

    return handle.?;
}

fn open_shared_handle_from_fence(
    device5: *d11.ID3D11Device5,
    handle: win32_foundation.HANDLE,
) !*d11.ID3D11Fence {
    var fence: *d11.ID3D11Fence = undefined;
    const hr = device5.OpenSharedFence(
        handle,
        d11.IID_ID3D11Fence,
        @ptrCast(&fence),
    );

    if (hr != win32_foundation.S_OK) {
        return error.FailedToOpenSharedFence;
    }

    return fence;
}

const std = @import("std");
const win32_system = @import("win32").system;
const win32_foundation = @import("win32").foundation;
const d11 = @import("win32").graphics.direct3d11;
const ptypes = @import("protocol").types;
