const Viewport = @This();

deinited: bool,

client: *Client,
id: ViewportID,
pos: ptypes.Pos,
size: ptypes.Size,
format: ptypes.BufferFormat,
should_close: bool,
throttle_frames: bool,
refresh_cycle: u32,
frame_number: usize,
current_buffer: ?BufferID,

buffers: Buffers,

events: std.ArrayList(Client.Event),

renderer: Renderer,

pub fn init(
    id: ViewportID,
    client: *Client,
    rect: ptypes.Rect,
    format: ptypes.BufferFormat,
    throttle: bool,
    renderer: Renderer,
) Viewport {
    return .{
        .client = client,
        .deinited = false,
        .id = id,
        .pos = rect.pos(),
        .size = rect.size(),
        .format = format,
        .throttle_frames = throttle,

        .should_close = false,
        .refresh_cycle = 0,
        .frame_number = 0,
        .current_buffer = null,

        .buffers = .init_for_viewport(renderer),

        .events = .empty,

        .renderer = renderer,
    };
}

pub fn deinit(vp: *Viewport) void {
    std.debug.assert(!vp.deinited);
    const gpa = vp.client.gpa;

    vp.buffers.deinit(gpa);
    vp.events.deinit(gpa);
    vp.deinited = true;
}

pub fn event_push(vp: *Viewport, event: Client.Event) void {
    vp.events.insertAssumeCapacity(0, event);
}

pub fn event_pop(vp: *Viewport) ?Client.Event {
    return vp.events.pop();
}

pub fn resize(vp: *Viewport, requested_size: ptypes.Size) !void {
    try vp.buffers_resize(requested_size);
    vp.size = requested_size;
}

fn buffers_resize(vp: *Viewport, requested_size: ptypes.Size) !void {
    const new_size: ptypes.Size = blk: {
        const width, const height = utils.new_dimensions(requested_size.width, requested_size.height);
        break :blk .{ .width = width, .height = height };
    };

    const client = vp.client;
    switch (vp.renderer) {
        inline else => |tag| {
            const map = vp.buffers.map(tag);
            const old_size = map.values()[0].size;
            for (map.values()) |buffer| std.debug.assert(buffer.size.eql(old_size));

            if (new_size.width <= old_size.width and new_size.height <= old_size.height) {
                return;
            }

            const buffer_type = vp.renderer.buffer_type();

            const buffer_request_ids: []const ptypes.RequestID = &.{
                client.next_request_id.increment(),
                client.next_request_id.increment(),
            };

            try client.send_buffer_create(buffer_request_ids[0], vp.format, new_size, buffer_type);
            try client.send_buffer_create(buffer_request_ids[1], vp.format, new_size, buffer_type);
            const old_buffer_count = vp.buffers.count(vp.renderer);

            while (true) {
                try vp.client.poll(.none);

                // TODO: On failure destory buffers
                const maybe_failed = try vp.client.buffers_create_from_pending_into(
                    buffer_type,
                    &vp.buffers,
                    buffer_request_ids,
                );

                if (maybe_failed) |reason| {
                    log.warn(
                        "Could not resize due to buffer creation failing. error.{s}",
                        .{reason.tag_name()},
                    );
                }

                if (vp.buffers.count(vp.renderer) == old_buffer_count + buffer_request_ids.len) {
                    break;
                }
            }

            var i = map.count();
            while (i > 0) {
                i -= 1;
                const buffer = &map.values()[i];

                if (!buffer.size.eql(old_size)) continue;

                buffer.deinit();

                vp.client.send_buffer_destroy(buffer.id) catch |err| switch (err) {
                    error.WriteFailed => {},
                };

                _ = map.orderedRemove(buffer.id);
            }
        },
    }
}

pub fn buffer_present(vp: *Viewport, comptime renderer: Renderer) !void {
    std.debug.assert(vp.renderer == renderer);

    if (renderer == .d11 and !constants.os_has_d3d) {
        @compileError("OS does not have d3d");
    }

    defer {
        vp.current_buffer = null;
    }

    switch (renderer) {
        .cpu => {
            const buffer = vp.buffers.cpu.getPtr(vp.current_buffer.?).?;
            std.debug.assert(buffer.released);

            try vp.client.connection.send_buffer_present(
                vp.client.io,
                .{
                    .viewport_id = vp.id,
                    .buffer_id = buffer.id,
                    .viewport_size = vp.size,
                },
            );
            buffer.released = false;
        },

        .gl, .d11 => |tag| {
            const map = switch (tag) {
                .d11 => &vp.buffers.d11,
                .gl => &vp.buffers.gl_linux,
                .cpu => comptime unreachable,
            };
            const buffer = map.getPtr(vp.current_buffer.?).?;

            std.debug.assert(buffer.released);

            buffer.release.point.advance();

            try vp.client.connection.send_buffer_present_with_sync(
                vp.client.io,
                .{
                    .viewport_id = vp.id,
                    .buffer_id = buffer.id,
                    .acquire_point = buffer.acquire.point,
                    .release_point = buffer.release.point,
                    .viewport_size = vp.size,
                },
            );

            buffer.released = false;
            buffer.acquire.point.advance();
        },
    }

    vp.frame_number += 1;
}

pub const Renderer = enum {
    gl,
    cpu,
    d11,

    pub fn buffer_type(tag: Renderer) ptypes.BufferType {
        return switch (tag) {
            .gl => .gbm_bo,
            .cpu => .cpu,
            .d11 => .d11,
        };
    }

    pub fn BufferType(comptime tag: Renderer) type {
        return switch (tag) {
            .gl => Buffers.GlLinux,
            .cpu => Buffers.Cpu,
            .d11 => Buffers.D11,
        };
    }

    pub fn MapType(comptime tag: Renderer) type {
        return switch (tag) {
            .cpu => std.array_hash_map.Auto(BufferID, Buffers.Cpu),
            .gl => std.array_hash_map.Auto(BufferID, Buffers.GlLinux),
            .d11 => std.array_hash_map.Auto(BufferID, Buffers.D11),
        };
    }
};

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const client_to_server = @import("protocol").client_to_server;
const server_to_client = @import("protocol").server_to_client;
const ptypes = @import("protocol").types;
const c_linux = @import("c_linux");
const glad = @import("glad");
const ViewportID = ptypes.ViewportID;
const BufferID = ptypes.BufferID;
const Client = @import("Client.zig");
const constants = @import("constants");
const CreateStatus = Client.CreateStatus;
const BufferPresented = server_to_client.MessagePayload.BufferPresented;
const log = std.log.scoped(.Viewport);
const os = @import("builtin").os.tag;
const BufferCreatedCpu = server_to_client.BufferCreatedCpu;
const BufferCreatedGbmBo = server_to_client.BufferCreatedGbmBo;
const TextureCreatedD3D = server_to_client.TextureCreatedD3D;
const utils = @import("utils");
const win32 = @import("win32");
const Buffers = @import("Buffers.zig");
