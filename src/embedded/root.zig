pub const Native = Embedded.Native;
pub const Process = @import("remote_client").Process;
pub const RemoteClient = @import("remote_client").RemoteClient;
pub const Size = ptypes.Size;
pub const Rect = ptypes.Rect;
pub const Pos = ptypes.Pos;

pub const EmbeddedHandle = opaque {
    fn cast(h: *EmbeddedHandle) *Embedded {
        return @ptrCast(@alignCast(h));
    }

    pub fn create(
        gpa: std.mem.Allocator,
        environ_map: *const std.process.Environ.Map,
        ptr: *anyopaque,
        native: Native,
        class: []const u8,
    ) !*EmbeddedHandle {
        return @ptrCast(
            try Embedded.create(gpa, environ_map, ptr, native, class),
        );
    }

    pub fn destroy(h: *EmbeddedHandle) void {
        h.cast().destroy();
    }

    pub fn poll(h: *EmbeddedHandle) void {
        h.cast().poll();
    }

    pub fn window_add(h: *EmbeddedHandle, new: *anyopaque, size: Size) !void {
        try h.cast().window_add(new, size);
    }

    pub fn window_update_size(h: *EmbeddedHandle, window_handle: *anyopaque, size: Size) void {
        const win = h.cast().window_from_handle(@ptrCast(window_handle)) orelse {
            log.err("Window does not exist {*}", .{window_handle});
            return;
        };
        win.size = size;
    }

    pub fn remote_client_create(h: *EmbeddedHandle) !*RemoteClient {
        return try h.cast().remote_client_create();
    }

    pub fn remote_client_destroy(h: *EmbeddedHandle, remote: *RemoteClient) void {
        h.cast().remote_client_destroy(remote);
    }

    pub fn process_init(
        h: *EmbeddedHandle,
        io: Io,
        gpa: std.mem.Allocator,
        argv: []const []const u8,
        environ_map: *const std.process.Environ.Map,
    ) !Process {
        return try .init(
            io,
            gpa,
            argv,
            environ_map,
            h.cast().com.socket_path(),
        );
    }

    pub fn remote_viewport_create(
        h: *EmbeddedHandle,
        remote: *RemoteClient,
        window_handle: *anyopaque,
        rect: Rect,
    ) !*RemoteViewportHandle {
        return @ptrCast(
            try h.cast().remote_viewport_create(
                remote,
                window_handle,
                rect,
            ),
        );
    }
};

pub const RemoteViewportHandle = opaque {
    fn cast(h: *RemoteViewportHandle) *RemoteViewport {
        return @ptrCast(@alignCast(h));
    }

    pub fn send_close(handle: *RemoteViewportHandle) !void {
        const rvp = handle.cast();
        const vp_key = switch (rvp.state) {
            .shown, .hidden => |key| key,
            .failed, .pending, .closed => return,
        };
        try rvp.embedded.connection.send_viewport_close(
            rvp.embedded.rt.io(),
            rvp.embedded.gpa,
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
            try rvp.embedded.connection.send_viewport_pos_set(
                rvp.embedded.rt.io(),
                rvp.embedded.gpa,
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
            try rvp.embedded.connection.send_viewport_size_set(
                rvp.embedded.rt.io(),
                rvp.embedded.gpa,
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

        try rvp.embedded.connection.send_viewport_display_state_set(
            rvp.embedded.rt.io(),
            rvp.embedded.gpa,
            .{ .viewport_key = vp_key, .state = s },
        );

        rvp.state = .from_display_state(s, vp_key);
    }
};

const std = @import("std");
const Io = std.Io;
const Embedded = @import("Embedded.zig");
const RemoteViewport = @import("RemoteViewport.zig");
const compositor = @import("compositor");
const zio = @import("zio");
const LocalConnection = @import("LocalConnection.zig");
const ptypes = @import("protocol").types;
const log = std.log.scoped(.agce_embedded);
