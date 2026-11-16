pub const Server = @import("server/Server.zig");
pub const Compositor = @import("Compositor.zig");
pub const zio = @import("zio");
pub const ClientResources = @import("ClientResources.zig");
pub const polling = @import("polling.zig");

pub const CompositorHandle = opaque {
    fn cast(ptr: *CompositorHandle) *Compositor {
        return @ptrCast(@alignCast(ptr));
    }

    pub fn create_wayland(
        display: *cwl.Display,
        args: Compositor.CreateArgs,
    ) !*CompositorHandle {
        const com: *Compositor = try .create_wayland(display, args);

        return @ptrCast(com);
    }

    pub fn create_win32(
        instance: win32_foundation.HINSTANCE,
        args: Compositor.CreateArgs,
    ) !*CompositorHandle {
        const com: *Compositor = try .create_win32(instance, args);

        return @ptrCast(com);
    }

    pub fn destroy(h: *CompositorHandle) void {
        h.cast().destroy();
    }

    pub fn socket_path(h: *CompositorHandle) []const u8 {
        return h.cast().server.unix_path;
    }

    pub fn io_queue(h: *CompositorHandle) *Io.Queue(Compositor.Event) {
        return h.cast().server.io_queue;
    }

    pub fn resources(h: *CompositorHandle) []const ClientResources {
        return h.cast().resources.values();
    }

    pub fn native_tag(h: *CompositorHandle) Compositor.NativeTag {
        return h.cast().native_tag();
    }

    pub fn window_focused_by_keyboard(h: *CompositorHandle, key: ptypes.ViewportKey) void {
        const com = h.cast();
        if (com.input_focus_keyboard == null) {
            com.deferred_events.append(
                com.gpa,
                .{ .keyboard_enter = .{ .viewport_key = key } },
            ) catch return;
        }
    }

    pub fn key_of_focused_viewport_keyboard(h: *CompositorHandle) ?ptypes.ViewportKey {
        return h.cast().input_focus_keyboard;
    }

    pub fn native_handle_from_viewport_key(h: *CompositorHandle, key: ptypes.ViewportKey) ?*anyopaque {
        const com = h.cast();
        const vp = com.viewport_from_key(key) orelse return null;
        return switch (vp.native_tag()) {
            .wayland => |tag| @ptrCast(tag.viewport(vp).surface),
            .win32 => |tag| @ptrCast(tag.viewport(vp).child_window_handle),
        };
    }

    pub fn connect_local(h: *CompositorHandle) !zio.net.Stream {
        return try h.cast().server.connect_local();
    }

    pub fn viewport_resize(
        h: *CompositorHandle,
        key: ptypes.ViewportKey,
        size: ptypes.Size,
    ) error{OutOfMemory}!void {
        const com = h.cast();
        try com.server_events.ensure_unused_capacity(1);
        com.server_events.push_assume_capacity(.{
            .viewport_resize = .{
                .client_uuid = key.client_uuid,
                .payload = .{
                    .viewport_id = key.viewport_id,
                    .size = size,
                },
            },
        });
    }

    pub fn viewport_should_close(
        h: *CompositorHandle,
        key: ptypes.ViewportKey,
    ) error{OutOfMemory}!void {
        const com = h.cast();
        try com.deferred_events.append(com.gpa, .{
            .viewport_should_close = .{ .viewport_key = key },
        });
    }

    pub fn tick(h: *CompositorHandle, poll_result: polling.Poll) error{OutOfMemory}!void {
        const com = h.cast();

        var oom = false;
        tick_inner(com, poll_result) catch |err| switch (err) {
            error.OutOfMemory => oom = true,
        };

        const server = com.server;
        server.close_clients_marked_with_error();
        server.clients.remove_closed_clients(server.gpa);

        var i = com.resources.count();
        while (i > 0) {
            i -= 1;
            const client_uuid = com.resources.keys()[i];
            if (!server.clients.contains(client_uuid)) {
                com.client_disconnected(client_uuid);
            }
        }

        if (com.resources.ensureTotalCapacity(com.gpa, server.clients.count())) |_| {
            for (server.clients.list.items) |client| {
                const uuid = client.uuid() orelse continue;
                if (!com.resources.contains(uuid)) {
                    com.client_registered(uuid) catch |err| switch (err) {
                        error.OutOfMemory => unreachable,
                    };
                }
            }
        } else |_| {}

        if (oom) return error.OutOfMemory;
    }

    fn tick_inner(com: *Compositor, poll_result: polling.Poll) error{OutOfMemory}!void {
        const server = com.server;

        try server.process_incoming_messages();
        while (server.compositor_events.pop()) |event| {
            com.event_handle(event) catch |err| switch (err) {
                error.OutOfMemory => |e| {
                    server.compositor_events.appendAssumeCapacity(event);
                    return e;
                },

                error.MessageUnsupportedByOS,
                error.InvalidSize,
                error.ClientDoesNotExist,
                error.ViewportDoesNotExist,
                error.ClientDoesNotOwnViewport,
                error.InvalidPosition,
                error.ViewportHasNoWindow,
                => {
                    log.err("event_handle {}", .{err});
                },
            };
        }

        try com.present();

        com.dispatch();
        for (com.deferred_events.items) |event| {
            com.event_handle(event) catch |err| {
                log.err("event_handle {}", .{err});
            };
        }
        com.deferred_events.clearRetainingCapacity();

        server.events_handle(com);

        if (poll_result.accept) {
            server.accept() catch |err| {
                log.err("Accept client failed {}", .{err});
            };
        }

        com.flush();
    }

    pub fn poll(
        h: *CompositorHandle,
        timeout: Io.Timeout,
    ) error{ OutOfMemory, PollFailed, Timeout }!polling.Poll {
        std.debug.assert(timeout != .deadline);
        const com = h.cast();
        const server = com.server;

        return try polling.poll( com, server, timeout);
    }
};

const std = @import("std");
const Io = std.Io;
const log = std.log.scoped(.agce);
const cwl = @import("wayland").client.wl;
const win32_win = @import("win32").ui.windows_and_messaging;
const win32_foundation = @import("win32").foundation;
const win32_programming = @import("win32").system.windows_programming;
const win32_threading = @import("win32").system.threading;
const win_sock = @import("win32").networking.win_sock;
const os = @import("builtin").os.tag;
const ptypes = @import("protocol").types;
const ClientConnection = @import("server/ClientConnection.zig");
