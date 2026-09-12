const LinuxRendererCpu = @This();

buffers: std.array_hash_map.Auto(BufferID, Buffer),

pub fn init() LinuxRendererCpu {
    return .{ .buffers = .empty };
}

pub fn deinit(r: *LinuxRendererCpu, gpa: std.mem.Allocator) void {
    r.buffers.deinit(gpa);
}

pub fn buffer_size(r: *const LinuxRendererCpu) ptypes.Size {
    const buffer = r.buffers.values()[0];
    return buffer.size;
}

pub fn get_buffer(r: *LinuxRendererCpu) ?*Buffer {
    for (r.buffers.values()) |*buffer| {
        if (buffer.released) return buffer;
    }

    return null;
}

pub fn frame_render(_: *LinuxRendererCpu) void {}

pub fn buffer_released(r: *LinuxRendererCpu, id: BufferID) void {
    std.debug.assert(r.buffers.count() > 0);
    for (r.buffers.values()) |*buffer| {
        if (buffer.id == id) {
            buffer.released = true;
        }
    }
}

pub fn buffer_destroyed(_: *LinuxRendererCpu, _: BufferID) void {}

pub const Buffer = struct {
    id: ptypes.BufferID,
    data: []align(std.heap.page_size_min) u8,
    released: bool,
    size: ptypes.Size,
    format: ptypes.BufferFormat,

    pub fn init(created: BufferCreatedCpu) !Buffer {
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

    pub fn deinit(buffer: *Buffer) void {
        std.posix.munmap(buffer.data);
    }
};

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const client_to_server = @import("protocol").client_to_server;
const server_to_client = @import("protocol").server_to_client;
const ViewportResize = server_to_client.ViewportResize;
const BufferCreatedCpu = server_to_client.BufferCreatedCpu;
const ptypes = @import("protocol").types;
const c_linux = @import("c_linux");
const glad = @import("glad");
const ViewportID = ptypes.ViewportID;
const BufferID = ptypes.BufferID;
const Client = @import("Client.zig");
const BufferStatus = @import("buffers.zig").BufferStatus;
const CreateStatus = Client.CreateStatus;
const log = std.log.scoped(.RendererCpu);
const Viewport = @import("Viewport.zig");
const utils = @import("utils");
