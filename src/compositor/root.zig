pub const Server = @import("server/Server.zig");
pub const Compositor = @import("Compositor.zig");
pub const zio = @import("zio");
pub const ClientResources = @import("ClientResources.zig");

pub const Tick = struct {
    com: *CompositorHandle,
    arena: std.heap.ArenaAllocator,

    pub fn init(com: *CompositorHandle) Tick {
        return .{ .com = com, .arena = .init(com.cast().gpa) };
    }

    pub fn deinit(state: *Tick) void {
        state.arena.deinit();
    }
};

pub fn tick(state: *Tick, poll_result: Poll) !void {
    defer _ = state.arena.reset(.{ .retain_with_limit = 1024 * 1024 });

    const com = state.com.cast();
    const server = com.server;
    const arena = state.arena.allocator();

    const messages = try server.messages_receive(arena, poll_result.clients);
    const ws_events = try server.messages_handle(arena, messages);
    com.events_handle(ws_events);
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

    server.close_marked_clients();
    server.clients.remove_closed_known_clients();
    server.clients.remove_promoted_or_closed_unknown_clients();

    var i = com.resources.count();
    while (i > 0) {
        i -= 1;
        const client_id = com.resources.keys()[i];
        if (!server.clients.known.contains(client_id)) {
            com.client_disconnected(client_id);
        }
    }

    try com.resources.ensureTotalCapacity(com.gpa, server.clients.count());
    for (server.clients.known.keys()) |client_id| {
        if (!com.resources.contains(client_id)) {
            com.client_registered(client_id) catch |err| switch (err) {
                error.OutOfMemory => unreachable,
            };
        }
    }
}

const Poll = struct {
    dispatch: bool,
    accept: bool,
    clients: []Server.MessageSource,
};

pub fn poll(
    arena: std.mem.Allocator,
    h: *CompositorHandle,
    timeout: Io.Timeout,
) error{ OutOfMemory, PollFailed, Timeout }!Poll {
    std.debug.assert(timeout != .deadline);
    const com = h.cast();
    const server = com.server;

    return switch (os) {
        .linux => try poll_linux(arena, com, server, timeout),
        .windows => try poll_windows(arena, com, server, timeout),
        else => comptime unreachable,
    };
}

fn poll_windows(
    arena: std.mem.Allocator,
    _: *Compositor,
    server: *const Server,
    timeout: Io.Timeout,
) !Poll {
    const events_len = server.clients.count() + 1;
    const events = try arena.alloc(*anyopaque, events_len);
    var clients: std.ArrayList(Server.MessageSource) = try .initCapacity(arena, server.clients.count());
    var i: usize = 0;

    const server_socket_i = i;
    {
        events[i] = server.win32_event_handle.handle;
        i += 1;
    }

    const known_i = i;
    for (server.clients.known.values()) |c| {
        events[i] = c.connection.win32_event_handle.handle;
        i += 1;
    }

    const unknown_i = i;
    for (server.clients.unknown.items) |c| {
        events[i] = c.connection.win32_event_handle.handle;
        i += 1;
    }

    std.debug.assert(i == events.len);

    const to: u32 = switch (timeout) {
        .deadline => unreachable,
        .duration => |d| @intCast(d.raw.toMilliseconds()),
        .none => win32_programming.INFINITE,
    };

    const result = win32_win.MsgWaitForMultipleObjectsEx(
        @intCast(events.len),
        events.ptr,
        to,
        win32_win.QS_ALLINPUT,
        win32_win.MWMO_INPUTAVAILABLE,
    );

    const WAIT_OBJECT_0: u32 = @intFromEnum(win32_foundation.WAIT_OBJECT_0);
    const signaled: enum { socket, window } =
        if (result >= WAIT_OBJECT_0 and result < WAIT_OBJECT_0 + events.len)
            .socket
        else if (result == WAIT_OBJECT_0 + events.len)
            .window
        else if (result == @intFromEnum(win32_foundation.WAIT_TIMEOUT))
            return error.Timeout
        else if (result == @intFromEnum(win32_foundation.WAIT_FAILED)) {
            const err = win32_foundation.GetLastError();
            log.err("Wait failed {}", .{err});
            return error.PollFailed;
        } else @panic("Unknown value");

    switch (signaled) {
        .socket => {
            for (server.clients.known.values(), 0..) |client, ci| {
                const event = events[known_i + ci];
                if (@intFromEnum(win32_threading.WaitForSingleObject(event, 0)) == WAIT_OBJECT_0) {
                    clients.appendAssumeCapacity(.{ .known = client.id });
                    std.debug.assert(
                        win_sock.WSAResetEvent(event) == @intFromEnum(std.os.windows.BOOL.TRUE),
                    );
                }
            }

            for (server.clients.unknown.items, 0..) |_, ci| {
                const event = events[unknown_i + ci];
                if (@intFromEnum(win32_threading.WaitForSingleObject(event, 0)) == WAIT_OBJECT_0) {
                    clients.appendAssumeCapacity(.{ .unknown = ci });
                    std.debug.assert(
                        win_sock.WSAResetEvent(event) == @intFromEnum(std.os.windows.BOOL.TRUE),
                    );
                }
            }

            const accept = blk: {
                const event = events[server_socket_i];
                const accept = @intFromEnum(win32_threading.WaitForSingleObject(event, 0)) == WAIT_OBJECT_0;
                if (accept) {
                    std.debug.assert(
                        win_sock.WSAResetEvent(event) == @intFromEnum(std.os.windows.BOOL.TRUE),
                    );
                }
                break :blk accept;
            };

            return .{
                .clients = clients.items,
                .accept = accept,
                .dispatch = false,
            };
        },
        .window => {
            return .{ .clients = &.{}, .accept = false, .dispatch = true };
        },
    }
}

fn poll_linux(
    arena: std.mem.Allocator,
    com: *Compositor,
    server: *const Server,
    timeout: Io.Timeout,
) !Poll {
    std.debug.assert(timeout != .deadline);

    const Pollfd, const POLL = .{ std.os.linux.pollfd, std.os.linux.POLL };

    const fds_len = server.clients.count() + 2;
    const fds = try arena.alloc(Pollfd, fds_len);
    var clients: std.ArrayList(Server.MessageSource) = try .initCapacity(arena, server.clients.count());

    const events = POLL.IN | POLL.HUP;

    for (fds) |*fd| {
        fd.* = .{
            .fd = -1,
            .events = events,
            .revents = 0,
        };
    }

    var i: usize = 0;

    const display_i = i;
    switch (com.native_tag()) {
        .wayland => |tag| {
            const wl = tag.compositor(com);
            const display_fd = wl.display.getFd();
            fds[i].fd = display_fd;
            i += 1;
        },
        else => unreachable,
    }

    const server_socket_i = i;
    {
        fds[i].fd = server.server.socket.handle;
        i += 1;
    }

    const known_i = i;
    for (server.clients.known.values()) |c| {
        fds[i].fd = c.connection.stream.socket.handle;
        i += 1;
    }

    const unknown_i = i;
    for (server.clients.unknown.items) |c| {
        fds[i].fd = c.connection.stream.socket.handle;
        i += 1;
    }

    std.debug.assert(i == fds.len);

    const ms: i32 = switch (timeout) {
        .none => std.math.maxInt(i32),
        .duration => |d| @truncate(d.raw.toMilliseconds()),
        .deadline => unreachable,
    };
    const poll_result: isize = @bitCast(std.os.linux.poll(fds.ptr, fds.len, ms));

    if (poll_result == 0) return error.Timeout;

    if (poll_result < 0) {
        return error.PollFailed;
    }

    for (server.clients.known.values(), 0..) |client, ci| {
        const fd = fds[known_i + ci];
        if ((fd.revents & events) != 0) {
            clients.appendAssumeCapacity(.{ .known = client.id });
        }
    }

    for (server.clients.unknown.items, 0..) |_, ci| {
        const fd = fds[unknown_i + ci];
        if ((fd.revents & events) != 0) {
            clients.appendAssumeCapacity(.{ .unknown = ci });
        }
    }

    const compositor = (fds[display_i].revents & POLL.IN) != 0;
    const accept = (fds[server_socket_i].revents & POLL.IN) != 0;
    return .{
        .dispatch = compositor,
        .accept = accept,
        .clients = clients.items,
    };
}

pub const CompositorHandle = opaque {
    fn cast(ptr: *CompositorHandle) *Compositor {
        return @ptrCast(@alignCast(ptr));
    }

    pub fn create_wayland(
        io: Io,
        gpa: std.mem.Allocator,
        environ_map: *const std.process.Environ.Map,
        display: *cwl.Display,
        class: []const u8,
        muxi: ?Compositor.MuxInterface,
    ) !*CompositorHandle {
        const com: *Compositor = try .create_wayland(
            io,
            gpa,
            environ_map,
            display,
            class,
            muxi,
        );

        return @ptrCast(com);
    }

    pub fn create_win32(
        io: Io,
        gpa: std.mem.Allocator,
        environ_map: *const std.process.Environ.Map,
        instance: win32_foundation.HINSTANCE,
        class: []const u8,
        muxi: ?Compositor.MuxInterface,
    ) !*CompositorHandle {
        const com: *Compositor = try .create_win32(
            io,
            gpa,
            environ_map,
            instance,
            class,
            muxi,
        );

        return @ptrCast(com);
    }

    pub fn destroy(h: *CompositorHandle) void {
        h.cast().destroy();
    }

    pub fn resources(h: *CompositorHandle) []const ClientResources {
        return h.cast().resources.values();
    }

    pub fn native_tag(h: *CompositorHandle) Compositor.NativeTag {
        return h.cast().native_tag();
    }

    pub fn window_register(h: *CompositorHandle, win: Compositor.Window) error{OutOfMemory}!void {
        return h.cast().window_register(win);
    }

    pub fn window_update_size(h: *CompositorHandle, id: Compositor.WindowID, size: ptypes.Size) error{WindowNotRegistered}!void {
        try h.cast().window_update_size(id, size);
    }

    pub fn window_focused_by_keyboard(h: *CompositorHandle, key: Compositor.ViewportKey) void {
        h.cast().window_focused_by_keyboard(key);
    }

    pub fn viewport_resize(
        h: *CompositorHandle,
        key: Compositor.ViewportKey,
        size: ptypes.Size,
    ) error{OutOfMemory}!void {
        const com = h.cast();
        try com.server_events.ensure_unused_capacity(1);
        com.server_events.push_assume_capacity(.{
            .viewport_resize = .{
                .client_id = key.client_id,
                .payload = .{
                    .viewport_id = key.viewport_id,
                    .size = size,
                },
            },
        });
    }

    pub fn viewport_should_close(
        h: *CompositorHandle,
        key: Compositor.ViewportKey,
    ) error{OutOfMemory}!void {
        const com = h.cast();
        try com.deferred_events.append(com.gpa, .{
            .viewport_should_close = .{ .viewport_key = key },
        });
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
