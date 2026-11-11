pub const Event = Client.Event;
pub const Renderer = Viewport.Renderer;
pub const opengl = @import("opengl.zig");

pub const ViewportID = ptypes.ViewportID;
pub const RemoteViewportID = ptypes.RemoteViewportID;
pub const BufferID = ptypes.BufferID;
pub const CursorShape = ptypes.CursorShape;
pub const ClientUUID = ptypes.ClientUUID;
pub const Rect = ptypes.Rect;
pub const Size = ptypes.Size;
pub const Pos = ptypes.Pos;
pub const ViewportDisplayState = ptypes.ViewportDisplayState;

pub const Key = @import("protocol").input.Key;
pub const KeyState = @import("protocol").input.KeyState;
pub const MouseButton = @import("protocol").input.MouseButton;

pub const RemoteClient = @import("remote_client").RemoteClient;
pub const Process = @import("remote_client").Process;

pub fn init(
    io: std.Io,
    gpa: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
) !*ClientHandle {
    const client = try gpa.create(Client);
    errdefer gpa.destroy(client);

    client.* = try .init(io, gpa, environ_map);
    errdefer client.deinit();

    const pid: ?ptypes.PID = switch (os) {
        .linux => null,
        .windows => @enumFromInt(win32.system.threading.GetCurrentProcessId()),
        else => comptime unreachable,
    };

    try client.connection.send_register(
        io,
        gpa,
        client.env.client_uuid,
        pid,
    );

    const duration: Io.Clock.Duration = .{ .raw = .fromSeconds(60), .clock = .awake };
    client.poll(.{ .duration = duration }) catch |err| switch (err) {
        error.Timeout => return error.TimeoutDuringRegisterPhase,
        else => |e| return e,
    };

    if (!client.registered) {
        std.log.err("Server did not respond with 'registered'", .{});
        return error.FailedToRegister;
    }

    log.debug("Client registered", .{});

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
        if (constants.os_has_gbm) {
            try client.init_gbm();
            try client.init_gl(major, minor);
        } else {
            @panic("TODO");
        }
    }

    pub fn init_d3d11(handle: *ClientHandle) !void {
        try handle.cast().init_d3d11();
    }

    pub fn poll(handle: *ClientHandle, timeout_ns: u64) !void {
        const client = handle.cast();

        const timeout: std.Io.Timeout = .{ .duration = .{ .raw = .fromNanoseconds(timeout_ns), .clock = .awake } };
        client.poll(timeout) catch |err| switch (err) {
            error.Timeout => return,
            else => |e| return e,
        };
    }

    pub fn poll_for_events(handle: *ClientHandle, id: ViewportID, timeout_ns: u64) !void {
        const client = handle.cast();
        const vp = client.viewports.get(id) orelse return;

        // In a loop to ignore messages that are not events
        var timeout: std.Io.Timeout = .{ .duration = .{ .raw = .fromNanoseconds(timeout_ns), .clock = .awake } };
        while (vp.events.items.len == 0) {
            const ts: std.Io.Timestamp = .now(client.io, .awake);

            try client.poll(timeout);

            const until_now = ts.untilNow(client.io, .awake).nanoseconds;
            if (until_now < timeout.duration.raw.nanoseconds) {
                timeout.duration.raw.nanoseconds -= until_now;
            } else {
                break;
            }
        }
    }

    pub fn viewport_create(
        handle: *ClientHandle,
        renderer: Renderer,
        s: Size,
        throttle: bool,
    ) !*ViewportHandle {
        const vp = try handle.cast().viewport_create(renderer, s, throttle);
        return @ptrCast(vp);
    }

    pub fn viewport_create_from_pending(
        handle: *ClientHandle,
        renderer: Renderer,
        viewport_id: ViewportID,
        s: Size,
        throttle: bool,
    ) !*ViewportHandle {
        const vp = try handle.cast().viewport_create_from_pending(
            renderer,
            viewport_id,
            throttle,
            s,
        );
        return @ptrCast(vp);
    }

    pub fn remote_client_create(handle: *ClientHandle) !*RemoteClient {
        const client = handle.cast();

        try client.remote_clients.ensureUnusedCapacity(client.gpa, 1);
        const remote = try client.gpa.create(RemoteClient);

        remote.* = .init(client.io);
        client.remote_clients.appendAssumeCapacity(remote);

        return remote;
    }

    pub fn remote_client_destroy(handle: *ClientHandle, remote: *RemoteClient) void {
        const client = handle.cast();
        for (client.remote_clients.items, 0..) |r, i| {
            if (r == remote) {
                _ = client.remote_clients.swapRemove(i);
                client.gpa.destroy(remote);
                return;
            }
        }
    }

    pub fn process_init(
        handle: *ClientHandle,
        argv: []const []const u8,
    ) !Process {
        const client = handle.cast();
        return .init(
            client.io,
            client.gpa,
            argv,
            &client.environ_map,
            client.environ_map.get(constants.env_agce_socket_path),
        );
    }

    pub fn remote_viewport_embed(handle: *ClientHandle, viewport: *ViewportHandle, remote: *RemoteClient, rect: Rect) !*RemoteViewportHandle {
        std.debug.assert(remote.status == .connected);
        const client = handle.cast();
        const vp = viewport.cast();

        return @ptrCast(
            try client.remote_viewport_embed(vp.id, remote.uuid, rect),
        );
    }

    pub const ViewportPendingPeek = struct {
        id: ViewportID,
        requsted_size: Size,
    };
    pub fn viewport_pending_peek(handle: *ClientHandle) ?ViewportPendingPeek {
        const client = handle.cast();
        if (client.viewports_from_server.count() == 0)
            return null;

        const id = client.viewports_from_server.keys()[0];
        const size = client.viewports_from_server.values()[0];
        return .{ .id = id, .requsted_size = size };
    }

    pub fn expect_viewport(handle: *ClientHandle) bool {
        return handle.cast().env.expect_viewport;
    }

    pub fn cursor_shape_set(handle: *ClientHandle, viewport_id: ViewportID, shape: CursorShape) !void {
        const client = handle.cast();

        try client.connection.send_cursor_shape_set(
            client.io,
            client.gpa,
            .{ .viewport_id = viewport_id, .shape = shape },
        );
    }

    pub fn d11_device(handle: *ClientHandle) *d11.ID3D11Device {
        if (handle.cast().d11_device == null) {
            @panic("Direct11 not initialized");
        }

        return handle.cast().d11_device.?.device;
    }

    pub fn d11_device_context(handle: *ClientHandle) *d11.ID3D11DeviceContext {
        if (handle.cast().d11_device == null) {
            @panic("Direct11 not initialized");
        }

        return handle.cast().d11_device.?.context;
    }
};

pub const ViewportHandle = opaque {
    fn cast(handle: *ViewportHandle) *Viewport {
        return @ptrCast(@alignCast(handle));
    }

    pub fn destroy(handle: *ViewportHandle) void {
        const vp = handle.cast();

        if (vp.deinited) {
            log.err("{f} double free", .{vp.id});
            return;
        }

        _ = vp.client.viewports.orderedRemove(vp.id);

        vp.client.connection.send_viewport_destroy(
            vp.client.io,
            vp.client.gpa,
            .{ .viewport_id = vp.id },
        ) catch {};

        vp.deinit();
        vp.client.gpa.destroy(vp);
    }

    pub fn id(handle: *ViewportHandle) ViewportID {
        return handle.cast().id;
    }

    pub fn destroyed(handle: *ViewportHandle) bool {
        return handle.cast().deinited;
    }

    pub fn should_close_set(handle: *ViewportHandle, value: bool) void {
        handle.cast().should_close = value;
    }

    pub fn should_close(handle: *ViewportHandle) bool {
        return handle.cast().should_close;
    }

    pub fn size(handle: *ViewportHandle) Size {
        return handle.cast().size;
    }

    pub fn event_pop(handle: *ViewportHandle) ?Client.Event {
        return handle.cast().event_pop();
    }

    pub fn throttle_frames_if_enabled(handle: *ViewportHandle) !void {
        const vp = handle.cast();
        try vp.client.throttle_frames_if_enabled(vp);
    }

    pub fn throttle_frames(handle: *ViewportHandle) !void {
        const vp = handle.cast();
        try vp.client.throttle_frames(vp);
    }

    pub fn resize(handle: *ViewportHandle, s: ptypes.Size) !void {
        try handle.cast().resize(s);
    }

    pub fn gl_buffer_get(handle: *ViewportHandle) !GlBuffer {
        std.debug.assert(!handle.destroyed());

        const vp = handle.cast();

        std.debug.assert(vp.renderer == .gl);
        std.debug.assert(vp.current_buffer == null);

        const buffer = vp.buffers.get_gl_linux(
            vp.client.gbm.?,
            std.math.maxInt(i64),
        ) catch |err| switch (err) {
            error.Timeout => unreachable,
        };

        vp.current_buffer = buffer.id;
        return .{
            .fbo = buffer.fbo,
            .viewport_size = vp.size,
        };
    }

    pub fn gl_present(handle: *ViewportHandle) !void {
        const vp = handle.cast();
        std.debug.assert(vp.renderer == .gl);

        const buffer = vp.buffers.gl_linux.getPtr(vp.current_buffer.?) orelse
            @panic("Buffer prematurely destroyed");

        buffer.frame_end(
            vp.client.gbm.?,
            vp.client.gl_context.?.egl_display,
        );

        try vp.buffer_present(.gl);
    }

    pub fn cpu_buffer_get(handle: *ViewportHandle) !CpuBuffer {
        std.debug.assert(!handle.destroyed());

        const vp = handle.cast();

        const client = vp.client;
        std.debug.assert(vp.renderer == .cpu);
        std.debug.assert(vp.current_buffer == null);

        var buffer: *Buffers.Cpu = blk: while (true) {
            if (vp.buffers.get_cpu()) |buffer| {
                break :blk buffer;
            }

            try client.poll(.none); // poll for buffer_released
        };

        vp.current_buffer = buffer.id;

        return .{
            .buffer = buffer.data,
            .width = buffer.size.width,
            .height = buffer.size.height,
            .bytes_per_pixel = buffer.format.bytes_per_pixel(),
            .viewport_size = vp.size,
        };
    }

    pub fn cpu_present(handle: *ViewportHandle) !void {
        try handle.cast().buffer_present(.cpu);
    }

    pub fn d11_buffer_get(handle: *ViewportHandle) !D11Buffer {
        if (!constants.os_has_d3d) {
            @panic("OS does not have d3d");
        }

        std.debug.assert(!handle.destroyed());
        const vp = handle.cast();

        const client = vp.client;
        std.debug.assert(vp.renderer == .d11);
        std.debug.assert(vp.current_buffer == null);

        const buffer = try vp.buffers.get_d11();

        vp.current_buffer = buffer.id;

        return .{
            .rtv = buffer.rtv,
            .context = client.d11_device.?.context,
        };
    }

    pub fn d11_present(handle: *ViewportHandle) !void {
        if (!constants.os_has_d3d) {
            @panic("OS does not have d3d");
        }

        const vp = handle.cast();
        const d11_device = vp.client.d11_device.?;

        std.debug.assert(vp.current_buffer != null);

        const buffer = vp.buffers.d11.getPtr(vp.current_buffer.?).?;
        const hr = d11_device.context4.Signal(
            buffer.acquire.fence.acquire,
            @intFromEnum(buffer.acquire.point),
        );
        std.debug.assert(hr == win32_foundation.S_OK);

        try vp.buffer_present(.d11);
    }

    pub fn d11_render_target_view(handle: *ViewportHandle) *d11.ID3D11RenderTargetView {
        const vp = handle.cast();
        if (vp.client.d11_device == null) {
            @panic("Direct11 not initialized");
        }

        std.debug.assert(vp.renderer == .d11);
        std.debug.assert(vp.current_buffer != null);

        const buffer = vp.renderer.d11.Buffers.get(vp.current_buffer.?).?;
        return buffer.rtv;
    }

    pub const D11Buffer = struct {
        rtv: *d11.ID3D11RenderTargetView,
        context: *d11.ID3D11DeviceContext,
    };

    pub const CpuBuffer = struct {
        buffer: []u8,
        width: i32,
        height: i32,
        bytes_per_pixel: u8,
        viewport_size: Size,
    };

    pub const GlBuffer = struct {
        fbo: c_uint,
        viewport_size: Size,
    };
};

pub const RemoteViewportHandle = opaque {
    fn cast(handle: *RemoteViewportHandle) *RemoteViewport {
        return @ptrCast(@alignCast(handle));
    }

    pub fn destroy(handle: *RemoteViewportHandle) void {
        const rvp = handle.cast();

        if (rvp.deinited) {
            std.log.err("{f} double free", .{rvp.id});
            return;
        }

        rvp.deinit();
    }

    pub fn send_close(handle: *RemoteViewportHandle) !void {
        const rvp = handle.cast();
        const vp_key = switch (rvp.state) {
            .shown, .hidden => |key| key,
            .failed, .pending, .closed => return,
        };
        try rvp.client.connection.send_viewport_close(
            rvp.client.io,
            rvp.client.gpa,
            .{ .viewport_key = vp_key },
        );
    }

    pub fn state(handle: *RemoteViewportHandle) RemoteViewport.State {
        return handle.cast().state;
    }

    pub fn render_size(handle: *RemoteViewportHandle) ptypes.Size {
        return handle.cast().render_size;
    }

    pub fn pos_get(handle: *RemoteViewportHandle) Pos {
        return handle.cast().pos;
    }

    pub fn size_get(handle: *RemoteViewportHandle) Size {
        return handle.cast().size;
    }

    pub fn rect_get(handle: *RemoteViewportHandle) Rect {
        const rvp = handle.cast();
        return .init(rvp.pos, rvp.size);
    }

    pub fn pos_set(handle: *RemoteViewportHandle, pos: Pos) !void {
        const rvp = handle.cast();

        const key = switch (rvp.state) {
            .shown, .hidden => |key| key,
            .pending, .failed, .closed => return,
        };

        if (pos.x != rvp.pos.x or pos.y != rvp.pos.y) {
            try rvp.client.connection.send_viewport_pos_set(
                rvp.client.io,
                rvp.client.gpa,
                .{ .pos = pos, .viewport_key = key },
            );
        }

        rvp.pos = pos;
    }

    pub fn size_set(handle: *RemoteViewportHandle, size: Size) !void {
        const rvp = handle.cast();

        const vp_key = switch (rvp.state) {
            .shown, .hidden => |key| key,
            .pending, .failed, .closed => return,
        };

        if (size.width != rvp.size.width or size.height != rvp.size.height) {
            try rvp.client.connection.send_viewport_size_set(
                rvp.client.io,
                rvp.client.gpa,
                .{ .size = size, .viewport_key = vp_key },
            );
        }

        rvp.size = size;
    }

    pub fn rect_set(handle: *RemoteViewportHandle, rect: Rect) !void {
        try handle.pos_set(.from_rect(rect));
        try handle.size_set(.from_rect(rect));
    }

    pub fn display_state_get(handle: *RemoteViewportHandle) ptypes.ViewportDisplayState {
        return handle.cast().state.to_display_state();
    }

    pub fn display_state_set(handle: *RemoteViewportHandle, s: ptypes.ViewportDisplayState) !void {
        const rvp = handle.cast();

        const vp_key = switch (rvp.state) {
            .shown => |key| if (s != .shown) key else return,
            .hidden => |key| if (s != .hidden) key else return,
            .pending, .failed, .closed => return,
        };

        try rvp.client.connection.send_viewport_display_state_set(
            rvp.client.io,
            rvp.client.gpa,
            .{ .viewport_key = vp_key, .state = s },
        );

        rvp.state = .from_display_state(s, vp_key);
    }
};

const std = @import("std");
const Io = std.Io;
const ptypes = @import("protocol").types;
const client_to_server = @import("protocol").client_to_server;
const server_to_client = @import("protocol").server_to_client;
const Client = @import("Client.zig");
const Viewport = @import("Viewport.zig");
const RemoteViewport = @import("RemoteViewport.zig");
const constants = @import("constants");
const log = std.log.scoped(.agce);
const win32 = @import("win32");
const os = @import("builtin").os.tag;
const win32_foundation = @import("win32").foundation;
const d11 = @import("win32").graphics.direct3d11;
const d3d = @import("win32").graphics.direct3d;
const Buffers = @import("Buffers.zig");
