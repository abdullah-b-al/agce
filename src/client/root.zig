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
pub const Size = ptypes.Size;
pub const ViewportDisplayState = ptypes.ViewportDisplayState;

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

    try client_to_server.message_send_json(
        io,
        gpa,
        client.connection,
        .{
            .register = .{ .full_id = client.env.client_full_id, .info = client.info },
        },
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

        client.poll(timeout) catch |err| switch (err) {
            error.Timeout => return,
            else => |e| return e,
        };
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

            try client.poll(timeout);
        }
    }

    pub fn viewport_create(
        handle: *ClientHandle,
        renderer: Renderer,
        s: Size,
        vsync: bool,
    ) !*ViewportHandle {
        const vp = try handle.cast().viewport_create(renderer, s, vsync);
        return @ptrCast(vp);
    }

    pub fn viewport_create_from_pending(
        handle: *ClientHandle,
        renderer: Renderer,
        viewport_id: ViewportID,
        s: Size,
        vsync: bool,
    ) !*ViewportHandle {
        const vp = try handle.cast().viewport_create_from_pending(
            renderer,
            viewport_id,
            vsync,
            s,
        );
        return @ptrCast(vp);
    }

    pub fn process_create(handle: *ClientHandle, argv: []const []const u8) !*ProcessHandle {
        const client = handle.cast();

        const process: *Process = try .create(client.io, client.gpa, argv, &client.environ_map);
        errdefer process.destroy(client.gpa);
        try client.processes.append(client.gpa, process);

        try client_to_server.message_send_json(
            client.io,
            client.gpa,
            client.connection,
            .{ .generate_client_full_id = .{} },
        );

        return @ptrCast(process);
    }

    pub fn sub_viewport_embed(handle: *ClientHandle, viewport: *ViewportHandle, client_id_to_embed: ClientID, rect: Rect) !*SubViewportHandle {
        const client = handle.cast();
        const vp = viewport.cast();
        return @ptrCast(
            try client.sub_viewport_embed(
                vp.id,
                client_id_to_embed,
                rect,
            ),
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

        try client_to_server.message_send_json(
            client.io,
            client.gpa,
            client.connection,
            .{
                .cursor_shape_set = .{ .viewport_id = viewport_id, .shape = shape },
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

    pub fn destroy(handle: *ViewportHandle) void {
        const vp = handle.cast();

        if (vp.deinited) {
            log.err("{f} double free", .{vp.id});
            return;
        }

        vp.deinit();
    }

    pub fn id(handle: *ViewportHandle) ViewportID {
        return handle.cast().id;
    }

    pub fn is_open(handle: *ViewportHandle) bool {
        return handle.cast().open;
    }

    pub fn size(handle: *ViewportHandle) Size {
        return handle.cast().size;
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

    pub fn resize(handle: *ViewportHandle, s: ptypes.Size) void {
        handle.cast().viewport_resize(s);
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
            .viewport_size = vp.size,
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
        try handle.cast().buffer_present();
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
            .viewport_size = vp.size,
        };
    }

    pub fn cpu_frame_end(_: *ViewportHandle) void {}

    pub fn cpu_frame_present(handle: *ViewportHandle) !void {
        try handle.cast().buffer_present();
    }

    pub const CpuFrameBegin = struct {
        buffer: []u8,
        width: u32,
        height: u32,
        bytes_per_pixel: u8,
        viewport_size: Size,
    };

    pub const GlFrameBegin = struct {
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

    pub fn rect_get(handle: *SubViewportHandle) Rect {
        return handle.cast().rect;
    }

    pub fn rect_set(handle: *SubViewportHandle, rect: Rect) !void {
        const svp = handle.cast();

        switch (svp.state) {
            .shown, .hidden => {},
            .pending, .failed, .closed => return,
        }

        try client_to_server.message_send_json(
            svp.client.io,
            svp.client.gpa,
            svp.client.connection,
            .{
                .sub_viewport_rect_set = .{
                    .rect = rect,
                    .sub_viewport_id = svp.id,
                },
            },
        );

        svp.rect = rect;
    }

    pub fn display_state_get(handle: *SubViewportHandle) ptypes.ViewportDisplayState {
        return handle.cast().state;
    }

    pub fn display_state_set(handle: *SubViewportHandle, s: ptypes.ViewportDisplayState) !void {
        const svp = handle.cast();

        switch (svp.state) {
            .shown => if (s == .shown) return,
            .hidden => if (s == .hidden) return,
            .pending, .failed, .closed => return,
        }

        try client_to_server.message_send_json(
            svp.client.io,
            svp.client.gpa,
            svp.client.connection,
            .{
                .sub_viewport_display_state_set = .{
                    .sub_viewport_id = svp.id,
                    .state = s,
                },
            },
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
        if (process.child) |_| {
            process.deinit();
        }
        process.child = null;
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
const RendererGL = @import("RendererGL.zig");
const RendererCpu = @import("RendererCpu.zig");
const Viewport = @import("Viewport.zig");
const SubViewport = @import("SubViewport.zig");
const buffers = @import("buffers.zig");
const Process = @import("Process.zig");
const constants = @import("constants");
const log = std.log.scoped(.agce);
