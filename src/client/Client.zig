const Client = @This();

io: Io,
gpa: std.mem.Allocator,
environ_map: std.process.Environ.Map,
connection: ServerConnection,
registered: bool,

next_viewport_id: ptypes.ViewportID,
next_remote_viewport_id: ptypes.RemoteViewportID,

viewports: std.array_hash_map.Auto(ViewportID, *Viewport),
viewports_from_server: std.array_hash_map.Auto(ViewportID, ptypes.Size),
remote_viewports: std.array_hash_map.Auto(RemoteViewportID, *RemoteViewport),

processes: std.ArrayList(*Process),

messages_arena: std.heap.ArenaAllocator,

gbm: ?Gbm,
gl_context: ?opengl.ContextLinux,
d11_device: ?D11Device,

env: Env,

read_future: Io.Future(void),
messages_queue: *MessagesQueue,

pub fn init(
    io: Io,
    gpa: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
) !Client {
    var map = try environ_map.clone(gpa);
    errdefer map.deinit();

    const env: Env = .extract(&map);

    const unix_path = if (environ_map.get(constants.env_agce_socket_path)) |path| blk: {
        break :blk try gpa.dupe(u8, path);
    } else blk: {
        const runtime_path = try known_folders.getPath(io, gpa, environ_map, .runtime) orelse
            return error.CouldNotGetRuntimeDirPath;
        defer gpa.free(runtime_path);

        break :blk try std.fs.path.join(gpa, &.{
            runtime_path,
            constants.socket_dir_name,
            constants.socket_mux_file_name,
        });
    };
    defer gpa.free(unix_path);

    const address = try net.UnixAddress.init(unix_path);

    const queues: *MessagesQueue = try .create(gpa);
    errdefer queues.destroy(gpa);

    const stream = try address.connect(io);

    const future = try io.concurrent(
        read_thread,
        .{ io, gpa, stream, queues },
    );

    return .{
        .io = io,
        .gpa = gpa,
        .environ_map = map,
        .connection = .{
            .format = .json,
            .stream = stream,
        },
        .messages_queue = queues,
        .registered = false,
        .messages_arena = .init(gpa),
        .next_viewport_id = .first_for_client,
        .next_remote_viewport_id = .first,
        .viewports = .empty,
        .viewports_from_server = .empty,
        .remote_viewports = .empty,
        .processes = .empty,
        .gbm = null,
        .gl_context = null,
        .d11_device = null,

        .env = env,
        .read_future = future,
    };
}

pub fn deinit(client: *Client) void {
    client.read_future.cancel(client.io);

    for (client.processes.items) |p| {
        if (!p.deinited) {
            p.deinit();
            log.err("Process {*} leaked", .{p});
        }
        client.gpa.destroy(p);
    }

    for (client.viewports.values()) |vp| {
        if (!vp.deinited) {
            vp.deinit();
            log.err("{f} leaked", .{vp.id});
        }
        client.gpa.destroy(vp);
    }

    for (client.remote_viewports.values()) |rvp| {
        if (!rvp.deinited) {
            rvp.deinit();
            log.err("{f} leaked", .{rvp.id});
        }
        client.gpa.destroy(rvp);
    }

    if (constants.os_has_gbm) {
        if (client.gbm) |gbm| {
            gbm.dri.close(client.io);
            c_linux.gbm_device_destroy(gbm.device);
        }
    }

    if (constants.os_has_d3d) {
        if (client.d11_device) |ctx| ctx.deinit();
    }

    const containers = .{
        &client.viewports,
        &client.remote_viewports,
        &client.viewports_from_server,
        &client.processes,
    };

    inline for (containers) |container| {
        container.deinit(client.gpa);
    }

    client.messages_queue.destroy(client.gpa);
    client.environ_map.deinit();
    client.messages_arena.deinit();
    client.connection.stream.close(client.io);
}

pub fn init_gbm(client: *Client) !void {
    std.debug.assert(client.gbm == null);

    const dri = try Io.Dir.openFileAbsolute(
        client.io,
        "/dev/dri/renderD128",
        .{ .mode = .read_write },
    );

    const device = c_linux.gbm_create_device(dri.handle) orelse
        return error.CouldNotCreateGbmDevice;

    client.gbm = .{
        .dri = dri,
        .device = device,
    };
}

pub fn init_d3d11(client: *Client) !void {
    std.debug.assert(client.d11_device == null);
    if (!constants.os_has_d3d) {
        @panic("OS does not have d3d");
    }

    client.d11_device = try .init();
}

pub fn init_gl(client: *Client, major: c_int, minor: c_int) !void {
    std.debug.assert(client.gbm != null);
    const gbm = client.gbm.?;

    const gl = try opengl.init_linux(gbm.device, major, minor);
    try opengl.load_gl(gl);

    client.gl_context = gl;
}

pub fn poll(client: *Client, timeout: Io.Timeout) error{ Timeout, Canceled, OutOfMemory }!void {
    try client.messages_queue.messages_available.waitTimeout(client.io, timeout);
    client.messages_queue.messages_available.reset();

    try client.messages_queue.mutex.lock(client.io);
    defer client.messages_queue.mutex.unlock(client.io);

    const len = client.messages_queue.messages.items.len;

    try client.viewports_from_server.ensureUnusedCapacity(client.gpa, len);
    for (client.viewports.values()) |vp| {
        try vp.events.ensureUnusedCapacity(client.gpa, len);
        try vp.pending_buffers_cpu.ensureUnusedCapacity(client.gpa, len);
        try vp.pending_buffers_gbm_bo.ensureUnusedCapacity(client.gpa, len);
        try vp.pending_textures_d3d.ensureUnusedCapacity(client.gpa, len);
    }

    while (client.messages_queue.messages.pop()) |message| {
        client.poll_process_message(message);
    }
}

fn poll_process_message(client: *Client, message: server_to_client.MessagePayload) void {
    switch (message) {
        .registered => {
            client.registered = true;
        },
        .generated_client_full_id => |result| {
            const process = blk: for (client.processes.items) |process| {
                if (process.full_id == null) break :blk process;
            } else null;

            if (process) |p| {
                p.received_id(result.full_id);
            } else unreachable;
        },
        .client_registered => |e| {
            const process = blk: for (client.processes.items) |process| {
                const full_id = process.full_id orelse continue;
                if (full_id.id == e.client_id) break :blk process;
            } else null;

            if (process) |p| {
                p.client_connected();
                for (client.viewports.values()) |vp| {
                    vp.event_push(.wake_up);
                }
            }
        },
        .client_disconnected => |e| {
            for (client.processes.items) |p| {
                if (p.full_id) |c| if (c.id == e.client_id) {
                    p.status = .disconnected;
                };
            }

            for (client.viewports.values()) |vp| {
                vp.event_push(.wake_up);
            }
        },
        .viewport_create => |e| {

            // TODO: Maybe these shouldn't trust the server and should error instead of asserting
            std.debug.assert(
                @intFromEnum(e.viewport_id) >= @intFromEnum(ViewportID.first_for_server),
            );
            client.viewports_from_server.putAssumeCapacityNoClobber(
                e.viewport_id,
                e.size,
            );
        },

        .remote_viewport_embeded => |e| {
            const rvp = client.remote_viewports.get(e.remote_viewport_id) orelse return;
            switch (e.status) {
                .success => {
                    if (client.viewports.get(rvp.parent)) |vp| {
                        vp.event_push(.{ .remote_viewport_embeded = rvp.id });
                    }
                    rvp.state = .{ .shown = e.viewport_key };
                },
                .failure => rvp.state = .failed,
            }
            rvp.render_size = e.render_size;
        },
        .remote_viewport_display_state => |e| {
            const rvp = blk: for (client.remote_viewports.values()) |rvp| {
                const key = switch (rvp.state) {
                    .shown, .hidden => |key| key,
                    .closed, .pending, .failed => continue,
                };

                if (std.meta.eql(key, e.viewport_key)) {
                    break :blk rvp;
                }
            } else return;

            const key = switch (rvp.state) {
                .shown, .hidden => |key| key,
                .closed, .failed, .pending => return,
            };
            rvp.state = .from_display_state(e.state, key);
        },
        .remote_viewport_closed => |e| {
            const rvp = blk: for (client.remote_viewports.values()) |rvp| {
                const key = switch (rvp.state) {
                    .shown, .hidden => |key| key,
                    .closed, .pending, .failed => continue,
                };

                if (std.meta.eql(key, e.viewport_key)) {
                    break :blk rvp;
                }
            } else return;

            rvp.state = .closed;

            if (client.viewports.get(rvp.parent)) |vp| {
                vp.event_push(.{ .remote_viewport_closed = rvp.id });
            }
        },
        .viewport_resize => |e| {
            const vp = client.viewports.get(e.viewport_id) orelse return;
            vp.event_push(.{ .viewport_resize = e });
        },
        .viewport_close => |e| {
            const vp = client.viewports.get(e.viewport_id) orelse return;
            vp.event_push(.{ .viewport_close = e });
        },
        .viewport_display_state => |e| {
            const vp = client.viewports.get(e.viewport_id) orelse return;
            vp.event_push(.wake_up);
        },

        inline .mouse_enter,
        .mouse_leave,
        .mouse_motion,
        .mouse_button,
        .mouse_scroll,
        .keyboard_key,
        .keyboard_char,
        => |e, tag| {
            const vp = client.viewports.get(e.viewport_id) orelse return;
            const event = @unionInit(Event, @tagName(tag), e);
            vp.event_push(event);
        },

        .buffer_created_cpu => |e| {
            const vp = client.viewports.get(e.viewport_id) orelse return;
            vp.pending_buffers_cpu.appendAssumeCapacity(e);
        },
        .buffer_created_gbm_bo => |e| {
            const vp = client.viewports.get(e.viewport_id) orelse return;
            vp.pending_buffers_gbm_bo.appendAssumeCapacity(e);
        },

        .texture_created_d3d => |e, tag| {
            if (!constants.os_has_d3d) {
                @panic("Received invalid message on os " ++ @tagName(tag));
            }

            const vp = client.viewports.get(e.viewport_id) orelse return;
            vp.pending_textures_d3d.appendAssumeCapacity(e);
        },

        .viewport_created => |e| {
            const vp = client.viewports.get(e.viewport_id) orelse return;
            std.debug.assert(vp.status == .pending);
            switch (e.status) {
                .success => vp.status = .created,
                .failure => vp.status = .failed,
            }
        },

        .buffer_released => |e| {
            const vp = client.viewports.get(e.viewport_id) orelse return;
            switch (vp.renderer) {
                .d11 => {}, // relies on fences
                .gl => {}, // relies on timelines
                .cpu => |*r| r.buffer_released(e.buffer_id),
            }
        },

        .frame_render => |e| {
            const vp = client.viewports.get(e.viewport_id) orelse return;
            vp.refresh_cycle = e.refresh_cycle;
        },
    }
}

pub fn viewport_create(
    client: *Client,
    tag: Viewport.Renderer.Tag,
    size: ptypes.Size,
    throttle: bool,
) !*Viewport {
    const id = client.next_viewport_id.increment_for_client();

    const vp = switch (tag) {
        inline else => |t| try client.viewport_create_with_id(t, id, size, throttle),
    };

    return vp;
}

pub fn viewport_create_from_pending(
    client: *Client,
    tag: Viewport.Renderer.Tag,
    id: ViewportID,
    throttle: bool,
    size: ptypes.Size,
) !*Viewport {
    std.debug.assert(
        client.viewports_from_server.contains(id),
    );

    const vp = switch (tag) {
        inline else => |t| try client.viewport_create_with_id(t, id, size, throttle),
    };

    _ = client.viewports_from_server.orderedRemove(id);

    return vp;
}

pub fn viewport_create_with_id(
    client: *Client,
    tag: Viewport.Renderer.Tag,
    id: ViewportID,
    requested_size: ptypes.Size,
    throttle: bool,
) !*Viewport {
    try client.viewports.ensureUnusedCapacity(client.gpa, 1);

    const vp = blk: {
        const renderer: Viewport.Renderer = switch (tag) {
            .gl => if (RendererGL == Viewport.LinuxRendererGL)
                .{ .gl = .init(client.gbm.?, client.gl_context.?) }
            else
                @panic("TODO"),
            .cpu => .{ .cpu = .init() },
            .d11 => .{ .d11 = .init() },
        };
        const vp = try client.gpa.create(Viewport);
        vp.* = .init(
            id,
            client,
            requested_size,
            .argb8888,
            throttle,
            renderer,
        );
        break :blk vp;
    };
    client.viewports.putAssumeCapacityNoClobber(vp.id, vp);

    errdefer {
        _ = client.viewports.orderedRemove(vp.id);
        vp.deinit();
        client.gpa.destroy(vp);
    }

    try client.send_viewport_create(id, requested_size);
    try vp.buffers_create(requested_size);

    while (vp.status == .pending) {
        try client.poll(.none);

        switch (vp.status) {
            .pending => continue,
            .created => break,
            .failed => return error.ViewportCreateFailed,
        }
    }

    return vp;
}

pub fn throttle_frames_if_enabled(client: *Client, vp: *Viewport) !void {
    if (!vp.throttle_frames) return;
    try throttle_frames(client, vp);
}

pub fn throttle_frames(client: *Client, vp: *Viewport) !void {
    std.debug.assert(vp.throttle_frames);

    while (vp.frame_number > vp.refresh_cycle) {
        try client.poll(.none);
    }
}

pub fn send_viewport_create(
    client: *Client,
    viewport_id: ViewportID,
    size: ptypes.Size,
) !void {
    const vp = client.viewports.get(viewport_id).?;

    const create_sync_timeline = blk: {
        break :blk switch (vp.renderer) {
            .gl => true,
            .cpu => false,
            .d11 => false, // TODO: Set to true
        };
    };

    try client.connection.send_viewport_create(client.io, client.gpa, .{
        .viewport_id = viewport_id,
        .create_sync_timeline = create_sync_timeline,
        .size = size,
        .format = vp.format,
    });
}

pub fn send_buffer_destroy(client: *Client, buffer_id: BufferID) !void {
    try client.connection.send_buffer_destroy(
        client.io,
        client.gpa,
        .{ .buffer_id = buffer_id },
    );
}

pub fn remote_viewport_embed(
    client: *Client,
    viewport_id: ViewportID,
    client_id_to_embed: ptypes.ClientID,
    rect: ptypes.Rect,
) !*RemoteViewport {
    try client.remote_viewports.ensureUnusedCapacity(client.gpa, 1);
    const rvp = try client.gpa.create(RemoteViewport);
    errdefer client.gpa.destroy(rvp);

    const id = client.next_remote_viewport_id.increment();
    rvp.* = .init(viewport_id, id, client, rect);

    client.remote_viewports.putAssumeCapacityNoClobber(id, rvp);

    try client.connection.send_remote_viewport_embed(
        client.io,
        client.gpa,
        .{
            .client_id_to_embed = client_id_to_embed,
            .embeder_viewport_id = viewport_id,
            .rect = rect,
            .remote_viewport_id = id,
        },
    );

    return rvp;
}

pub fn read_thread(
    io: Io,
    gpa: std.mem.Allocator,
    stream: net.Stream,
    queues: *Client.MessagesQueue,
) void {
    log.debug("Started read_thread", .{});
    defer log.debug("Exited read_thread", .{});

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    var reader_buffer: [4096]u8 = undefined;
    var reader = stream.reader(io, &reader_buffer);
    while (true) {
        _ = arena.reset(.{ .retain_with_limit = 1024 * 1024 }); // 1MB

        const message = switch (os) {
            .linux => ServerConnection.receive_linux(io, arena.allocator(), stream),
            .windows => blk: {
                const message = ServerConnection.receive_with_reader(
                    io,
                    arena.allocator(),
                    &reader.interface,
                ) catch |err| break :blk switch (err) {
                    error.ReadFailed => reader.err.?,
                    else => |e| break :blk e,
                };

                break :blk message;
            },
            else => comptime unreachable,
        } catch |err| switch (err) {
            error.EndOfStream, error.OutOfMemory => continue,

            error.Unexpected,
            error.ConnectionResetByPeer,
            error.Canceled,
            => return,

            else => |e| {
                std.log.err("Receive {}", .{e});
                continue;
            },
        };

        queues.mutex.lock(io) catch return;
        defer queues.mutex.unlock(io);

        queues.messages.ensureUnusedCapacity(gpa, 512) catch @panic("OOM");
        queues.messages.insertAssumeCapacity(0, message);
        queues.messages_available.set(io);
    }
}

pub const Gbm = if (!constants.os_has_gbm) void else struct {
    dri: Io.File,
    device: *c_linux.struct_gbm_device,
};

pub const D11Device = if (!constants.os_has_d3d) void else struct {
    device: *d11.ID3D11Device,
    device1: *d11.ID3D11Device1,
    device5: *d11.ID3D11Device5,

    context: *d11.ID3D11DeviceContext,
    context4: *d11.ID3D11DeviceContext4,

    pub fn init() !D11Device {
        const device, const context = blk: {
            var device: *d11.ID3D11Device = undefined;
            var context: *d11.ID3D11DeviceContext = undefined;
            var feature_level: d3d.D3D_FEATURE_LEVEL = undefined;

            const result = d11.D3D11CreateDevice(
                null,
                .HARDWARE,
                null,
                .{},
                null,
                0,
                d11.D3D11_SDK_VERSION,
                &device,
                &feature_level,
                &context,
            );

            if (result != win32_foundation.S_OK) {
                log.err("FailedToCreateD3D11Device: 0x{x}", .{result});
                return error.FailedToCreateD3D11Device;
            }

            break :blk .{ device, context };
        };

        const device1 = blk: {
            var device1: *d11.ID3D11Device1 = undefined;
            const result = device.IUnknown.QueryInterface(
                d11.IID_ID3D11Device1,
                @ptrCast(&device1),
            );
            if (result != win32_foundation.S_OK) {
                log.err("FailedToQueryD3D11Device1: 0x{x}", .{result});
                return error.FailedToQueryD3D11Device1;
            }
            break :blk device1;
        };

        const device5 = blk: {
            var device5: *d11.ID3D11Device5 = undefined;
            const result = device.IUnknown.QueryInterface(
                d11.IID_ID3D11Device5,
                @ptrCast(&device5),
            );
            if (result != win32_foundation.S_OK) {
                log.err("FailedToQueryD3D11Device5: 0x{x}", .{result});
                return error.FailedToQueryD3D11Device5;
            }
            break :blk device5;
        };

        const context4 = blk: {
            var context4: *d11.ID3D11DeviceContext4 = undefined;
            const result = context.IUnknown.QueryInterface(
                d11.IID_ID3D11DeviceContext4,
                @ptrCast(&context4),
            );
            if (result != win32_foundation.S_OK) {
                log.err("FailedToQueryD3D11Context4: 0x{x}", .{result});
                return error.FailedToQueryD3D11Context4;
            }
            break :blk context4;
        };

        return .{
            .device = device,
            .context = context,
            .device1 = device1,
            .device5 = device5,
            .context4 = context4,
        };
    }

    pub fn deinit(ctx: D11Device) void {
        _ = ctx.device1.IUnknown.Release();
        _ = ctx.device5.IUnknown.Release();

        _ = ctx.context4.IUnknown.Release();
        _ = ctx.context.IUnknown.Release();
        _ = ctx.device.IUnknown.Release();
    }
};

pub const Event = union(enum) {
    viewport_resize: server_to_client.ViewportResize,
    viewport_close: server_to_client.ViewportClose,
    keyboard_char: server_to_client.KeyboardChar,
    keyboard_key: server_to_client.KeyboardKey,
    mouse_enter: server_to_client.MouseEnter,
    mouse_leave: server_to_client.MouseLeave,
    mouse_motion: server_to_client.MouseMotion,
    mouse_button: server_to_client.MouseButton,
    mouse_scroll: server_to_client.MouseScroll,
    remote_viewport_closed: RemoteViewportID,
    remote_viewport_embeded: RemoteViewportID,
    wake_up,
};

pub fn WithViewportID(comptime T: type) type {
    return struct {
        viewport_id: ViewportID,
        message: T,
    };
}

pub const CreateStatus = enum {
    created,
    pending,
    failed,
};

const Env = struct {
    expect_viewport: bool,
    client_full_id: ?ptypes.ClientFullID,

    pub fn extract(map: *std.process.Environ.Map) Env {
        defer {
            _ = map.swapRemove(constants.env_client_full_id);
            _ = map.swapRemove(constants.env_expect_viewport_key);
        }

        return .{
            .expect_viewport = if (map.get(constants.env_expect_viewport_key)) |value|
                std.mem.eql(u8, value, constants.env_expect_viewport_true)
            else
                false,

            .client_full_id = if (map.get(constants.env_client_full_id)) |value|
                .from_env_string(value)
            else
                null,
        };
    }
};

pub const MessagesQueue = struct {
    mutex: Io.Mutex,
    messages: std.ArrayList(server_to_client.MessagePayload),
    messages_available: Io.Event,

    pub fn create(gpa: std.mem.Allocator) !*MessagesQueue {
        const ptr = try gpa.create(MessagesQueue);
        ptr.* = .{
            .mutex = .init,
            .messages = .empty,
            .messages_available = .unset,
        };
        return ptr;
    }

    pub fn destroy(q: *MessagesQueue, gpa: std.mem.Allocator) void {
        q.messages.deinit(gpa);
        gpa.destroy(q);
    }
};

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const utils = @import("utils");
const constants = @import("constants");
const client_to_server = @import("protocol").client_to_server;
const server_to_client = @import("protocol").server_to_client;
const ptypes = @import("protocol").types;
const opengl = @import("opengl.zig");
const c_linux = @import("c_linux");
const glad = @import("glad");
const ViewportID = ptypes.ViewportID;
const RemoteViewportID = ptypes.RemoteViewportID;
const BufferID = ptypes.BufferID;
const log = std.log.scoped(.Client);
const Viewport = @import("Viewport.zig");
const RemoteViewport = @import("RemoteViewport.zig");
const RendererGL = Viewport.RendererGL;
const RendererCpu = Viewport.RendererCpu;
const Process = @import("Process.zig");
const ServerConnection = @import("ServerConnection.zig");
const os = @import("builtin").os.tag;
const d11 = @import("win32").graphics.direct3d11;
const d3d = @import("win32").graphics.direct3d;
const win32_foundation = @import("win32").foundation;
const known_folders = @import("known-folders");
