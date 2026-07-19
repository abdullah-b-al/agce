const viewport_id_cpu: protocol_types.ViewportID = @enumFromInt(1);
const viewport_id_gpu: protocol_types.ViewportID = @enumFromInt(2);

var next_buffer_id: protocol_types.BufferID = .first;

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

    const cpu_table = .{
        .{ .id = viewport.front.id, .fd = viewport.front.fd },
        .{ .id = viewport.back.id, .fd = viewport.back.fd },
    };
    inline for (cpu_table) |entry| {
        try client_to_server.message_send_json(
            init.io,
            init.gpa,
            stream,
            .{
                .buffer_create_cpu_with_fd = .{
                    .id = entry.id,
                    .width = viewport.width,
                    .height = viewport.height,
                    .format = viewport.format,
                    .fd = entry.fd,
                },
            },
        );
    }

    const gpu_table = .{
        .{ .id = viewport_gl.front_buffer.id, .fd = viewport_gl.front_buffer.get_fd() },
        .{ .id = viewport_gl.back_buffer.id, .fd = viewport_gl.back_buffer.get_fd() },
    };
    inline for (gpu_table) |entry| {
        try client_to_server.message_send_json(
            init.io,
            init.gpa,
            stream,
            .{
                .buffer_create_gpu_with_fd = .{
                    .id = entry.id,
                    .width = viewport.width,
                    .height = viewport.height,
                    .format = viewport.format,
                    .gbm_bo_modifier = viewport_gl.modifier,
                    .fd = entry.fd,
                },
            },
        );
    }

    try client_to_server.message_send_json(init.io, init.gpa, stream, .{ .window_create = .{
        .viewport_id = viewport_id_cpu,
        .width = viewport.width,
        .height = viewport.height,
    } });
    try client_to_server.message_send_json(init.io, init.gpa, stream, .{ .window_create = .{
        .viewport_id = viewport_id_gpu,
        .width = viewport_gl.width,
        .height = viewport_gl.height,
    } });

    var rand: std.Random.DefaultPrng = .init(0);
    const random = rand.random();
    var time = Io.Timestamp.now(init.io, .awake);
    var first_frame = true;
    while (true) {
        const should_render =
            time.untilNow(init.io, .awake).toMilliseconds() >= 1000 or
            first_frame;

        if (should_render) {
            if (viewport.back.released) {
                try render_cpu(init.io, init.gpa, stream, &viewport, random);
            }

            if (viewport_gl.back_buffer.released) {
                try render_gpu(init.io, init.gpa, stream, &viewport_gl, random);
            }

            time = .now(init.io, .awake);
        }

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

        first_frame = false;
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
        .buffer_released => |e| {
            if (e.viewport_id == viewport_id_gpu) {
                if (e.buffer_id == viewport_gl.front_buffer.id) {
                    viewport_gl.front_buffer.released = true;
                } else if (e.buffer_id == viewport_gl.back_buffer.id) {
                    viewport_gl.back_buffer.released = true;
                } else {
                    for (viewport_gl.old_buffers.items) |*b| {
                        if (b.id == e.buffer_id) {
                            b.released = true;
                        }
                    }
                }
            } else if (e.viewport_id == viewport_id_cpu) {
                if (e.buffer_id == viewport.front.id) {
                    viewport.front.released = true;
                } else if (e.buffer_id == viewport.back.id) {
                    viewport.back.released = true;
                }
            }
        },
        .buffer_destroyed => |e| {
            var i = viewport_gl.old_buffers.items.len;
            while (i > 0) {
                i -= 1;
                const old = &viewport_gl.old_buffers.items[i];
                if (e.buffer_id == old.id) {
                    old.deinit(gl_ctx);
                    _ = viewport_gl.old_buffers.orderedRemove(i);
                }
            }
        },
    }
}

fn resize_cpu(io: Io, gpa: std.mem.Allocator, stream: net.Stream, viewport: *Viewport, resize: protocol_types.ViewportResize) !void {
    std.debug.assert(resize.viewport_id == viewport_id_cpu);

    const new_viewport: Viewport = try .init(resize.width, resize.height);
    viewport.deinit();
    viewport.* = new_viewport;

    const cpu_table = .{
        .{ .id = viewport.front.id, .fd = viewport.front.fd },
        .{ .id = viewport.back.id, .fd = viewport.back.fd },
    };
    inline for (cpu_table) |entry| {
        try client_to_server.message_send_json(
            io,
            gpa,
            stream,
            .{
                .buffer_create_cpu_with_fd = .{
                    .id = entry.id,
                    .width = viewport.width,
                    .height = viewport.height,
                    .format = viewport.format,
                    .fd = entry.fd,
                },
            },
        );
    }
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
    try viewport.resize(io, gpa, stream, gl_ctx, gbm_device, resize.width, resize.height);
}

const ViewportGL = struct {
    width: u32,
    height: u32,
    stride: u32,
    bpp: u8,
    format: protocol_types.BufferFormat,
    modifier: u64,

    old_buffers: std.ArrayList(Buffer),
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

            .old_buffers = .empty,
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

    pub fn resize(vp: *ViewportGL, io: Io, gpa: std.mem.Allocator, stream: net.Stream, gl_ctx: opengl.ContextLinux, gbm_device: *c_linux.struct_gbm_device, requested_width: u32, requested_height: u32) !void {
        const width, const height = new_dimensions(requested_width, requested_height);

        // TODO: Use the buffer's width not the viewport's
        if (width < vp.width and height < vp.height) {
            return;
        }

        const front_buffer = try Buffer.init(gl_ctx, gbm_device, width, height);
        const back_buffer = try Buffer.init(gl_ctx, gbm_device, width, height);

        try vp.old_buffers.append(gpa, vp.front_buffer);
        try vp.old_buffers.append(gpa, vp.back_buffer);

        try client_to_server.message_send_json(
            io,
            gpa,
            stream,
            .{ .buffer_destroy = .{ .buffer_id = vp.front_buffer.id } },
        );
        try client_to_server.message_send_json(
            io,
            gpa,
            stream,
            .{ .buffer_destroy = .{ .buffer_id = vp.back_buffer.id } },
        );

        vp.front_buffer = front_buffer;
        vp.back_buffer = back_buffer;

        const table = .{
            .{ .id = front_buffer.id, .fd = front_buffer.get_fd() },
            .{ .id = back_buffer.id, .fd = back_buffer.get_fd() },
        };
        inline for (table) |entry| {
            try client_to_server.message_send_json(
                io,
                gpa,
                stream,
                .{
                    .buffer_create_gpu_with_fd = .{
                        .id = entry.id,
                        .width = width,
                        .height = height,
                        .format = vp.format,
                        .gbm_bo_modifier = vp.modifier,
                        .fd = entry.fd,
                    },
                },
            );
        }
    }

    pub const Buffer = struct {
        bo: *c_linux.struct_gbm_bo,
        gbm_texture: opengl.GbmBackedTexture,
        fbo: glad.GLuint,
        id: protocol_types.BufferID,
        released: bool,

        pub fn init(gl: opengl.ContextLinux, gbm_device: *c_linux.struct_gbm_device, width: u32, height: u32) !Buffer {
            const bo = try gbm_bo_create(gbm_device, width, height);
            const gbm_texture = try opengl.egl_image_from_gbm_bo(gl, bo);
            const fbo = try opengl.fbo_gen(gbm_texture.texture);

            const id = next_buffer_id.increment();
            return .{
                .bo = bo,
                .gbm_texture = gbm_texture,
                .fbo = fbo,
                .id = id,
                .released = true,
            };
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
    format: protocol_types.BufferFormat,

    front: Buffer,
    back: Buffer,

    pub fn init(width: u32, height: u32) !Viewport {
        const format: protocol_types.BufferFormat = .argb8888;
        const s = width * height * format.bytes_per_pixel();
        const front_fd, const front_buffer = try create_fd(s);
        const back_fd, const back_buffer = try create_fd(s);

        const front_id = next_buffer_id.increment();
        const back_id = next_buffer_id.increment();
        return .{
            .width = width,
            .height = height,
            .format = format,

            .front = .{
                .id = front_id,
                .fd = front_fd,
                .data = front_buffer,
                .released = true,
            },
            .back = .{
                .id = back_id,
                .fd = back_fd,
                .data = back_buffer,
                .released = true,
            },
        };
    }

    pub fn deinit(vp: *Viewport) void {
        std.posix.munmap(vp.front.data);
        std.posix.munmap(vp.back.data);
        _ = std.os.linux.close(vp.front.fd);
        _ = std.os.linux.close(vp.back.fd);
    }

    fn swap(vp: *Viewport) void {
        std.mem.swap(Buffer, &vp.front, &vp.back);
    }

    const Buffer = struct {
        id: protocol_types.BufferID,
        fd: c_int,
        data: []align(std.heap.page_size_min) u8,
        released: bool,
    };
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
    std.debug.assert(viewport.back.released);

    const r: u8 = random.int(u8);
    const g: u8 = random.int(u8);
    const b: u8 = random.int(u8);
    const a: u8 = 0xFF;
    std.log.info("Sent {x} {x} {x} {x} BufferID({})", .{ r, g, b, a, @intFromEnum(viewport.back.id) });
    var i: usize = 0;
    while (i < viewport.back.data.len) : (i += 4) {
        viewport.back.data[i + 0] = @intCast(b); // B
        viewport.back.data[i + 1] = @intCast(g); // G
        viewport.back.data[i + 2] = @intCast(r); // R
        viewport.back.data[i + 3] = @intCast(a); // A
    }

    viewport.swap();

    viewport.front.released = false;
    try client_to_server.message_send_json(
        io,
        gpa,
        stream,
        .{
            .buffer_present = .{
                .viewport_id = viewport_id_cpu,
                .buffer_id = viewport.front.id,
            },
        },
    );
}

fn render_gpu(io: Io, gpa: std.mem.Allocator, stream: net.Stream, viewport_gl: *ViewportGL, random: std.Random) !void {
    std.debug.assert(viewport_gl.back_buffer.released);

    const fr = random.float(f32);
    const fg = random.float(f32);
    const fb = random.float(f32);
    const fa = 1;
    std.log.info("Sent {d} {d} {d} {d} BufferID({}) fbo({})", .{
        fr,
        fg,
        fb,
        fa,
        @intFromEnum(viewport_gl.back_buffer.id),
        viewport_gl.back_buffer.fbo,
    });
    glad.glBindFramebuffer(glad.GL_FRAMEBUFFER, viewport_gl.back_buffer.fbo);
    std.debug.print("{}\n", .{glad.glGetError() == glad.GL_NO_ERROR});
    glad.glViewport(0, 0, @intCast(viewport_gl.width), @intCast(viewport_gl.height));
    std.debug.print("{}\n", .{glad.glGetError() == glad.GL_NO_ERROR});

    glad.glClearColor(fr, fg, fb, fa);
    std.debug.print("{}\n", .{glad.glGetError() == glad.GL_NO_ERROR});
    glad.glClear(glad.GL_COLOR_BUFFER_BIT);
    std.debug.print("{}\n", .{glad.glGetError() == glad.GL_NO_ERROR});
    glad.glFinish();
    std.debug.print("{}\n", .{glad.glGetError() == glad.GL_NO_ERROR});

    std.debug.print("\n\n\n", .{});
    viewport_gl.swap();

    viewport_gl.front_buffer.released = false;
    try client_to_server.message_send_json(
        io,
        gpa,
        stream,
        .{
            .buffer_present = .{
                .viewport_id = viewport_id_gpu,
                .buffer_id = viewport_gl.front_buffer.id,
            },
        },
    );
}

fn crash(io: Io, gpa: std.mem.Allocator, stream: net.Stream, viewport_gl: *ViewportGL, gl: opengl.ContextLinux, gbm_device: *c_linux.struct_gbm_device) !void {
    for (0..100) |i| {
        try client_to_server.message_send_json(
            io,
            gpa,
            stream,
            .{
                .buffer_present = .{
                    .viewport_id = viewport_id_gpu,
                    .buffer_id = viewport_gl.front_buffer.id,
                },
            },
        );
        try resize_gpu(io, gpa, stream, viewport_gl, gl, gbm_device, .{
            .viewport_id = viewport_id_gpu,
            .width = viewport_gl.width + @as(u32, @truncate(i)),
            .height = viewport_gl.height + @as(u32, @truncate(i)),
        });
        try io.sleep(.fromMilliseconds(1), .awake);
    }

    std.process.exit(1);
}

fn new_dimensions(width: u32, height: u32) struct { u32, u32 } {
    return .{
        dimension_multiple_of(width, 640),
        dimension_multiple_of(height, 480),
    };
}

fn dimension_multiple_of(requested: u32, multiple_of: u32) u32 {
    var result: u32 = 0;

    while (result < requested) {
        result += multiple_of;
    }

    return result;
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
