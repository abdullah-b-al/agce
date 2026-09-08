const Viewport = @This();

deinited: bool,

client: *Client,
id: ViewportID,
size: ptypes.Size,
format: ptypes.BufferFormat,
should_close: bool,
throttle_frames: bool,
refresh_cycle: u32,
frame_number: usize,
current_buffer: ?BufferID,

status: Client.CreateStatus,
pending_buffers_cpu: std.ArrayList(BufferCreatedCpu),
pending_buffers_gbm_bo: std.ArrayList(BufferCreatedGbmBo),

messages: std.ArrayList(Client.Message),
events: std.ArrayList(Client.Event),

renderer: Renderer,

pub fn init(
    id: ViewportID,
    client: *Client,
    size: ptypes.Size,
    format: ptypes.BufferFormat,
    throttle: bool,
    renderer: Renderer,
) Viewport {
    return .{
        .client = client,
        .deinited = false,
        .id = id,
        .size = size,
        .format = format,
        .throttle_frames = throttle,
        .pending_buffers_cpu = .empty,
        .pending_buffers_gbm_bo = .empty,

        .should_close = false,
        .refresh_cycle = 0,
        .frame_number = 0,
        .current_buffer = null,

        .messages = .empty,
        .events = .empty,

        .status = .pending,
        .renderer = renderer,
    };
}

pub fn deinit(vp: *Viewport) void {
    std.debug.assert(!vp.deinited);
    const gpa = vp.client.gpa;

    vp.pending_buffers_cpu.deinit(gpa);
    vp.pending_buffers_gbm_bo.deinit(gpa);

    switch (vp.renderer) {
        inline else => |*r| r.deinit(gpa),
    }

    vp.messages.deinit(gpa);
    vp.events.deinit(gpa);
    vp.deinited = true;
}

pub fn event_push(vp: *Viewport, event: Client.Event) void {
    vp.events.insertAssumeCapacity(0, event);
}

pub fn event_pop(vp: *Viewport) ?Client.Event {
    return vp.events.pop();
}

pub fn message_push(vp: *Viewport, message: Client.Message) void {
    vp.messages.insertAssumeCapacity(0, message);
}

pub fn message_handle(vp: *Viewport, comptime tag: Client.Message.Tag, message: Client.Message) !void {
    std.debug.assert(tag == message);
    const msg = @field(message, @tagName(tag));

    switch (tag) {
        .viewport_created => {
            std.debug.assert(vp.status == .pending);
            switch (msg.status) {
                .success => vp.status = .created,
                .failure => vp.status = .failed,
            }
        },
        .viewport_resize => {
            try vp.buffer_resize(msg.size);
        },

        .buffer_released => {
            switch (vp.renderer) {
                .gl => {}, // relies on timelines
                .cpu => |*r| r.buffer_released(msg.buffer_id),
            }
        },
        .frame_render => {
            vp.refresh_cycle = msg.refresh_cycle;
        },
    }
}

pub fn viewport_resize(vp: *Viewport, size: ptypes.Size) void {
    const buffer_size = switch (vp.renderer) {
        inline else => |r| r.buffer_size(),
    };

    const width = @min(buffer_size.width, size.width);
    const height = @min(buffer_size.height, size.height);

    vp.size = .{ .width = width, .height = height };
}

pub fn buffer_present(vp: *Viewport) !void {
    defer {
        vp.current_buffer = null;
    }

    const buffer: *anyopaque, const message: client_to_server.MessagePayload =
        blk: switch (vp.renderer) {
            .cpu => |*cpu| {
                const buffer = cpu.buffers.getPtr(vp.current_buffer.?).?;
                std.debug.assert(buffer.released);

                break :blk .{
                    buffer,
                    .{
                        .buffer_present = .{
                            .viewport_id = vp.id,
                            .buffer_id = buffer.id,
                            .viewport_size = vp.size,
                        },
                    },
                };
            },
            .gl => |*gl| {
                const buffer = gl.buffers.getPtr(vp.current_buffer.?) orelse
                    @panic("Buffer prematurely destroyed");
                std.debug.assert(buffer.released);
                buffer.release.point.advance();

                break :blk .{
                    buffer,
                    .{
                        .buffer_present_with_sync = .{
                            .viewport_id = vp.id,
                            .buffer_id = buffer.id,
                            .acquire_point = buffer.acquire.point,
                            .release_point = buffer.release.point,
                            .viewport_size = vp.size,
                        },
                    },
                };
            },
        };

    try client_to_server.message_send_json(
        vp.client.io,
        vp.client.gpa,
        vp.client.connection,
        message,
    );

    switch (vp.renderer) {
        .cpu => |_, tag| {
            const b: *Renderer.RendererBuffer(tag) = @ptrCast(@alignCast(buffer));
            b.released = false;
        },
        .gl => |_, tag| {
            const b: *Renderer.RendererBuffer(tag) = @ptrCast(@alignCast(buffer));
            b.acquire.point.advance();
            b.released = false;
        },
    }

    vp.frame_number += 1;
}

pub fn buffers_create(
    vp: *Viewport,
    requested_size: ptypes.Size,
) !void {
    const client = vp.client;
    const buffer_count = 2;
    const width, const height = utils.new_dimensions(requested_size.width, requested_size.height);
    switch (vp.renderer) {
        .cpu => {
            for (0..buffer_count) |_| {
                try client_to_server.message_send_json(
                    client.io,
                    client.gpa,
                    client.connection,
                    .{
                        .buffer_create_cpu = .{
                            .viewport_id = vp.id,
                            .format = vp.format,
                            .size = .{ .width = width, .height = height },
                        },
                    },
                );
            }

            std.debug.assert(vp.pending_buffers_cpu.items.len == 0);
            while (vp.pending_buffers_cpu.items.len != buffer_count) {
                try client.poll(.none);
            }
            std.debug.assert(vp.pending_buffers_cpu.items.len >= buffer_count);

            try vp.renderer_buffers_create(BufferCreatedCpu, vp.pending_buffers_cpu.items);
            vp.pending_buffers_cpu.clearRetainingCapacity();
        },
        .gl => {
            for (0..buffer_count) |_| {
                try client_to_server.message_send_json(
                    client.io,
                    client.gpa,
                    client.connection,
                    .{
                        .buffer_create_gbm_bo = .{
                            .viewport_id = vp.id,
                            .format = vp.format,
                            .size = .{ .width = width, .height = height },
                        },
                    },
                );
            }

            std.debug.assert(vp.pending_buffers_gbm_bo.items.len == 0);
            while (vp.pending_buffers_gbm_bo.items.len != buffer_count) {
                try client.poll(.none);
            }
            std.debug.assert(vp.pending_buffers_gbm_bo.items.len >= buffer_count);

            try vp.renderer_buffers_create(BufferCreatedGbmBo, vp.pending_buffers_gbm_bo.items);
            vp.pending_buffers_gbm_bo.clearRetainingCapacity();
        },
    }
}
pub fn renderer_buffers_create(
    vp: *Viewport,
    comptime Buffer: type,
    created: []Buffer,
) !void {
    const gpa = vp.client.gpa;

    defer {
        for (created) |c| {
            switch (Buffer) {
                BufferCreatedCpu => {
                    switch (os) {
                        .linux => {
                            std.debug.assert(std.os.linux.close(@intFromEnum(c.handle)) == 0);
                        },
                        else => comptime unreachable,
                    }
                },
                BufferCreatedGbmBo => {},
                else => comptime unreachable,
            }
        }
    }

    switch (vp.renderer) {
        .gl => |*r| {
            switch (RendererGL) {
                LinuxRendererGL => {
                    if (Buffer == BufferCreatedGbmBo) {
                        std.debug.assert(r.buffers.count() == 0);
                        try r.buffers.ensureUnusedCapacity(gpa, created.len);

                        for (created) |b| {
                            const buffer: LinuxRendererGL.Buffer = try .init(
                                vp.client.gbm.?,
                                vp.client.gl_context.?,
                                b,
                            );
                            r.buffers.putAssumeCapacityNoClobber(buffer.id, buffer);
                        }
                    }
                },
                else => comptime unreachable,
            }
        },
        .cpu => |*r| {
            if (Buffer == BufferCreatedCpu) {
                std.debug.assert(r.buffers.count() == 0);
                try r.buffers.ensureUnusedCapacity(gpa, created.len);

                for (created) |b| {
                    const buffer: RendererCpu.Buffer = try .init(b);
                    r.buffers.putAssumeCapacityNoClobber(buffer.id, buffer);
                }
            }
        },
    }
}

pub fn buffer_resize(
    vp: *Viewport,
    requested_size: ptypes.Size,
) !void {
    const new_width, const new_height = utils.new_dimensions(requested_size.width, requested_size.height);
    const new_size: ptypes.Size = .{ .width = new_width, .height = new_height };
    const buffer_size = switch (vp.renderer) {
        inline else => |r| r.buffer_size(),
    };

    if (buffer_size.width < new_width or buffer_size.height < new_height) {
        switch (vp.renderer) {
            inline .gl, .cpu => |*r| {
                var old_buffers = r.buffers;
                r.buffers = .empty;

                vp.buffers_create(new_size) catch |err| {
                    r.buffers = old_buffers;
                    return err;
                };
                std.debug.assert(r.buffers.count() != 0);

                for (old_buffers.values()) |*old| {
                    old.deinit();

                    client_to_server.message_send_json(
                        vp.client.io,
                        vp.client.gpa,
                        vp.client.connection,
                        .{ .buffer_destroy = .{ .buffer_id = old.id } },
                    ) catch {};
                }
                old_buffers.deinit(vp.client.gpa);
            },
        }
    }
}

pub const RendererGL = switch (os) {
    .linux => LinuxRendererGL,
    .windows => Win32RendererGL,
    else => unreachable,
};

pub const RendererCpu = switch (os) {
    .linux => LinuxRendererCpu,
    .windows => Win32RendererCpu,
    else => unreachable,
};

pub const Renderer = union(enum) {
    pub const Tag = std.meta.Tag(Renderer);

    gl: RendererGL,
    cpu: RendererCpu,

    pub fn RendererBuffer(comptime tag: Tag) type {
        return switch (tag) {
            .gl => RendererGL.Buffer,
            .cpu => RendererCpu.Buffer,
        };
    }
};

pub const LinuxRendererGL = @import("LinuxRendererGL.zig");
pub const LinuxRendererCpu = @import("LinuxRendererCpu.zig");
pub const Win32RendererGL = @import("Win32RendererGL.zig");
pub const Win32RendererCpu = @import("Win32RendererCpu.zig");

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
const buffers = @import("buffers.zig");
const BufferStatus = @import("buffers.zig").BufferStatus;
const CreateStatus = Client.CreateStatus;
const BufferPresented = server_to_client.MessagePayload.BufferPresented;
const log = std.log.scoped(.Viewport);
const os = @import("builtin").os.tag;
const BufferCreatedCpu = server_to_client.MessagePayload.BufferCreatedCpu;
const BufferCreatedGbmBo = server_to_client.MessagePayload.BufferCreatedGbmBo;
const utils = @import("utils");
