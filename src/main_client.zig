pub fn main(init: std.process.Init) !void {
    if (@import("builtin").os.tag == .windows) {
        // silence compile errors for now
        return;
    }

    var use_cpu = false;
    var use_gl = false;
    var iter = try init.minimal.args.iterateAllocator(init.gpa);
    defer iter.deinit();
    _ = iter.skip();
    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "use_cpu")) use_cpu = true;
        if (std.mem.eql(u8, arg, "use_gl")) use_gl = true;
    }

    if (!use_gl and !use_cpu) {
        std.log.err("Pass use_gl and/or use_cpu to pick the renderer", .{});
        std.process.exit(1);
    }

    var client: Client = try .init(init.io, init.gpa, init.environ_map);
    defer client.deinit();

    if (use_gl) {
        try client.init_gbm();
        try client.init_gl(3, 3);
    }

    const viewport_gl = if (use_gl) try client.viewport_create_gl(1280, 720) else null;
    const viewport_cpu = if (use_cpu) try client.viewport_create_cpu(1280, 720) else null;

    if (viewport_cpu) |cpu| {
        try client.window_create(cpu.id, cpu.width, cpu.height);
    }
    if (viewport_gl) |gl| {
        try client.window_create(gl.id, gl.width, gl.height);
    }

    var rand: std.Random.DefaultPrng = .init(0);
    const random = rand.random();
    var time = Io.Timestamp.now(init.io, .awake);
    var first_frame = true;
    while (true) {
        const timeout: Io.Timeout =
            .{ .duration = .{ .raw = .fromNanoseconds(1), .clock = .awake } };
        client.messages_poll_and_handle(timeout) catch |err| switch (err) {
            error.NoBuffers => {},
            else => |e| return e,
        };

        const should_render =
            time.untilNow(init.io, .awake).toMilliseconds() >= 1000 or
            first_frame;

        if (should_render) {
            if (viewport_cpu) |cpu| {
                try render_cpu(cpu, random);
            }

            if (viewport_gl) |gl| {
                try render_gpu(gl, random);
            }

            time = .now(init.io, .awake);
        }

        first_frame = false;
    }
}

fn render_cpu(vp: *ViewportCpu, random: std.Random) !void {
    const buffer = vp.get_buffer() orelse return;

    const r: u8 = random.int(u8);
    const g: u8 = random.int(u8);
    const b: u8 = random.int(u8);
    const a: u8 = 0xFF;
    std.log.info("Sent {x} {x} {x} {x} BufferID({})", .{ r, g, b, a, @intFromEnum(buffer.id) });
    var i: usize = 0;
    while (i < buffer.data.len) : (i += 4) {
        buffer.data[i + 0] = @intCast(b); // B
        buffer.data[i + 1] = @intCast(g); // G
        buffer.data[i + 2] = @intCast(r); // R
        buffer.data[i + 3] = @intCast(a); // A
    }

    try vp.buffer_present(buffer);
}

fn render_gpu(vp: *ViewportGL, random: std.Random) !void {
    const buffer = vp.get_buffer() orelse return;

    const fr = random.float(f32);
    const fg = random.float(f32);
    const fb = random.float(f32);
    const fa = 1;
    std.log.info("Sent {d:.3} {d:.3} {d:.3} {d:.3} BufferID({}) fbo({}) buffer({}x{}), viewport({}x{})", .{
        fr,
        fg,
        fb,
        fa,
        @intFromEnum(buffer.id),
        buffer.fbo,
        c_linux.gbm_bo_get_width(buffer.bo),
        c_linux.gbm_bo_get_height(buffer.bo),
        vp.width,
        vp.height,
    });

    glad.glBindFramebuffer(glad.GL_FRAMEBUFFER, buffer.fbo);
    glad.glViewport(0, 0, @intCast(vp.width), @intCast(vp.height));
    glad.glClearColor(fr, fg, fb, fa);
    glad.glClear(glad.GL_COLOR_BUFFER_BIT);

    try vp.end_frame(buffer);
    try vp.buffer_present(buffer);
}

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const Client = @import("client").Client;
const c_linux = @import("c_linux");
const glad = @import("glad");
const ViewportGL = @import("client").ViewportGL;
const ViewportCpu = @import("client").ViewportCpu;
