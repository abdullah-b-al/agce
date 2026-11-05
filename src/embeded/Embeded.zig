const Embeded = @This();

gpa: std.mem.Allocator,
rt: *zio.Runtime,

registered: bool,

windows: std.array_hash_map.Auto(WindowID, Window),

com: *compositor.CompositorHandle,
tick_thread_handle: zio.JoinHandle(void),
tick_thread_exit: *Io.Event,

remote_clients: std.ArrayList(*RemoteClient),

connection: LocalConnection,

pub fn create(
    gpa: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    ptr: *anyopaque,
    native: Native,
    class: []const u8,
) !*Embeded {
    const em = try gpa.create(Embeded);
    errdefer gpa.destroy(em);

    const exit_event = try gpa.create(Io.Event);
    errdefer gpa.destroy(exit_event);
    exit_event.* = .unset;

    const rt = try zio.Runtime.init(gpa, .{
        .executors = .exact(2),
        .enable_main_executor = true,
    });
    errdefer rt.deinit();
    const io = rt.io();

    const com = switch (native) {
        .wayland_display => try compositor.CompositorHandle.create_wayland(@ptrCast(ptr), .{
            .io = io,
            .gpa = gpa,
            .environ_map = environ_map,
            .class = class,
            .muxi = .{
                .ptr = em,
                .vtable = &.{
                    .window_handle_for_viewport = mux_interface.window_handle_for_viewport,
                    .window_id_from_handle = mux_interface.window_id_from_handle,
                    .window_handle_from_id = mux_interface.window_handle_from_id,
                    .window_size = mux_interface.window_size,
                },
            },
            .socket_owner = .{ .embeded = class },
        }),
    };
    errdefer com.destroy();

    const thread_handle = try rt.spawnInto(.{ .executor = 1 }, tick_thread, .{ com, exit_event });
    errdefer exit_event.set(io);

    const stream = try com.connect_local();
    em.* = .{
        .gpa = gpa,
        .com = com,
        .registered = false,
        .rt = rt,
        .windows = .empty,
        .remote_clients = .empty,
        .connection = .{ .uuid = .new(io), .stream = stream, .format = .json },

        .tick_thread_handle = thread_handle,
        .tick_thread_exit = exit_event,
    };

    try em.connection.send_register_local(io, gpa);

    // TODO: Add a timeout and handle it
    while (!em.registered) {
        em.poll();
    }

    return em;
}

pub fn destroy(em: *Embeded) void {
    em.tick_thread_exit.set(em.rt.io());
    em.connection.send_wake_up(em.rt.io(), em.gpa) catch {
        // TODO: Figure out a way to not return an error
        return;
    };

    em.tick_thread_handle.join();
    em.com.destroy();
    em.connection.stream.close();
    em.rt.deinit();

    for (em.remote_clients.items) |ptr| em.gpa.destroy(ptr);

    em.remote_clients.deinit(em.gpa);
    em.windows.deinit(em.gpa);

    em.gpa.destroy(em.tick_thread_exit);
    em.gpa.destroy(em);
}

pub fn poll(em: *Embeded) void {
    var arena: std.heap.ArenaAllocator = .init(em.gpa);
    defer arena.deinit();

    var reader_buffer: [4096]u8 = undefined;
    var reader = em.connection.stream.reader(&reader_buffer);
    reader.setTimeout(.fromNanoseconds(0));

    while (true) {
        const message = em.connection.receive_with_reader(arena.allocator(), &reader.interface) catch |err|
            switch (err) {
                error.OutOfMemory,
                error.EndOfStream,
                => return,
                error.ReadFailed => switch (reader.err.?) {
                    error.Timeout => return,

                    else => |e| {
                        // TODO: Handle errors
                        log.err("Poll(): {}", .{e});
                        continue;
                    },
                },

                error.Overflow,
                error.InvalidCharacter,
                error.HeaderInvalidLen,
                error.HeaderInvalidFormat,
                error.HeaderInvalidMessageTag,
                error.HeaderWithoutPayload,
                error.UnexpectedToken,
                error.InvalidNumber,
                error.InvalidEnumTag,
                error.DuplicateField,
                error.UnknownField,
                error.MissingField,
                error.LengthMismatch,
                error.SyntaxError,
                error.UnexpectedEndOfInput,
                error.BufferUnderrun,
                error.ValueTooLong,
                => |e| {
                    log.err("Poll(): {}", .{e});
                    continue;
                },
            };

        switch (message) {
            .registered => em.registered = true,
            .client_registered => |m| {
                for (em.remote_clients.items) |remote| {
                    if (remote.uuid == m.client_uuid) {
                        remote.connected();
                    }
                }
            },
            .client_disconnected => |m| {
                for (em.remote_clients.items) |remote| {
                    if (remote.uuid == m.client_uuid) {
                        remote.disconnected();
                    }
                }
            },
            else => {},
        }
    }
}

pub fn remote_client_create(em: *Embeded) !*RemoteClient {
    try em.remote_clients.ensureUnusedCapacity(em.gpa, 1);
    const remote = try em.gpa.create(RemoteClient);

    remote.* = .init(em.rt.io());
    em.remote_clients.appendAssumeCapacity(remote);

    return remote;
}

pub fn remote_client_destroy(em: *Embeded, remote: *RemoteClient) void {
    for (em.remote_clients.items, 0..) |r, i| {
        if (r == remote) {
            _ = em.remote_clients.swapRemove(i);
            em.gpa.destroy(remote);
            return;
        }
    }
}

pub fn process_init(
    em: *Embeded,
    io: Io,
    gpa: std.mem.Allocator,
    argv: []const []const u8,
    environ_map: *const std.process.Environ.Map,
) !Process {
    return try .init(io, gpa, argv, environ_map, em.com.socket_path());
}

fn tick_thread(com: *compositor.CompositorHandle, exit: *Io.Event) void {
    while (!exit.isSet()) {
        const poll_result = com.poll(.none) catch |err| {
            log.err("tick_thread.poll() {}", .{err});
            continue;
        };

        com.tick(poll_result) catch |err| {
            log.err("tick_thread.tick() {}", .{err});
        };
    }
}

pub const Native = enum {
    wayland_display,
};

pub const Window = struct {
    handle: *Compositor.WindowHandle,
    size: ptypes.Size,
};

const mux_interface = struct {
    fn window_handle_for_viewport(_: *anyopaque, _: ptypes.ViewportKey, _: ptypes.Size) ?*Compositor.WindowHandle {
        @panic("TODO");
    }

    fn window_id_from_handle(_: *anyopaque, _: *Compositor.WindowHandle) ?WindowID {
        @panic("TODO");
    }

    fn window_handle_from_id(ptr: *anyopaque, id: WindowID) ?*Compositor.WindowHandle {
        const em: *Embeded = @ptrCast(@alignCast(ptr));
        const win = em.windows.get(id) orelse return null;
        return win.handle;
    }

    fn window_size(ptr: *anyopaque, id: WindowID) ?ptypes.Size {
        const em: *Embeded = @ptrCast(@alignCast(ptr));
        const win = em.windows.get(id) orelse return null;
        return win.size;
    }
};

const std = @import("std");
const Io = std.Io;
const compositor = @import("compositor");
const Compositor = compositor.Compositor;
const ptypes = @import("protocol").types;
const WindowID = Compositor.WindowID;
const zio = @import("zio");
const LocalConnection = @import("LocalConnection.zig");
const log = std.log.scoped(.agce_embeded);
const RemoteClient = @import("remote_client").RemoteClient;
const Process = @import("remote_client").Process;
