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

const Case = enum {
    events_resize,
    events_mouse,
    events_keys,
    events_cursor_shape,
    render_few_frames_gl,
    embed_remote_viewports,
    hide_remote_viewports,
    d3d11_share_texture,
    d3d11_clear_screen,
    present_many_viewports_cpu,
    present_many_viewports_d11,
};

comptime {
    for (@typeInfo(Case).@"enum".fields) |field| {
        var found = false;
        for (files) |file| {
            if (@hasDecl(file, field.name)) {
                found = true;
            }
        }

        if (!found) @compileError("Cannot find case " ++ field.name ++ ". Either it does not exist or its function is private");
    }
}

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.arena.allocator());
    const binary_path = args.next().?;

    const case_to_run = args.next();

    if (case_to_run) |case_string| {
        const case = std.meta.stringToEnum(Case, case_string) orelse {
            const available = comptime blk: {
                var str: []const u8 = "";
                for (@typeInfo(Case).@"enum".fields) |f| {
                    str = str ++ f.name ++ "\n";
                }
                break :blk str;
            };
            std.process.fatal("Unknown test case {s}.\nAvailable cases:\n{s}", .{ case_string, available });
        };
        switch (case) {
            inline else => |tag| {
                const file = blk: inline for (files) |file| {
                    if (@hasDecl(file, @tagName(tag))) {
                        break :blk file;
                    }
                } else @panic("Cannot find case " ++ @tagName(tag));

                const func = @field(file, @tagName(tag));
                try func(init);
            },
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
    const vp = try handle.viewport_create(.cpu, .{ .width = 512, .height = 512 }, false);
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

        inline for (@typeInfo(Case).@"enum".fields) |field| {
            context.setSourceToPixel(black);

            if (mouse_y >= y + padding and mouse_y <= y + line_size) {
                context.setSourceToPixel(green);

                if (clicked) {
                    const dir = try std.process.executableDirPathAlloc(io, gpa);
                    defer gpa.free(dir);

                    _ = try std.process.spawn(
                        io,
                        .{
                            .argv = &.{ binary_path, field.name },
                            .stdout = .inherit,
                            .stderr = .inherit,
                        },
                    );
                }
            }

            try context.showText(field.name, 0, y);
            y += line_size + padding;
        }

        try vp.cpu_present();

        try io.sleep(.fromMilliseconds(16), .awake);
    }
}

pub fn main2(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.arena.allocator());
    _ = args.skip();

    var cases: std.EnumSet(Case) = .empty;

    while (args.next()) |arg| {
        const case = std.meta.stringToEnum(Case, arg) orelse {
            const available = comptime blk: {
                var str: []const u8 = "";
                for (@typeInfo(Case).@"enum".fields) |f| {
                    str = str ++ f.name ++ "\n";
                }
                break :blk str;
            };
            std.process.fatal("Unknown test case {s}.\nAvailable cases:\n{s}", .{ arg, available });
        };

        cases.insert(case);
    }

    if (cases.count() == 0) {
        cases = .full;
    }

    var iter = cases.iterator();

    while (iter.next()) |case| {
        switch (case) {
            inline else => |tag| {
                const file = blk: inline for (files) |file| {
                    if (@hasDecl(file, @tagName(tag))) {
                        break :blk file;
                    }
                } else @panic("Cannot find case " ++ @tagName(tag));

                const func = @field(file, @tagName(tag));
                try func(init);
            },
        }
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

    const vp = try handle.viewport_create(.gl, .{ .width = 512, .height = 512 }, false);

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
