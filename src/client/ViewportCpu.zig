const ViewportCpu = @This();

client: *Client,
id: ViewportID,
width: u32,
height: u32,
format: ptypes.BufferFormat,
open: bool,

buffers: Buffers(Buffer),

pub fn init(client: *Client, width: u32, height: u32) !ViewportCpu {
    const format: ptypes.BufferFormat = .argb8888;
    return .{
        .client = client,
        .id = client.next_viewport_id.increment_for_client(),
        .width = width,
        .height = height,
        .format = format,
        .open = true,

        .buffers = .empty,
    };
}

pub fn deinit(vp: *ViewportCpu) void {
    vp.buffers.deinit(vp.client.gpa);
}

pub fn close(vp: *ViewportCpu) void {
    vp.open = false;
}

pub fn buffer_new(vp: *ViewportCpu, width: u32, height: u32) !void {
    try vp.buffers.ensure_unused_capacity(vp.client.gpa, 1);

    const id = vp.client.next_buffer_id.increment();
    var buffer: Buffer = try .init(id, width, height, vp.format);
    errdefer buffer.deinit();

    try vp.client.send_buffer_create_cpu_with_fd(buffer);

    vp.buffers.pending.appendAssumeCapacity(buffer);
}

pub fn resize(
    vp: *ViewportCpu,
    msg: ptypes.ViewportResize,
) !void {
    std.debug.assert(msg.viewport_id == vp.id);

    if (vp.width >= msg.width and vp.height >= msg.height) {
        return;
    }

    try vp.buffers.ensure_unused_capacity(vp.client.gpa, 2);
    try vp.buffer_new(msg.width, msg.height);
    try vp.buffer_new(msg.width, msg.height);

    while (vp.buffers.available.pop()) |b| {
        vp.buffers.old.appendAssumeCapacity(b);
        try vp.client.send_buffer_destroy(b.id);
    }

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

    errdefer comptime unreachable;

    vp.width = msg.width;
    vp.height = msg.height;
}

pub fn get_buffer(vp: *ViewportCpu) ?*Buffer {
    for (vp.buffers.available.items) |*buffer| {
        if (buffer.released) return buffer;
    }

    return null;
}

pub fn has_buffer(vp: *ViewportCpu, id: BufferID) bool {
    return vp.buffers.has(id);
}

pub fn buffer_present(vp: *ViewportCpu, buffer: *Buffer) !void {
    std.debug.assert(buffer.released);
    buffer.released = false;

    try client_to_server.message_send_json(
        vp.client.io,
        vp.client.gpa,
        vp.client.connection,
        .{
            .buffer_present = .{
                .viewport_id = vp.id,
                .buffer_id = buffer.id,
            },
        },
    );
}

pub fn frame_render(_: *ViewportCpu) void {}

pub fn buffer_released(vp: *ViewportCpu, id: BufferID) void {
    for (vp.buffers.available.items) |*buffer| {
        if (buffer.id == id) {
            buffer.released = true;
        }
    }
}

pub fn buffer_destroyed(_: *ViewportCpu, _: BufferID) void {}

pub fn buffer_created(vp: *ViewportCpu, id: BufferID) !void {
    vp.buffers.buffer_created(id);
}

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

    pub fn init(id: BufferID, width: u32, height: u32, format: ptypes.BufferFormat) !Buffer {
        const s = width * height * format.bytes_per_pixel();
        const fd, const buffer = try create_fd(s);

        return .{
            .id = id,
            .fd = @enumFromInt(fd),
            .data = buffer,
            .released = true,
            .width = width,
            .height = height,
            .format = format,
        };
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
const Buffers = @import("buffers.zig").Buffers;
