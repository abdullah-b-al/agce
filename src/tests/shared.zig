fn environ_map_create(src: std.builtin.SourceLocation) !std.process.Environ.Map {
    var environ_map = try testing.environ.createMap(testing.allocator);

    var buf: [constants.socket_max_path]u8 = undefined;
    const testing_path_len = try std.process.executableDirPath(
        testing.io,
        &buf,
    );

    const path = try std.fs.path.join(testing.allocator, &.{
        buf[0..testing_path_len],
        src.fn_name,
    });
    defer testing.allocator.free(path);

    try environ_map.put(constants.env_agce_socket_path, path);

    return environ_map;
}

pub const TestServer = struct {
    future: Io.Future(@typeInfo(@TypeOf(server_spawn)).@"fn".return_type.?),
    exit: *Io.Event,

    pub fn concurrent(src: std.builtin.SourceLocation) !TestServer {
        // Wait between tests to prevent race conditions in windows
        try testing.io.sleep(.fromSeconds(1), .awake);

        const exit = try testing.allocator.create(Io.Event);
        exit.* = .unset;

        const server = try testing.io.concurrent(server_spawn, .{ src, exit });

        return .{ .future = server, .exit = exit };
    }

    pub fn await(ctx: *TestServer) !void {
        ctx.exit.set(testing.io);
        defer testing.allocator.destroy(ctx.exit);

        try ctx.future.await(testing.io);
    }

    fn server_spawn(src: std.builtin.SourceLocation, exit: *Io.Event) !void {
        const gpa = testing.allocator;
        var environ_map = try environ_map_create(src);
        defer environ_map.deinit();

        const rt = try zio.Runtime.init(gpa, .{});
        defer rt.deinit();
        const io = rt.io();

        const ws: *WindowSystem = try .create(io, gpa, src.fn_name);
        defer ws.destroy();

        const server = try Server.create(io, &environ_map, gpa);
        defer server.destroy();

        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();

        while (!exit.isSet()) {
            _ = arena.reset(.{ .retain_with_limit = 1024 * 1024 });
            try tick(arena.allocator(), ws, server, .none);
        }
    }
};

pub fn client_init(src: std.builtin.SourceLocation) !*client.ClientHandle {
    var environ_map = try environ_map_create(src);
    defer environ_map.deinit();

    // wait for the server to spawn
    try testing.io.sleep(.fromMilliseconds(100), .awake);
    return try client.init(testing.io, testing.allocator, &environ_map);
}

pub fn render_cpu(vp: *client.ViewportHandle) !void {
    const frame = try vp.cpu_frame_begin();

    const r: u8 = 0xFF;
    const g: u8 = 0xFF;
    const b: u8 = 0xFF;
    const a: u8 = 0xFF;
    var i: usize = 0;
    while (i < frame.buffer.len) : (i += 4) {
        frame.buffer[i + 0] = @intCast(b); // B
        frame.buffer[i + 1] = @intCast(g); // G
        frame.buffer[i + 2] = @intCast(r); // R
        frame.buffer[i + 3] = @intCast(a); // A
    }

    vp.cpu_frame_end();
    try vp.cpu_frame_present();
}

pub fn render_gl(vp: *client.ViewportHandle) !void {
    const frame = try vp.gl_frame_begin();

    const fr = 0;
    const fg = 0;
    const fb = 1;
    const fa = 1;

    glad.glBindFramebuffer(glad.GL_FRAMEBUFFER, frame.fbo);
    glad.glViewport(0, 0, @intCast(frame.viewport_size.width), @intCast(frame.viewport_size.height));
    glad.glClearColor(fr, fg, fb, fa);
    glad.glClear(glad.GL_COLOR_BUFFER_BIT);

    vp.gl_frame_end();
    try vp.gl_frame_present();
}

const std = @import("std");
const Io = std.Io;
const testing = std.testing;

const client = @import("client");
const constants = @import("constants");
const glad = @import("glad");
const WindowSystem = @import("main").WindowSystem;
const Server = @import("main").Server;
const zio = @import("main").zio;
const tick = @import("main").tick;
