pub fn main(init: std.process.Init) !void {
    if (@import("builtin").os.tag == .windows) {
        // silence compile errors for now
        return;
    }

    var use_cpu = false;
    var use_gl = false;
    var vsync = false;
    var iter = try init.minimal.args.iterateAllocator(init.gpa);
    defer iter.deinit();
    _ = iter.skip();
    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "use_cpu")) use_cpu = true;
        if (std.mem.eql(u8, arg, "use_gl")) use_gl = true;
        if (std.mem.eql(u8, arg, "vsync")) vsync = true;
    }

    if (!use_gl and !use_cpu) {
        std.log.err("Pass use_gl and/or use_cpu to pick the renderer", .{});
        std.process.exit(1);
    }

    const client = try api.init(init.io, init.gpa, init.environ_map);
    defer api.deinit(client);

    if (use_gl) {
        try api.init_opengl(client, 3, 3);
    }

    const viewport_gl = if (use_gl) try api.gl_viewport_create(client, 1280, 720, vsync) else null;
    const viewport_cpu = if (use_cpu) try api.cpu_viewport_create(client, 1280, 720) else null;

    if (viewport_cpu) |cpu| {
        const size = api.viewport_size(client, cpu.generic).?;
        try api.window_create(client, cpu.generic, size[0], size[1]);
    }
    if (viewport_gl) |gl| {
        const size = api.viewport_size(client, gl.generic).?;
        try api.window_create(client, gl.generic, size[0], size[1]);
    }

    var rand: std.Random.DefaultPrng = .init(0);
    const random = rand.random();
    var time_cpu = Io.Timestamp.now(init.io, .awake);
    var time_gpu = Io.Timestamp.now(init.io, .awake);
    var first_frame = true;
    while (true) {
        const timeout: Io.Timeout =
            .{ .duration = .{ .raw = .fromNanoseconds(1), .clock = .awake } };

        try api.poll(client, timeout);
        try api.update(client);

        const should_render_cpu =
            time_cpu.untilNow(init.io, .awake).toMilliseconds() >= 1000 or
            first_frame;

        const should_render_gpu =
            time_gpu.untilNow(init.io, .awake).toMilliseconds() >= 1000 or
            first_frame;

        if (should_render_cpu) {
            if (viewport_cpu) |cpu| {
                try render_cpu(client, cpu, random);
                time_cpu = .now(init.io, .awake);
            }
        }

        if (should_render_gpu) {
            if (viewport_gl) |gl| {
                try render_gpu(client, gl, random);
                time_gpu = .now(init.io, .awake);
            }
        }

        const exit_gpu = if (viewport_gl) |gl| !api.viewport_open(client, gl.generic) else true;
        const exit_cpu = if (viewport_cpu) |cpu| !api.viewport_open(client, cpu.generic) else true;
        if (exit_gpu and exit_cpu) {
            break;
        }

        first_frame = false;
    }
}

fn render_cpu(handle: *ClientHandle, vp: CpuViewportID, random: std.Random) !void {
    const buffer = api.cpu_frame_begin(handle, vp) orelse return;

    const r: u8 = random.int(u8);
    const g: u8 = random.int(u8);
    const b: u8 = random.int(u8);
    const a: u8 = 0xFF;
    std.log.info("Sent {x} {x} {x} {x}", .{ r, g, b, a });
    var i: usize = 0;
    while (i < buffer.len) : (i += 4) {
        buffer[i + 0] = @intCast(b); // B
        buffer[i + 1] = @intCast(g); // G
        buffer[i + 2] = @intCast(r); // R
        buffer[i + 3] = @intCast(a); // A
    }

    api.cpu_frame_end(handle, vp);
    try api.cpu_frame_present(handle, vp);
}

fn render_gpu(handle: *ClientHandle, vp: GlViewportID, random: std.Random) !void {
    const frame = try api.gl_frame_begin(handle, vp);

    const fr = random.float(f32);
    const fg = random.float(f32);
    const fb = random.float(f32);
    const fa = 1;
    std.log.info("Sent {d:.3} {d:.3} {d:.3} {d:.3} fbo({})", .{
        fr,
        fg,
        fb,
        fa,
        frame.fbo,
    });

    glad.glBindFramebuffer(glad.GL_FRAMEBUFFER, frame.fbo);
    glad.glViewport(0, 0, @intCast(frame.width), @intCast(frame.height));
    glad.glClearColor(fr, fg, fb, fa);
    glad.glClear(glad.GL_COLOR_BUFFER_BIT);

    api.gl_frame_end(handle, vp);
    try api.gl_frame_present(handle, vp);
}

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const api = @import("client");
const c_linux = @import("c_linux");
const glad = @import("glad");
const ViewportID = @import("client").ViewportID;
const GlViewportID = @import("client").GlViewportID;
const CpuViewportID = @import("client").CpuViewportID;
const ClientHandle = @import("client").ClientHandle;
