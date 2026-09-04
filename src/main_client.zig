pub fn main(init: std.process.Init) !void {
    if (@import("builtin").os.tag == .windows) {
        // silence compile errors for now
        return;
    }

    var use_cpu = false;
    var use_gl = false;
    var throttle_frames = false;
    var iter = try init.minimal.args.iterateAllocator(init.gpa);
    defer iter.deinit();
    _ = iter.skip();
    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "use_cpu")) use_cpu = true;
        if (std.mem.eql(u8, arg, "use_gl")) use_gl = true;
        if (std.mem.eql(u8, arg, "throttle_frames")) throttle_frames = true;
    }

    if (!use_gl and !use_cpu) {
        std.log.err("Pass use_gl and/or use_cpu to pick the renderer", .{});
        std.process.exit(1);
    }

    const handle = try api.init(init.io, init.gpa, init.environ_map);
    defer handle.deinit();

    if (use_gl) {
        try handle.init_opengl(3, 3);
    }

    const size: api.Size = .{ .width = 1280, .height = 720 };
    const viewport_gl: ?*api.ViewportHandle = if (use_gl) try handle.viewport_create(.gl, size, throttle_frames) else null;
    const viewport_cpu: ?*api.ViewportHandle = if (use_cpu) try handle.viewport_create(.cpu, size, throttle_frames) else null;

    var rand: std.Random.DefaultPrng = .init(0);
    const random = rand.random();
    var time_cpu = Io.Timestamp.now(init.io, .awake);
    var time_gpu = Io.Timestamp.now(init.io, .awake);
    var first_frame = true;
    while (true) {
        const timeout: Io.Timeout =
            .{ .duration = .{ .raw = .fromNanoseconds(1), .clock = .awake } };

        try handle.poll(timeout);
        try handle.update();

        const should_render_cpu =
            time_cpu.untilNow(init.io, .awake).toMilliseconds() >= 1000 or
            first_frame;

        const should_render_gpu =
            time_gpu.untilNow(init.io, .awake).toMilliseconds() >= 1000 or
            first_frame;

        if (should_render_cpu) {
            if (viewport_cpu) |cpu| {
                try render_cpu(cpu, random);
                time_cpu = .now(init.io, .awake);
            }
        }

        if (should_render_gpu) {
            if (viewport_gl) |gl| {
                try render_gpu(gl, random);
                time_gpu = .now(init.io, .awake);
            }
        }

        const exit_gpu = if (viewport_gl) |gl| gl.should_close() else true;
        const exit_cpu = if (viewport_cpu) |cpu| cpu.should_close() else true;
        if (exit_gpu and exit_cpu) {
            break;
        }

        first_frame = false;
    }
}

fn render_cpu(vp: *ViewportHandle, random: std.Random) !void {
    const frame = try vp.cpu_frame_begin();

    const r: u8 = random.int(u8);
    const g: u8 = random.int(u8);
    const b: u8 = random.int(u8);
    const a: u8 = 0xFF;
    std.log.info("Sent {x} {x} {x} {x}", .{ r, g, b, a });
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

fn render_gpu(vp: *ViewportHandle, random: std.Random) !void {
    const frame = try vp.gl_frame_begin();

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
    glad.glViewport(0, 0, @intCast(frame.viewport_size.width), @intCast(frame.viewport_size.height));
    glad.glClearColor(fr, fg, fb, fa);
    glad.glClear(glad.GL_COLOR_BUFFER_BIT);

    vp.gl_frame_end();
    try vp.gl_frame_present();
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
const ViewportHandle = @import("client").ViewportHandle;
