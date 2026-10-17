pub const Event = Client.Event;
pub const Renderer = Viewport.Renderer.Tag;
pub const opengl = @import("opengl.zig");

pub const ViewportID = ptypes.ViewportID;
pub const SubViewportID = ptypes.SubViewportID;
pub const BufferID = ptypes.BufferID;
pub const CursorShape = ptypes.CursorShape;
pub const ClientID = ptypes.ClientID;
pub const Rect = ptypes.Rect;
pub const Size = ptypes.Size;
pub const Pos = ptypes.Pos;
pub const ViewportDisplayState = ptypes.ViewportDisplayState;

pub const Key = @import("protocol").input.Key;
pub const KeyState = @import("protocol").input.KeyState;
pub const MouseButton = @import("protocol").input.MouseButton;

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
        .{ .full_id = client.env.client_full_id, .pid = pid },
    );

    const duration: Io.Clock.Duration = .{ .raw = .fromSeconds(1), .clock = .awake };
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
        const timeout: std.Io.Timeout = .{ .duration = .{ .raw = .fromNanoseconds(timeout_ns), .clock = .awake } };
        const ts: std.Io.Timestamp = .now(client.io, .awake);
        const vp = client.viewports.get(id) orelse return;

        // In a loop to ignore messages that are not events
        while (vp.events.items.len == 0) {
            if (ts.untilNow(client.io, .awake).nanoseconds >= timeout_ns) {
                break;
            }

            try client.poll(timeout);
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

    pub fn process_create(handle: *ClientHandle, argv: []const []const u8) !*ProcessHandle {
        const client = handle.cast();

        const process: *Process = try .create(client.io, client.gpa, argv, &client.environ_map);
        errdefer {
            process.deinit();
            client.gpa.destroy(process);
        }

        try client.processes.append(client.gpa, process);

        try client.connection.send_generate_client_full_id(
            client.io,
            client.gpa,
            .{},
        );

        return @ptrCast(process);
    }

    pub fn sub_viewport_embed(handle: *ClientHandle, viewport: *ViewportHandle, process: *ProcessHandle, rect: Rect) !*SubViewportHandle {
        std.debug.assert(process.status() == .connected);
        const client = handle.cast();
        const vp = viewport.cast();
        const client_id = process.status().connected;

        return @ptrCast(
            try client.sub_viewport_embed(vp.id, client_id, rect),
        );
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

        vp.deinit();

        _ = vp.client.viewports.orderedRemove(vp.id);
        vp.client.viewports_destroyed.putAssumeCapacityNoClobber(vp.id, vp);

        vp.client.connection.send_viewport_destroy(
            vp.client.io,
            vp.client.gpa,
            .{ .viewport_id = vp.id },
        ) catch {};
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

    pub fn resize(handle: *ViewportHandle, s: ptypes.Size) void {
        handle.cast().viewport_resize(s);
    }

    pub fn gl_buffer_get(handle: *ViewportHandle) !GlBuffer {
        std.debug.assert(!handle.destroyed());

        const vp = handle.cast();

        std.debug.assert(vp.renderer == .gl);
        const gl = &vp.renderer.gl;

        std.debug.assert(vp.current_buffer == null);

        const buffer = gl.get_buffer(std.math.maxInt(i64)) catch |err| switch (err) {
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
        const gl = &vp.renderer.gl;

        const buffer = gl.buffers.getPtr(vp.current_buffer.?) orelse
            @panic("Buffer prematurely destroyed");

        gl.frame_end(buffer);

        try vp.buffer_present(.gl);
    }

    pub fn cpu_buffer_get(handle: *ViewportHandle) !CpuBuffer {
        std.debug.assert(!handle.destroyed());

        const vp = handle.cast();

        const client = vp.client;
        std.debug.assert(vp.renderer == .cpu);
        const cpu = &vp.renderer.cpu;

        std.debug.assert(vp.current_buffer == null);

        var buffer: ?*RendererCpu.Buffer = null;
        while (buffer == null) {
            buffer = cpu.get_buffer() orelse {
                std.debug.assert(cpu.buffers.count() > 0);
                try client.poll(.none); // poll for buffer_released
                continue;
            };
        }

        vp.current_buffer = buffer.?.id;

        return .{
            .buffer = buffer.?.data,
            .width = buffer.?.size.width,
            .height = buffer.?.size.height,
            .bytes_per_pixel = buffer.?.format.bytes_per_pixel(),
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
        const r = &vp.renderer.d11;

        std.debug.assert(vp.current_buffer == null);
        const buffer: *RendererD11.Buffer = try r.get_buffer();

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

        const buffer = vp.renderer.d11.buffers.getPtr(vp.current_buffer.?).?;
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

        const buffer = vp.renderer.d11.buffers.get(vp.current_buffer.?).?;
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

pub const SubViewportHandle = opaque {
    fn cast(handle: *SubViewportHandle) *SubViewport {
        return @ptrCast(@alignCast(handle));
    }

    pub fn destroy(handle: *SubViewportHandle) void {
        const svp = handle.cast();

        if (svp.deinited) {
            std.log.err("{f} double free", .{svp.id});
            return;
        }

        svp.deinit();
    }

    pub fn state(handle: *SubViewportHandle) SubViewport.State {
        return handle.cast().state;
    }

    pub fn render_size(handle: *SubViewportHandle) ptypes.Size {
        return handle.cast().render_size;
    }

    pub fn pos_get(handle: *SubViewportHandle) Pos {
        return handle.cast().pos;
    }

    pub fn size_get(handle: *SubViewportHandle) Size {
        return handle.cast().size;
    }

    pub fn rect_get(handle: *SubViewportHandle) Rect {
        const svp = handle.cast();
        return .init(svp.pos, svp.size);
    }

    pub fn pos_set(handle: *SubViewportHandle, pos: Pos) !void {
        const svp = handle.cast();

        switch (svp.state) {
            .shown, .hidden => {},
            .pending, .failed, .closed => return,
        }

        if (pos.x != svp.pos.x or pos.y != svp.pos.y) {
            try svp.client.connection.send_sub_viewport_pos_set(
                svp.client.io,
                svp.client.gpa,
                .{ .pos = pos, .sub_viewport_id = svp.id },
            );
        }

        svp.pos = pos;
    }

    pub fn size_set(handle: *SubViewportHandle, size: Size) !void {
        const svp = handle.cast();

        switch (svp.state) {
            .shown, .hidden => {},
            .pending, .failed, .closed => return,
        }

        if (size.width != svp.size.width or size.height != svp.size.height) {
            try svp.client.connection.send_sub_viewport_size_set(
                svp.client.io,
                svp.client.gpa,
                .{ .size = size, .sub_viewport_id = svp.id },
            );
        }

        svp.size = size;
    }

    pub fn rect_set(handle: *SubViewportHandle, rect: Rect) !void {
        try handle.pos_set(.from_rect(rect));
        try handle.size_set(.from_rect(rect));
    }

    pub fn display_state_get(handle: *SubViewportHandle) ptypes.ViewportDisplayState {
        return handle.cast().state.to_display_state();
    }

    pub fn display_state_set(handle: *SubViewportHandle, s: ptypes.ViewportDisplayState) !void {
        const svp = handle.cast();

        switch (svp.state) {
            .shown => if (s == .shown) return,
            .hidden => if (s == .hidden) return,
            .pending, .failed, .closed => return,
        }

        try svp.client.connection.send_sub_viewport_display_state_set(
            svp.client.io,
            svp.client.gpa,
            .{ .sub_viewport_id = svp.id, .state = s },
        );

        svp.state = .from_display_state(s);
    }
};

pub const ProcessHandle = opaque {
    fn cast(handle: *ProcessHandle) *Process {
        return @ptrCast(@alignCast(handle));
    }

    pub fn status(handle: *ProcessHandle) Process.Status {
        return handle.cast().status;
    }

    pub fn spawn(handle: *ProcessHandle, options: Process.SpawnOptions) !void {
        return handle.cast().spawn(options);
    }

    pub fn kill(handle: *ProcessHandle) void {
        const process = handle.cast();
        if (!process.deinited) {
            process.deinit();
        }
    }

    pub fn wait(handle: *ProcessHandle) std.process.Child.WaitError!std.process.Child.Term {
        const process = handle.cast();
        std.debug.assert(process.child != null);
        const result = process.child.?.wait(process.io);

        process.child = null;
        process.deinit();

        return result;
    }
};

const std = @import("std");
const Io = std.Io;
const ptypes = @import("protocol").types;
const client_to_server = @import("protocol").client_to_server;
const server_to_client = @import("protocol").server_to_client;
const Client = @import("Client.zig");
const RendererGL = Viewport.RendererGL;
const RendererCpu = Viewport.RendererCpu;
const RendererD11 = Viewport.RendererD11;
const Viewport = @import("Viewport.zig");
const SubViewport = @import("SubViewport.zig");
const Process = @import("Process.zig");
const constants = @import("constants");
const log = std.log.scoped(.agce);
const win32 = @import("win32");
const os = @import("builtin").os.tag;
const win32_foundation = @import("win32").foundation;
const d11 = @import("win32").graphics.direct3d11;
const d3d = @import("win32").graphics.direct3d;
