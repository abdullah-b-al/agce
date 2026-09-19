const Win32RendererCpu = @This();

buffers: std.array_hash_map.Auto(BufferID, Buffer),

pub fn init() Win32RendererCpu {
    return .{ .buffers = .empty };
}

pub fn deinit(r: *Win32RendererCpu, gpa: std.mem.Allocator) void {
    r.buffers.deinit(gpa);
}

pub fn buffer_size(r: *const Win32RendererCpu) ptypes.Size {
    const buffer = r.buffers.values()[0];
    return buffer.size;
}

pub fn get_buffer(r: *Win32RendererCpu) ?*Buffer {
    for (r.buffers.values()) |*buffer| {
        if (buffer.released) return buffer;
    }

    return null;
}

pub fn frame_render(_: *Win32RendererCpu) void {}

pub fn buffer_released(r: *Win32RendererCpu, id: BufferID) void {
    std.debug.assert(r.buffers.count() > 0);
    for (r.buffers.values()) |*buffer| {
        if (buffer.id == id) {
            buffer.released = true;
        }
    }
}

pub fn buffer_destroyed(_: *Win32RendererCpu, _: BufferID) void {}

pub const Buffer = struct {
    id: ptypes.BufferID,
    data: []u8,
    released: bool,
    size: ptypes.Size,
    format: ptypes.BufferFormat,

    pub fn init(created: BufferCreatedCpu) !Buffer {
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

    pub fn deinit(buffer: *Buffer) void {
        _ = win32.system.memory.UnmapViewOfFile(buffer.data.ptr);
    }
};

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const client_to_server = @import("protocol").client_to_server;
const server_to_client = @import("protocol").server_to_client;
const ViewportResize = server_to_client.ViewportResize;
const ptypes = @import("protocol").types;
const c_linux = @import("c_linux");
const glad = @import("glad");
const ViewportID = ptypes.ViewportID;
const BufferID = ptypes.BufferID;
const Client = @import("Client.zig");
const log = std.log.scoped(.RendererCpu);
const Viewport = @import("Viewport.zig");
const utils = @import("utils");
const win32 = @import("win32");
const BufferCreatedCpu = server_to_client.BufferCreatedCpu;
