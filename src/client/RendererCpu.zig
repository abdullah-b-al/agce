const RendererCpu = @This();

buffers_collection: buffers.Collection(Buffer),

pub fn init() RendererCpu {
    return .{ .buffers_collection = .empty };
}

pub fn deinit(r: *RendererCpu, gpa: std.mem.Allocator) void {
    r.buffers_collection.deinit(gpa);
}

pub fn resize(r: *RendererCpu, vp: *Viewport, msg: ViewportResize) !void {
    std.debug.assert(msg.viewport_id == vp.id);
    std.debug.assert(r.buffers_collection.available.count() > 0);
    const new_width, const new_height = utils.new_dimensions(msg.size.width, msg.size.height);

    const buffer = r.buffers_collection.available.values()[0];
    if (buffer.width < new_width or buffer.height < new_height) {
        try buffers.buffers_resize(
            RendererCpu.Buffer,
            2,
            vp,
            vp.client,
            &r.buffers_collection,
            .{ vp.client, new_width, new_height, vp.format },
        );
    }
}

pub fn buffer_size(r: *const RendererCpu) ptypes.Size {
    const buffer = r.buffers_collection.available.values()[0];
    return .{
        .width = buffer.width,
        .height = buffer.height,
    };
}

pub fn get_buffer(r: *RendererCpu) ?*Buffer {
    for (r.buffers_collection.available.values()) |*buffer| {
        if (buffer.released) return buffer;
    }

    return null;
}

pub fn has_buffer(r: *RendererCpu, id: BufferID) bool {
    return r.buffers_collection.has(id);
}

pub fn frame_render(_: *RendererCpu) void {}

pub fn buffer_released(r: *RendererCpu, id: BufferID) void {
    std.debug.assert(r.buffers_collection.available.count() > 0);
    for (r.buffers_collection.available.values()) |*buffer| {
        if (buffer.id == id) {
            buffer.released = true;
        }
    }
}

pub fn buffer_destroyed(_: *RendererCpu, _: BufferID) void {}

fn create_fd(size: i32) !struct { c_int, []align(std.heap.page_size_min) u8 } {
    const fd = try std.posix.memfd_create("agce-buffer", 0);
    if (std.posix.errno(std.posix.system.ftruncate(fd, @intCast(size))) != .SUCCESS) return error.FtruncateFailed;
    const buffer = try std.posix.mmap(
        null,
        @intCast(size),
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .SHARED },
        fd,
        0,
    );

    return .{ fd, buffer };
}

pub const Buffer = struct {
    id: ptypes.BufferID,
    fd: ptypes.CpuBufferFd,
    data: []align(std.heap.page_size_min) u8,
    released: bool,
    width: i32,
    height: i32,
    format: ptypes.BufferFormat,

    pub fn init(client: *Client, width: i32, height: i32, format: ptypes.BufferFormat) !Buffer {
        const s = width * height * format.bytes_per_pixel();
        const fd, const buffer = try create_fd(s);

        return .{
            .id = client.next_buffer_id.increment(),
            .fd = @enumFromInt(fd),
            .data = buffer,
            .released = true,
            .width = width,
            .height = height,
            .format = format,
        };
    }

    pub fn create_on_server(buffer: Buffer, vp: *Viewport, client: *Client) !void {
        try client.send_buffer_create_cpu_with_fd(vp, buffer);
    }

    pub fn deinit(buffer: *Buffer) void {
        std.posix.munmap(buffer.data);
        _ = std.os.linux.close(@intFromEnum(buffer.fd));
    }
};

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const client_to_server = @import("protocol").client_to_server;
const server_to_client = @import("protocol").server_to_client;
const ViewportResize = server_to_client.MessagePayload.ViewportResize;
const ptypes = @import("protocol").types;
const c_linux = @import("c_linux");
const glad = @import("glad");
const ViewportID = ptypes.ViewportID;
const BufferID = ptypes.BufferID;
const Client = @import("Client.zig");
const buffers = @import("buffers.zig");
const BufferStatus = @import("buffers.zig").BufferStatus;
const CreateStatus = Client.CreateStatus;
const log = std.log.scoped(.RendererCpu);
const Viewport = @import("Viewport.zig");
const utils = @import("utils");
