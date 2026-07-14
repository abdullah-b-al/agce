const viewport_id_cpu: protocol_types.ViewportID = @enumFromInt(1);
const viewport_id_gpu: protocol_types.ViewportID = @enumFromInt(2);

pub fn main(init: std.process.Init) !void {
    if (@import("builtin").os.tag == .windows) {
        // silence compile errors for now
        return;
    }

    const dri = try Io.Dir.openFileAbsolute(
        init.io,
        "/dev/dri/renderD128",
        .{ .mode = .read_write },
    );
    defer dri.close(init.io);

    const gbm_device = c_linux.gbm_create_device(dri.handle) orelse
        return error.CouldNotCreateGbmDevice;
    defer c_linux.gbm_device_destroy(gbm_device);

    const gl = try opengl.init_linux(gbm_device);
    try opengl.load_gl(gl);

    var viewport_gl: ViewportGL = try .init(gl, gbm_device, 1280, 720);

    var path_buf: [constants.socket_max_path]u8 = undefined;
    const path = utils.unix_address_path(init.environ_map, &path_buf);
    const address = try net.UnixAddress.init(path);

    const stream = try address.connect(init.io);
    defer stream.close(init.io);

    var viewport: Viewport = try .init(1280, 720);

    // cpu
    try client_to_server.message_send_json(init.io, init.gpa, stream, .{ .viewport_create_with_fds_cpu = .{ .id = viewport_id_cpu, .width = viewport.width, .height = viewport.height, .format = viewport.format, .fds = .{ .front = viewport.front_fd, .back = viewport.back_fd } } });
    try client_to_server.message_send_json(init.io, init.gpa, stream, .{ .window_create = .{ .viewport_id = viewport_id_cpu } });

    // gpu
    try client_to_server.message_send_json(init.io, init.gpa, stream, .{ .viewport_create_with_fds_gpu = .{ .id = viewport_id_gpu, .width = viewport_gl.width, .height = viewport_gl.height, .format = viewport_gl.format, .gbm_bo_modifier = viewport_gl.modifier, .fds = .{ .front = viewport_gl.front_buffer.get_fd(), .back = viewport_gl.back_buffer.get_fd() } } });
    try client_to_server.message_send_json(init.io, init.gpa, stream, .{ .window_create = .{ .viewport_id = viewport_id_gpu } });

    var rand: std.Random.DefaultPrng = .init(0);
    const random = rand.random();
    while (true) {
        try render_cpu(init.io, init.gpa, stream, &viewport, random);

        try render_gpu(init.io, init.gpa, stream, &viewport_gl, random);

        const timeout: Io.Timeout =
            .{ .duration = .{ .raw = .fromNanoseconds(1), .clock = .awake } };
        try handle_server_message_all(
            init.gpa,
            init.io,
            init.arena.allocator(),
            stream,
            timeout,
            &viewport,
            &viewport_gl,
            gl,
            gbm_device,
        );

        try init.io.sleep(.fromMilliseconds(1000), .awake);
    }
}

fn handle_server_message_all(
    gpa: std.mem.Allocator,
    io: Io,
    arena: std.mem.Allocator,
    stream: net.Stream,
    timeout: Io.Timeout,
    viewport: *Viewport,
    viewport_gl: *ViewportGL,
    gl_ctx: opengl.ContextLinux,
    gbm_device: *c_linux.struct_gbm_device,
) !void {
    while (true) {
        handle_server_message(
            gpa,
            io,
            arena,
            stream,
            timeout,
            viewport,
            viewport_gl,
            gl_ctx,
            gbm_device,
        ) catch |err| switch (err) {
            error.Timeout => return,
            else => |e| return e,
        };
    }
}
fn handle_server_message(
    gpa: std.mem.Allocator,
    io: Io,
    arena: std.mem.Allocator,
    stream: net.Stream,
    timeout: Io.Timeout,
    viewport: *Viewport,
    viewport_gl: *ViewportGL,
    gl_ctx: opengl.ContextLinux,
    gbm_device: *c_linux.struct_gbm_device,
) !void {
    const message = try server_to_client.message_receive(
        io,
        arena,
        stream,
        timeout,
    ) orelse return error.Timeout;

    switch (message) {
        .viewport_resize => |resize| {
            if (resize.viewport_id == viewport_id_cpu) {
                try resize_cpu(io, gpa, stream, viewport, resize);
            } else if (resize.viewport_id == viewport_id_gpu) {
                try resize_gpu(io, gpa, stream, viewport_gl, gl_ctx, gbm_device, resize);
            } else {
                unreachable;
            }
        },
    }
}

fn resize_cpu(io: Io, gpa: std.mem.Allocator, stream: net.Stream, viewport: *Viewport, resize: protocol_types.ViewportResize) !void {
    std.debug.assert(resize.viewport_id == viewport_id_cpu);

    const new_viewport: Viewport = try .init(resize.width, resize.height);
    viewport.deinit();
    viewport.* = new_viewport;

    try client_to_server.message_send_json(
        io,
        gpa,
        stream,
        .{
            .viewport_create_with_fds_cpu = .{
                .id = viewport_id_cpu,
                .width = viewport.width,
                .height = viewport.height,
                .format = viewport.format,
                .fds = .{
                    .front = viewport.front_fd,
                    .back = viewport.back_fd,
                },
            },
        },
    );
}

fn resize_gpu(
    io: Io,
    gpa: std.mem.Allocator,
    stream: net.Stream,
    viewport: *ViewportGL,
    gl_ctx: opengl.ContextLinux,
    gbm_device: *c_linux.struct_gbm_device,
    resize: protocol_types.ViewportResize,
) !void {
    const new_viewport = try ViewportGL.init(gl_ctx, gbm_device, resize.width, resize.height);

    viewport.deinit(gl_ctx);
    viewport.* = new_viewport;

    try client_to_server.message_send_json(
        io,
        gpa,
        stream,
        .{
            .viewport_create_with_fds_gpu = .{
                .id = viewport_id_gpu,
                .width = viewport.width,
                .height = viewport.height,
                .format = viewport.format,
                .gbm_bo_modifier = viewport.modifier,
                .fds = .{
                    .front = viewport.front_buffer.get_fd(),
                    .back = viewport.back_buffer.get_fd(),
                },
            },
        },
    );
}

const ViewportGL = struct {
    width: u32,
    height: u32,
    stride: u32,
    bpp: u8,
    format: protocol_types.ViewportFormat,
    modifier: u64,

    front_buffer: Buffer,
    back_buffer: Buffer,

    pub fn init(gl: opengl.ContextLinux, gbm_device: *c_linux.struct_gbm_device, width: u32, height: u32) !ViewportGL {
        const front_buffer = try Buffer.init(gl, gbm_device, width, height);
        const back_buffer = try Buffer.init(gl, gbm_device, width, height);
        const bytes = c_linux.gbm_bo_get_bpp(front_buffer.bo) / 8;
        std.debug.assert(bytes == 4);
        return .{
            .width = width,
            .height = height,
            .stride = c_linux.gbm_bo_get_stride(front_buffer.bo),
            .bpp = @intCast(bytes),
            .modifier = c_linux.gbm_bo_get_modifier(front_buffer.bo),
            .format = .argb8888,

            .front_buffer = front_buffer,
            .back_buffer = back_buffer,
        };
    }

    pub fn deinit(vp: *ViewportGL, gl: opengl.ContextLinux) void {
        vp.front_buffer.deinit(gl);
        vp.back_buffer.deinit(gl);
    }

    fn swap(vp: *ViewportGL) void {
        std.mem.swap(Buffer, &vp.back_buffer, &vp.front_buffer);
    }

    pub const Buffer = struct {
        bo: *c_linux.struct_gbm_bo,
        gbm_texture: opengl.GbmBackedTexture,
        fbo: glad.GLuint,

        pub fn init(gl: opengl.ContextLinux, gbm_device: *c_linux.struct_gbm_device, width: u32, height: u32) !Buffer {
            const bo = try gbm_bo_create(gbm_device, width, height);
            const gbm_texture = try opengl.egl_image_from_gbm_bo(gl, bo);
            const fbo = try opengl.fbo_gen(gbm_texture.texture);

            return .{ .bo = bo, .gbm_texture = gbm_texture, .fbo = fbo };
        }

        pub fn deinit(buffer: *Buffer, gl: opengl.ContextLinux) void {
            glad.glDeleteTextures(1, &buffer.gbm_texture.texture);
            glad.glDeleteFramebuffers(1, &buffer.fbo);
            _ = glad.eglDestroyImageKHR(gl.egl_display, buffer.gbm_texture.image);
            c_linux.gbm_bo_destroy(buffer.bo);
        }

        pub fn get_fd(buffer: Buffer) c_int {
            return c_linux.gbm_bo_get_fd(buffer.bo);
        }
    };
};

fn gbm_bo_create(gbm_device: *c_linux.struct_gbm_device, width: u32, height: u32) !*c_linux.struct_gbm_bo {
    return c_linux.gbm_bo_create(
        gbm_device,
        width,
        height,
        c_linux.GBM_BO_FORMAT_ARGB8888,
        c_linux.GBM_BO_USE_RENDERING,
    ) orelse error.FailedToGbmBoCreate;
}

const Viewport = struct {
    width: u32,
    height: u32,
    format: protocol_types.ViewportFormat,

    front_fd: c_int,
    back_fd: c_int,
    front_buffer: []align(std.heap.page_size_min) u8,
    back_buffer: []align(std.heap.page_size_min) u8,

    pub fn init(width: u32, height: u32) !Viewport {
        const format: protocol_types.ViewportFormat = .argb8888;
        const s = width * height * format.bytes_per_pixel();
        const front_fd, const front_buffer = try create_fd(s);
        const back_fd, const back_buffer = try create_fd(s);

        return .{
            .width = width,
            .height = height,
            .format = format,

            .front_fd = front_fd,
            .back_fd = back_fd,

            .front_buffer = front_buffer,
            .back_buffer = back_buffer,
        };
    }

    pub fn deinit(vp: *Viewport) void {
        std.posix.munmap(vp.front_buffer);
        std.posix.munmap(vp.back_buffer);
        _ = std.os.linux.close(vp.front_fd);
        _ = std.os.linux.close(vp.back_fd);
    }

    fn swap(vp: *Viewport) void {
        std.mem.swap([]align(std.heap.page_size_min) u8, &vp.front_buffer, &vp.back_buffer);
        std.mem.swap(c_int, &vp.front_fd, &vp.back_fd);
    }
};

fn create_fd(size: usize) !struct { c_int, []align(std.heap.page_size_min) u8 } {
    const fd = try std.posix.memfd_create("agce-buffer", 0);
    if (std.posix.errno(std.posix.system.ftruncate(fd, @intCast(size))) != .SUCCESS) return error.FtruncateFailed;
    const buffer = try std.posix.mmap(
        null,
        size,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .SHARED },
        fd,
        0,
    );

    return .{ fd, buffer };
}

fn render_cpu(io: Io, gpa: std.mem.Allocator, stream: net.Stream, viewport: *Viewport, random: std.Random) !void {
    const r: u8 = random.int(u8);
    const g: u8 = random.int(u8);
    const b: u8 = random.int(u8);
    const a: u8 = 0xFF;
    std.log.info("Sent {x} {x} {x} {x}", .{ r, g, b, a });
    var i: usize = 0;
    while (i < viewport.back_buffer.len) : (i += 4) {
        viewport.back_buffer[i + 0] = @intCast(b); // B
        viewport.back_buffer[i + 1] = @intCast(g); // G
        viewport.back_buffer[i + 2] = @intCast(r); // R
        viewport.back_buffer[i + 3] = @intCast(a); // A
    }
    try client_to_server.message_send_json(io, gpa, stream, .{ .viewport_buffers_swap = .{
        .viewport_id = viewport_id_cpu,
    } });
    viewport.swap();
}

fn render_gpu(io: Io, gpa: std.mem.Allocator, stream: net.Stream, viewport_gl: *ViewportGL, random: std.Random) !void {
    const fr = random.float(f32);
    const fg = random.float(f32);
    const fb = random.float(f32);
    const fa = 1;
    std.log.info("Sent {d} {d} {d} {d}", .{ fr, fg, fb, fa });
    glad.glBindFramebuffer(glad.GL_FRAMEBUFFER, viewport_gl.back_buffer.fbo);
    glad.glViewport(0, 0, @intCast(viewport_gl.width), @intCast(viewport_gl.height));
    glad.glClearColor(fr, fg, fb, fa);
    glad.glClear(glad.GL_COLOR_BUFFER_BIT);
    glad.glFinish();
    try client_to_server.message_send_json(io, gpa, stream, .{ .viewport_buffers_swap = .{
        .viewport_id = viewport_id_gpu,
    } });
    viewport_gl.swap();
}

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const constants = @import("constants.zig");
const utils = @import("server/utils.zig");
const client_to_server = @import("protocol/client_to_server.zig");
const server_to_client = @import("protocol/server_to_client.zig");
const common = @import("protocol/common.zig");
const protocol_types = @import("protocol/types.zig");
const c_linux = @import("c_linux");
const opengl = @import("opengl.zig");
const glad = @import("glad");
