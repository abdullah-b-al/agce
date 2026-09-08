const Win32RendererCpu = @This();

buffers_collection: buffers.Collection(Buffer),

pub fn init() Win32RendererCpu {
    return .{ .buffers_collection = .empty };
}

pub fn deinit(r: *Win32RendererCpu, gpa: std.mem.Allocator) void {
    r.buffers_collection.deinit(gpa);
}

pub fn resize(r: *Win32RendererCpu, vp: *Viewport, msg: ViewportResize) !void {
    std.debug.assert(msg.viewport_id == vp.id);
    std.debug.assert(r.buffers_collection.available.count() > 0);
    const new_width, const new_height = utils.new_dimensions(msg.size.width, msg.size.height);

    const buffer = r.buffers_collection.available.values()[0];
    if (buffer.width < new_width or buffer.height < new_height) {
        try buffers.buffers_resize(
            Win32RendererCpu.Buffer,
            2,
            vp,
            vp.client,
            &r.buffers_collection,
            .{ vp.client, new_width, new_height, vp.format },
        );
    }
}

pub fn buffer_size(r: *const Win32RendererCpu) ptypes.Size {
    const buffer = r.buffers_collection.available.values()[0];
    return .{
        .width = buffer.width,
        .height = buffer.height,
    };
}

pub fn get_buffer(r: *Win32RendererCpu) ?*Buffer {
    for (r.buffers_collection.available.values()) |*buffer| {
        if (buffer.released) return buffer;
    }

    return null;
}

pub fn has_buffer(r: *Win32RendererCpu, id: BufferID) bool {
    return r.buffers_collection.has(id);
}

pub fn frame_render(_: *Win32RendererCpu) void {}

pub fn buffer_released(r: *Win32RendererCpu, id: BufferID) void {
    std.debug.assert(r.buffers_collection.available.count() > 0);
    for (r.buffers_collection.available.values()) |*buffer| {
        if (buffer.id == id) {
            buffer.released = true;
        }
    }
}

pub fn buffer_destroyed(_: *Win32RendererCpu, _: BufferID) void {}

fn create_pixel_buffer(size: i32) !struct { std.os.windows.HANDLE, []u8 } {
    const handle = win32.system.memory.CreateFileMappingA(
        win32.foundation.INVALID_HANDLE_VALUE,
        null,
        win32.system.memory.PAGE_READWRITE,
        0,
        @intCast(size),
        null,
    ) orelse return error.FailedToCreateFileMapping;
    errdefer _ = win32.foundation.CloseHandle(handle);

    const buffer = win32.system.memory.MapViewOfFile(
        handle,
        win32.system.memory.FILE_MAP_ALL_ACCESS,
        0,
        0,
        @intCast(size),
    ) orelse return error.FailedToMapViewOfFile;

    const ptr: [*]u8 = @ptrCast(buffer);

    return .{ handle, ptr[0..@intCast(size)] };
}

pub const Buffer = struct {
    id: ptypes.BufferID,
    handle: std.os.windows.HANDLE,
    data: []u8,
    released: bool,
    width: i32,
    height: i32,
    format: ptypes.BufferFormat,

    pub fn init(client: *Client, width: i32, height: i32, format: ptypes.BufferFormat) !Buffer {
        const s = width * height * format.bytes_per_pixel();
        const handle, const buffer = try create_pixel_buffer(s);

        return .{
            .id = client.next_buffer_id.increment(),
            .handle = handle,
            .data = buffer,
            .released = true,
            .width = width,
            .height = height,
            .format = format,
        };
    }

    pub fn create_on_server(_: Buffer, _: *Viewport, _: *Client) !void {
        unreachable;
    }

    pub fn deinit(buffer: *Buffer) void {
        _ = win32.system.memory.UnmapViewOfFile(buffer.data.ptr);
        _ = win32.foundation.CloseHandle(buffer.handle);
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
const win32 = @import("win32");
