pub const Server = @import("server/Server.zig");
pub const Compositor = @import("Compositor.zig");
pub const zio = @import("zio");
pub const ClientResources = @import("ClientResources.zig");

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
        h.cast().window_focused_by_keyboard(key);
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

    pub fn tick(h: *CompositorHandle, poll_result: polling.Poll) !void {
        const com = h.cast();

        defer _ = com.tick_arena.reset(.{ .retain_with_limit = 1024 * 1024 });

        const server = com.server;
        const arena = com.tick_arena.allocator();

        const compositor_events = try server.process_incoming_messages(arena, poll_result.clients);

        com.events_handle(compositor_events);
        try com.present();

        com.dispatch();

        com.events_handle(com.deferred_events.items);
        com.deferred_events.clearRetainingCapacity();

        server.events_handle(com);

        if (poll_result.accept) {
            // FIXME: In windows, we must accept all connections as resetting the accept event
            // will result in ignoring new clients
            if (server.server.accept(.{})) |stream| {
                try server.handle_event(.{ .unknown_client_connected = stream });
            } else |err| {
                log.err("Accept client failed {}", .{err});
            }
        }

        server.close_clients_marked_with_error();
        server.clients.remove_closed_clients_known_or_local();
        server.clients.remove_promoted_or_closed_unknown_clients();

        var i = com.resources.count();
        while (i > 0) {
            i -= 1;
            const client_uuid = com.resources.keys()[i];
            if (!server.clients.contains(client_uuid)) {
                com.client_disconnected(client_uuid);
            }
        }

        try com.resources.ensureTotalCapacity(com.gpa, server.clients.count());
        inline for (.{
            server.clients.known.keys(),
            server.clients.local.keys(),
        }) |keys| {
            for (keys) |uuid| {
                if (!com.resources.contains(uuid)) {
                    com.client_registered(uuid) catch |err| switch (err) {
                        error.OutOfMemory => unreachable,
                    };
                }
            }
        }

        com.flush(compositor_events);
    }

    pub fn poll(
        h: *CompositorHandle,
        timeout: Io.Timeout,
    ) error{ OutOfMemory, PollFailed, Timeout }!polling.Poll {
        std.debug.assert(timeout != .deadline);
        const com = h.cast();
        const server = com.server;
        const arena = com.tick_arena.allocator();

        return try polling.poll(arena, com, server, timeout);
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
const polling = @import("polling.zig");
