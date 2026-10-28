pub fn environ_map_create(src: std.builtin.SourceLocation, init: std.process.Init) !std.process.Environ.Map {
    var environ_map = try init.environ_map.clone(init.gpa);

    var buf: [constants.socket_max_path]u8 = undefined;
    const testing_path_len = try std.process.executableDirPath(
        init.io,
        &buf,
    );

    const path = try std.fs.path.join(init.gpa, &.{
        buf[0..testing_path_len],
        src.fn_name,
    });
    defer init.gpa.free(path);

    try environ_map.put(constants.env_agce_socket_path, path);

    return environ_map;
}

pub const TestServer = struct {
    future: Io.Future(@typeInfo(@TypeOf(server_spawn)).@"fn".return_type.?),
    exit: *Io.Event,

    pub fn concurrent(src: std.builtin.SourceLocation, init: std.process.Init) !TestServer {
        // Wait between tests to prevent race conditions in windows
        try init.io.sleep(.fromSeconds(1), .awake);

        const exit = try init.gpa.create(Io.Event);
        exit.* = .unset;

        const server = try init.io.concurrent(server_spawn, .{ src, exit, init });

        return .{ .future = server, .exit = exit };
    }

    pub fn await(ctx: *TestServer, init: std.process.Init) !void {
        ctx.exit.set(init.io);
        defer init.gpa.destroy(ctx.exit);

        try ctx.future.await(init.io);
    }

    fn server_spawn(src: std.builtin.SourceLocation, exit: *Io.Event, init: std.process.Init) !void {
        const gpa = init.gpa;
        var environ_map = try environ_map_create(src, init);
        defer environ_map.deinit();

        const rt = try zio.Runtime.init(gpa, .{});
        defer rt.deinit();
        const io = rt.io();

        const ws: *WindowSystem = try .create(io, gpa, &environ_map, src.fn_name);
        defer ws.destroy();

        var state: Tick = .init(ws);
        defer state.deinit();

        while (!exit.isSet()) {
            tick(
                &state,
                .{ .duration = .{ .raw = .fromMilliseconds(100), .clock = .awake } },
            ) catch |err| switch (err) {
                error.Timeout => {},
                else => |e| return e,
            };
        }
    }
};

pub fn client_init(src: std.builtin.SourceLocation, init: std.process.Init) !*client.ClientHandle {
    var environ_map = try environ_map_create(src, init);
    defer environ_map.deinit();

    // wait for the server to spawn
    try init.io.sleep(.fromMilliseconds(100), .awake);
    return try client.init(init.io, init.gpa, &environ_map);
}

pub fn render_cpu(vp: *client.ViewportHandle, color: u32) !void {
    const frame = try vp.cpu_buffer_get();

    const ptr: [*]u32 = @ptrCast(@alignCast(frame.buffer.ptr));
    const buffer: []u32 = ptr[0 .. frame.buffer.len / frame.bytes_per_pixel];

    const a: u32 = 0xFF_00_00_00;
    const r: u32 = color & 0xFF_00_00;
    const g: u32 = color & 0x00_FF_00;
    const b: u32 = color & 0x00_00_FF;
    for (buffer) |*p| {
        p.* = a | r | g | b;
    }

    try vp.cpu_present();
}

pub fn render_gl(vp: *client.ViewportHandle) !void {
    const frame = try vp.gl_buffer_get();

    const fr = 0;
    const fg = 0;
    const fb = 1;
    const fa = 1;

    glad.glBindFramebuffer(glad.GL_FRAMEBUFFER, frame.fbo);
    glad.glViewport(0, 0, @intCast(frame.viewport_size.width), @intCast(frame.viewport_size.height));
    glad.glClearColor(fr, fg, fb, fa);
    glad.glClear(glad.GL_COLOR_BUFFER_BIT);

    try vp.gl_present();
}

const std = @import("std");
const Io = std.Io;
const testing = std.testing;

const client = @import("client");
const constants = @import("constants");
const glad = @import("glad");
const Tick = @import("window_system").Tick;
const WindowSystem = @import("window_system").WindowSystem;
const Server = @import("window_system").Server;
const zio = @import("window_system").zio;
const tick = @import("window_system").tick;
