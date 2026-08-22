pub const Event = Client.Event;
pub const Renderer = Viewport.Renderer.Tag;
pub const opengl = @import("opengl.zig");

pub const ViewportID = ptypes.ViewportID;
pub const SubViewportID = ptypes.SubViewportID;
pub const BufferID = ptypes.BufferID;
pub const CursorShape = ptypes.CursorShape;
pub const ClientInfo = ptypes.ClientInfo;
pub const ClientID = ptypes.ClientID;
pub const Rect = ptypes.Rect;

pub const Key = @import("protocol").input.Key;
pub const KeyState = @import("protocol").input.KeyState;
pub const MouseButton = @import("protocol").input.MouseButton;

pub fn init(
    io: std.Io,
    gpa: std.mem.Allocator,
    environ_map: *std.process.Environ.Map,
    info: ?ClientInfo,
) !*ClientHandle {
    const client = try gpa.create(Client);
    errdefer gpa.destroy(client);

    client.* = try .init(io, gpa, environ_map, info);
    errdefer client.deinit();

    if (client.info) |i| {
        try client_to_server.message_send_json(
            io,
            gpa,
            client.connection,
            .{ .client_info_set = i },
        );
    }

    return @ptrCast(client);
}

pub const ClientHandle = opaque {
    fn cast(handle: *ClientHandle) *Client {
        return @ptrCast(@alignCast(handle));
    }

    pub fn deinit(handle: *ClientHandle) void {
        const client = handle.cast();
        const gpa = client.gpa;

        client.deinit();
        gpa.destroy(client);
    }

    pub fn init_opengl(handle: *ClientHandle, major: c_int, minor: c_int) !void {
        const client = handle.cast();
        try client.init_gbm();
        try client.init_gl(major, minor);
    }

    pub fn poll(handle: *ClientHandle, timeout: std.Io.Timeout) !void {
        const client = handle.cast();
        const ts: std.Io.Timestamp = .now(client.io, .awake);
        while (true) {
            if (timeout.toTimestamp(client.io)) |to| {
                if (ts.untilNow(client.io, .awake).nanoseconds >= to.raw.nanoseconds) {
                    break;
                }
            }

            client.poll_once(timeout) catch |err| switch (err) {
                error.Timeout => break,
                else => |e| return e,
            };
        }
    }

    pub fn poll_once(handle: *ClientHandle, timeout: std.Io.Timeout) !void {
        const client = handle.cast();
        try client.poll_once(timeout);
    }

    pub fn poll_for_events(handle: *ClientHandle, id: ViewportID, timeout: std.Io.Timeout) !void {
        const client = handle.cast();
        const ts: std.Io.Timestamp = .now(client.io, .awake);
        const vp = client.viewports.get(id) orelse return;

        // In a loop to ignore messages that are not events
        while (vp.events.items.len == 0) {
            if (timeout.toTimestamp(client.io)) |to| {
                if (ts.untilNow(client.io, .awake).nanoseconds >= to.raw.nanoseconds) {
                    break;
                }
            }

            try client.poll_once(timeout);
        }
    }

    pub fn update(handle: *ClientHandle) !void {
        const client = handle.cast();
        for (client.viewports.values()) |vp| {
            while (vp.messages.pop()) |message| {
                switch (message) {
                    inline else => |_, tag| {
                        vp.message_handle(tag, message) catch |err| switch (err) {
                            else => |e| return e,
                        };
                    },
                }
            }
        }
    }

    pub fn viewport_pending_peek(handle: *ClientHandle) ?ViewportID {
        const client = handle.cast();
        if (client.viewports_from_server.count() == 0)
            return null;

        return client.viewports_from_server.keys()[0];
    }

    pub fn expect_viewport(handle: *ClientHandle) bool {
        return handle.cast().env_flags.expect_viewport;
    }

    pub fn spawn_process_to_embed(handle: *ClientHandle, argv: []const []const u8) !std.process.Child {
        const client = handle.cast();
        var map = try client.environ_map.clone(client.gpa);
        defer map.deinit();
        try map.put(
            constants.env_flag_expect_viewport_key,
            constants.env_flag_expect_viewport_true,
        );

        return try std.process.spawn(
            client.io,
            .{
                .argv = argv,
                .environ_map = &map,
                .stdout = .close,
                .stderr = .close,
                .stdin = .close,
            },
        );
    }

    pub fn cursor_shape_set(handle: *ClientHandle, viewport_id: ViewportID, shape: CursorShape) !void {
        const client = handle.cast();

        try client_to_server.message_send_json(
            client.io,
            client.gpa,
            client.connection,
            .{
                .cursor_shape_set = .{ .viewport_id = viewport_id, .shape = shape },
            },
        );
    }

    pub fn sub_viewport_rect_set(
        handle: *ClientHandle,
        sub_viewport_id: SubViewportID,
        rect: Rect,
    ) !void {
        const client = handle.cast();

        try client_to_server.message_send_json(
            client.io,
            client.gpa,
            client.connection,
            .{
                .sub_viewport_rect_set = .{
                    .rect = rect,
                    .sub_viewport_id = sub_viewport_id,
                },
            },
        );
    }

    pub fn client_info_iterator(handle: *ClientHandle) ClientInfoIterator {
        return .{
            .handle = handle,
            .i = 0,
        };
    }

    pub const ClientInfoIterator = struct {
        handle: *ClientHandle,
        i: usize,

        pub fn next(iter: *ClientInfoIterator) ?Result {
            const client = iter.handle.cast();
            if (iter.i >= client.other_clients.count()) return null;
            defer iter.i += 1;

            const id, const clone = .{
                client.other_clients.keys()[iter.i],
                client.other_clients.values()[iter.i],
            };

            return .{
                .client_id = id,
                .info = .{
                    .name = clone.strings[clone.name.offset..][0..clone.name.len],
                },
            };
        }

        pub const Result = struct {
            client_id: ptypes.ClientID,
            info: ptypes.ClientInfo,
        };
    };
};

pub const ViewportHandle = opaque {
    fn cast(handle: *ViewportHandle) *Viewport {
        return @ptrCast(@alignCast(handle));
    }

    pub fn create(
        handle: *ClientHandle,
        renderer: Renderer,
        width: u32,
        height: u32,
        vsync: bool,
    ) !*ViewportHandle {
        const vp = try handle.cast().viewport_create(renderer, width, height, vsync);
        return @ptrCast(vp);
    }

    pub fn create_from_pending(
        handle: *ClientHandle,
        renderer: Renderer,
        vsync: bool,
        viewport_id: ViewportID,
    ) !*ViewportHandle {
        const vp = try handle.cast().viewport_create_from_pending(
            renderer,
            viewport_id,
            vsync,
        );
        return @ptrCast(vp);
    }

    pub fn id(handle: *ViewportHandle) ViewportID {
        return handle.cast().id;
    }

    pub fn is_open(handle: *ViewportHandle) bool {
        return handle.cast().open;
    }

    pub fn size(handle: *ViewportHandle) [2]u32 {
        const vp = handle.cast();
        return .{ vp.width, vp.height };
    }

    pub fn event_pop(handle: *ViewportHandle) ?Client.Event {
        return handle.cast().event_pop();
    }

    pub fn frame_wait_for_vsync_if_enabled(handle: *ViewportHandle) !void {
        const vp = handle.cast();
        try vp.client.frame_wait_for_vsync_if_enabled(vp);
    }

    pub fn frame_wait_for_vsync(handle: *ViewportHandle) !void {
        const vp = handle.cast();
        try vp.client.frame_wait_for_vsync(vp);
    }

    pub fn sub_viewport_embed(handle: *ViewportHandle, client_id_to_embed: ClientID, rect: Rect) !SubViewportID {
        const vp = handle.cast();
        return vp.client.sub_viewport_embed(vp.id, client_id_to_embed, rect);
    }

    pub fn resize(handle: *ViewportHandle, requseted_width: u32, requseted_height: u32) !void {
        const vp = handle.cast();
        try vp.client.viewport_resize(vp, requseted_width, requseted_height);
    }

    pub fn gl_frame_begin(handle: *ViewportHandle) !GlFrameBegin {
        const vp = handle.cast();

        std.debug.assert(vp.renderer == .gl);
        const gl = &vp.renderer.gl;

        if (!vp.open) return error.ViewportClosed;

        std.debug.assert(vp.current_buffer == null);

        const buffer = gl.get_buffer(std.math.maxInt(i64)) catch |err| switch (err) {
            error.Timeout => unreachable,
        };

        vp.current_buffer = buffer.id;
        return .{
            .fbo = buffer.fbo,
            .viewport_width = vp.width,
            .viewport_height = vp.height,
        };
    }

    pub fn gl_frame_end(handle: *ViewportHandle) void {
        const vp = handle.cast();
        std.debug.assert(vp.renderer == .gl);
        const gl = &vp.renderer.gl;

        const buffer = gl.buffers_collection.available.getPtr(vp.current_buffer.?) orelse
            @panic("Buffer prematurely destroyed");

        gl.frame_end(buffer);
    }

    pub fn gl_frame_present(handle: *ViewportHandle) !void {
        const vp = handle.cast();

        std.debug.assert(vp.renderer == .gl);
        const gl = &vp.renderer.gl;
        defer vp.current_buffer = null;

        const buffer = gl.buffers_collection.available.getPtr(vp.current_buffer.?) orelse
            @panic("Buffer prematurely destroyed");

        try gl.buffer_present(vp, buffer);
    }

    pub fn cpu_frame_begin(handle: *ViewportHandle) !CpuFrameBegin {
        const vp = handle.cast();
        const client = vp.client;
        std.debug.assert(vp.renderer == .cpu);
        const cpu = &vp.renderer.cpu;

        if (!vp.open) return error.ViewportClosed;

        std.debug.assert(vp.current_buffer == null);

        var buffer: ?*RendererCpu.Buffer = null;
        while (buffer == null) {
            buffer = cpu.get_buffer() orelse {
                std.debug.assert(cpu.buffers_collection.available.count() > 0);
                try client.wait_for(vp.id, .buffer_released);
                try client.update_by_tag(vp.id, .buffer_released);
                continue;
            };
        }

        vp.current_buffer = buffer.?.id;

        return .{
            .buffer = buffer.?.data,
            .width = buffer.?.width,
            .height = buffer.?.height,
            .bytes_per_pixel = buffer.?.format.bytes_per_pixel(),
            .viewport_width = vp.width,
            .viewport_height = vp.height,
        };
    }

    pub fn cpu_frame_end(_: *ViewportHandle) void {}

    pub fn cpu_frame_present(handle: *ViewportHandle) !void {
        const vp = handle.cast();
        std.debug.assert(vp.renderer == .cpu);
        const cpu = &vp.renderer.cpu;
        defer vp.current_buffer = null;

        const buffer = cpu.buffers_collection.available.getPtr(vp.current_buffer.?).?;
        try cpu.buffer_present(vp, buffer);
    }

    pub const CpuFrameBegin = struct {
        buffer: []u8,
        width: u32,
        height: u32,
        bytes_per_pixel: u8,
        viewport_width: u32,
        viewport_height: u32,
    };

    pub const GlFrameBegin = struct {
        fbo: c_uint,
        viewport_width: u32,
        viewport_height: u32,
    };
};

const std = @import("std");
const ptypes = @import("protocol").types;
const client_to_server = @import("protocol").client_to_server;
const server_to_client = @import("protocol").server_to_client;
const Client = @import("Client.zig");
const RendererGL = @import("RendererGL.zig");
const RendererCpu = @import("RendererCpu.zig");
const Viewport = @import("Viewport.zig");
const buffers = @import("buffers.zig");
const constants = @import("constants");
