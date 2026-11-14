const this_file = @This();

pub const std_options: std.Options = .{
    .log_scope_levels = &.{
        .{ .scope = .zio, .level = .info },
    },
};

const files = .{
    this_file,
    @import("embeding.zig"),
    @import("events.zig"),
    @import("d3d.zig"),
    @import("presentation.zig"),
};

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.arena.allocator());
    const binary_path = args.next().?;

    const case_to_run = args.next();

    if (case_to_run) |case_string| {
        inline for (files) |file| {
            inline for (@typeInfo(file).@"struct".decls) |decl| {
                const function = @field(file, decl.name);
                if (@typeInfo(@TypeOf(function)) == .@"fn" and
                    !std.mem.eql(u8, decl.name, "main") and
                    std.mem.eql(u8, decl.name, case_string))
                {
                    try function(init);
                }
            }
        }
    } else {
        try phase2(init, binary_path);
    }
}

fn phase2(init: std.process.Init, binary_path: []const u8) !void {
    var server = try shared.TestServer.concurrent(@src(), init);
    errdefer server.await(init) catch {};

    const handle = try shared.client_init(@src(), init);
    defer handle.deinit();

    try show_tests(init.io, init.gpa, handle, binary_path);

    try server.await(init);
}

fn show_tests(
    io: Io,
    gpa: std.mem.Allocator,
    handle: *client.ClientHandle,
    binary_path: []const u8,
) !void {
    const vp = try handle.viewport_create(.cpu, null, .{ .width = 512, .height = 512 }, false);
    defer vp.destroy();

    var mouse_x: i32 = 0;
    var mouse_y: i32 = 0;
    while (true) {
        try handle.poll(0);

        var clicked = false;
        while (vp.event_pop()) |event| {
            switch (event) {
                .mouse_motion => |e| {
                    mouse_x = @trunc(e.x);
                    mouse_y = @trunc(e.y);
                },
                .viewport_resize => |e| try vp.resize(e.size),
                .mouse_button => |e| clicked = e.button == .left and e.state == .pressed,
                .viewport_close => return,
                else => {},
            }
        }

        const black = z2d.Pixel.fromColor(.{ .rgba = .{ 0, 0, 0, 1 } });
        const green = z2d.Pixel.fromColor(.{ .rgba = .{ 0, 0.75, 0, 1 } });

        const frame = try vp.cpu_buffer_get();
        const buffer: []z2d.pixel.ARGB = blk: {
            const ptr: [*]z2d.pixel.ARGB = @ptrCast(@alignCast(frame.buffer));
            std.debug.assert(frame.bytes_per_pixel == 4);
            break :blk ptr[0 .. frame.buffer.len / 4];
        };

        var surface = z2d.Surface.initBuffer(
            .image_surface_argb,
            .{ .r = 0xFF, .g = 0xFF, .b = 0xFF, .a = 0xFF },
            buffer,
            frame.width,
            frame.height,
        );

        var context = z2d.Context.init(io, gpa, &surface);
        defer context.deinit();

        const line_size = 32;
        const padding = line_size / 4;
        context.setSourceToPixel(black);
        context.setAntiAliasingMode(.default);
        context.setFontSize(line_size);
        try context.setFontToBuffer(@embedFile("ProggyClean.ttf"));

        try context.showText("Click on test case to run", 0, 0);
        var y: i32 = line_size + padding;

        inline for (files) |file| {
            inline for (@typeInfo(file).@"struct".decls) |decl| {
                const function = @field(file, decl.name);
                if (@typeInfo(@TypeOf(function)) == .@"fn" and
                    !std.mem.eql(u8, decl.name, "main"))
                {
                    context.setSourceToPixel(black);

                    if (mouse_y >= y + padding and mouse_y <= y + line_size) {
                        context.setSourceToPixel(green);

                        if (clicked) {
                            const dir = try std.process.executableDirPathAlloc(io, gpa);
                            defer gpa.free(dir);

                            _ = try std.process.spawn(
                                io,
                                .{
                                    .argv = &.{ binary_path, decl.name },
                                    .stdout = .inherit,
                                    .stderr = .inherit,
                                },
                            );
                        }
                    }

                    try context.showText(decl.name, 0, y);
                    y += line_size + padding;
                }
            }
        }

        try vp.cpu_present();

        try io.sleep(.fromMilliseconds(16), .awake);
    }
}

fn render_few_frames_gl(init: std.process.Init) !void {
    switch (@import("builtin").os.tag) {
        .linux => {},
        else => {
            return error.TODO;
        },
    }

    var server = try shared.TestServer.concurrent(@src(), init);

    const handle = try shared.client_init(@src(), init);
    defer handle.deinit();

    try handle.init_opengl(3, 3);

    const vp = try handle.viewport_create(.gl, null, .{ .width = 512, .height = 512 }, false);

    for (0..60) |_| {
        try shared.render_gl(vp);
        try init.io.sleep(.fromMilliseconds(16), .awake);
    }

    vp.destroy();

    try server.await(init);
}

const std = @import("std");
const Io = std.Io;
const testing = std.testing;

const shared = @import("shared.zig");

const client = @import("client");
const constants = @import("constants");
const glad = @import("glad");
const z2d = @import("z2d");
const Compositor = @import("compositor").Compositor;
const Server = @import("compositor").Server;
const zio = @import("compositor").zio;
const tick = @import("compositor").tick;

const log = std.log;
