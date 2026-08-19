const ViewportCpu = @This();

base: ViewportBase,

buffers_collection: buffers.Collection(Buffer),

pub fn init(
    id: ViewportID,
    client: *Client,
    width: u32,
    height: u32,
    vsync: bool,
) !ViewportCpu {
    const format: ptypes.BufferFormat = .argb8888;
    return .{
        .base = .init(client, id, width, height, format, vsync),
        .buffers_collection = .empty,
    };
}

pub fn deinit(vp: *ViewportCpu) void {
    vp.base.deinit();
    vp.buffers_collection.deinit(vp.base.client.gpa);
}

pub fn close(vp: *ViewportCpu) void {
    vp.base.open = false;
}

pub fn resize(vp: *ViewportCpu, msg: ptypes.ViewportResize) !void {
    std.debug.assert(msg.viewport_id == vp.base.id);
    std.debug.assert(vp.buffers_collection.available.count() > 0);
    const new_width, const new_height = buffers.new_dimensions(msg.width, msg.height);

    const buffer = vp.buffers_collection.available.values()[0];
    if (buffer.width < new_width or buffer.height < new_height) {
        try buffers.buffers_resize(
            ViewportCpu.Buffer,
            2,
            &vp.base,
            vp.base.client,
            &vp.buffers_collection,
            .{ vp.base.client, new_width, new_height, vp.base.format },
        );
    }
}

pub fn buffer_size(vp: *ViewportCpu) [2]u32 {
    const buffer = vp.buffers_collection.available.values()[0];
    return .{ buffer.width, buffer.height };
}

pub fn get_buffer(vp: *ViewportCpu) ?*Buffer {
    for (vp.buffers_collection.available.values()) |*buffer| {
        if (buffer.released) return buffer;
    }

    return null;
}

pub fn has_buffer(vp: *ViewportCpu, id: BufferID) bool {
    return vp.buffers_collection.has(id);
}

pub fn buffer_present(vp: *ViewportCpu, buffer: *Buffer) !void {
    std.debug.assert(buffer.released);
    buffer.released = false;

    try client_to_server.message_send_json(
        vp.base.client.io,
        vp.base.client.gpa,
        vp.base.client.connection,
        .{
            .buffer_present = .{
                .viewport_id = vp.base.id,
                .buffer_id = buffer.id,
            },
        },
    );
}

pub fn frame_render(_: *ViewportCpu) void {}

pub fn buffer_released(vp: *ViewportCpu, id: BufferID) void {
    std.debug.assert(vp.buffers_collection.available.count() > 0);
    for (vp.buffers_collection.available.values()) |*buffer| {
        if (buffer.id == id) {
            buffer.released = true;
        }
    }
}

pub fn buffer_destroyed(_: *ViewportCpu, _: BufferID) void {}

fn create_fd(size: usize) !struct { c_int, []align(std.heap.page_size_min) u8 } {
    const fd = try std.posix.memfd_create("agce-buffer", 0);
    if (std.posix.errno(std.posix.system.ftruncate(fd, @intCast(size))) != .SUCCESS) return error.FtruncateFailed;
    const buffer = try std.posix.mmap(
        null,
        size,
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
    width: u32,
    height: u32,
    format: ptypes.BufferFormat,

    pub fn init(client: *Client, width: u32, height: u32, format: ptypes.BufferFormat) !Buffer {
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

    pub fn create_on_server(buffer: Buffer, base: *ViewportBase, client: *Client) !void {
        try client.send_buffer_create_cpu_with_fd(base, buffer);
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
const ptypes = @import("protocol").types;
const c_linux = @import("c_linux");
const glad = @import("glad");
const ViewportID = ptypes.ViewportID;
const BufferID = ptypes.BufferID;
const Client = @import("Client.zig");
const buffers = @import("buffers.zig");
const BufferStatus = @import("buffers.zig").BufferStatus;
const CreateStatus = Client.CreateStatus;
const log = std.log.scoped(.ViewportCpu);
const ViewportBase = @import("ViewportBase.zig");
