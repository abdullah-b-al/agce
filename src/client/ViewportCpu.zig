const ViewportCpu = @This();

client: *Client,
id: ViewportID,
width: u32,
height: u32,
format: protocol_types.BufferFormat,

front: Buffer,
back: Buffer,

pub fn init(client: *Client, width: u32, height: u32) !ViewportCpu {
    const format: protocol_types.BufferFormat = .argb8888;
    const front: Buffer = try .init(client.next_buffer_id.increment(), width, height, format);
    const back: Buffer = try .init(client.next_buffer_id.increment(), width, height, format);

    return .{
        .client = client,
        .id = client.next_viewport_id.increment_for_client(),
        .width = width,
        .height = height,
        .format = format,

        .front = front,
        .back = back,
    };
}

pub fn deinit(vp: *ViewportCpu) void {
    vp.front.deinit();
    vp.back.deinit();
}

pub fn resize(
    vp: *ViewportCpu,
    msg: protocol_types.ViewportResize,
) !void {
    std.debug.assert(msg.viewport_id == vp.id);

    if (vp.width >= msg.width and vp.height >= msg.height) {
        return;
    }

    const front: Buffer = try .init(vp.client.next_buffer_id.increment(), msg.width, msg.height, vp.format);
    const back: Buffer = try .init(vp.client.next_buffer_id.increment(), msg.width, msg.height, vp.format);

    try vp.client.send_buffer_create_cpu_with_fd(back);
    try vp.client.send_buffer_create_cpu_with_fd(front);
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

    vp.back.deinit();
    vp.front.deinit();

    vp.back = back;
    vp.front = front;

    vp.width = msg.width;
    vp.height = msg.height;
}

pub fn get_buffer(vp: *ViewportCpu) ?*Buffer {
    if (vp.back.released) return &vp.back;
    if (vp.front.released) return &vp.front;
    return null;
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

pub fn buffer_released(vp: *ViewportCpu, id: BufferID) void {
    inline for (&.{ &vp.back, &vp.front }) |buffer| {
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
    id: protocol_types.BufferID,
    fd: protocol_types.CpuBufferFd,
    data: []align(std.heap.page_size_min) u8,
    released: bool,
    width: u32,
    height: u32,
    format: protocol_types.BufferFormat,

    pub fn init(id: BufferID, width: u32, height: u32, format: protocol_types.BufferFormat) !Buffer {
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

    fn deinit(buffer: *Buffer) void {
        std.posix.munmap(buffer.data);
        _ = std.os.linux.close(@intFromEnum(buffer.fd));
    }
};

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const constants = @import("../constants.zig");
const utils = @import("../server/utils.zig");
const client_to_server = @import("../protocol/client_to_server.zig");
const server_to_client = @import("../protocol/server_to_client.zig");
const common = @import("../protocol/common.zig");
const protocol_types = @import("../protocol/types.zig");
const opengl = @import("../opengl.zig");
const c_linux = @import("c_linux");
const glad = @import("glad");
const ViewportID = protocol_types.ViewportID;
const BufferID = protocol_types.BufferID;
const Client = @import("Client.zig");
