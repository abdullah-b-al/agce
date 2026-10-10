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

pub fn get_buffer(r: *RendererD11) ?*Buffer {
    for (r.buffers.values()) |*b| {
        if (b.released) return b;
    }

    return null;
}

pub const Buffer = struct {
    id: BufferID,
    size: ptypes.Size,
    format: ptypes.BufferFormat,

    released: bool,

    texture: if (constants.os_has_d3d) *d11.ID3D11Texture2D else void,
    rtv: if (constants.os_has_d3d) *d11.ID3D11RenderTargetView else void,

    pub fn init(device: *d11.ID3D11Device, device1: *d11.ID3D11Device1, created: server_to_client.TextureCreatedD3D) !Buffer {
        std.debug.assert(created.version == .d3d11);

        var texture: *d11.ID3D11Texture2D = undefined;
        const open_result = device1.OpenSharedResource1(
            @ptrFromInt(@intFromEnum(created.handle)),
            d11.IID_ID3D11Texture2D,
            @ptrCast(&texture),
        );
        std.debug.assert(open_result == win32_foundation.S_OK);

        var rtv: *d11.ID3D11RenderTargetView = undefined;
        const hr = device.CreateRenderTargetView(
            @ptrCast(texture),
            null,
            &rtv,
        );
        std.debug.assert(hr == win32_foundation.S_OK);

        return .{
            .id = created.buffer_id,
            .size = created.size,
            .format = created.format,
            .released = true,
            .texture = texture,
            .rtv = rtv,
        };
    }

    pub fn deinit(b: *Buffer) void {
        if (constants.os_has_d3d) {
            _ = b.rtv.IUnknown.Release();
            _ = b.texture.IUnknown.Release();
        }
    }
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
const constants = @import("constants");
