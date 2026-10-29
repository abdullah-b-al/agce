const this_file = @This();

pub const std_options: std.Options = .{
    .log_level = .info,
};

const files = .{
    this_file,
    @import("embeding.zig"),
    @import("interactive.zig"),
    @import("d3d.zig"),
    @import("presentation.zig"),
};

const Case = enum {
    create_a_viewport,
    render_few_frames_cpu,
    render_few_frames_gl,
    interactive_events,
    embed_sub_viewports,
    hide_sub_viewports,
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
    _ = args.skip();

    var cases: std.EnumSet(Case) = .empty;

    while (args.next()) |arg| {
        const case = std.meta.stringToEnum(Case, arg) orelse {
            std.process.fatal("Unknown test case {s}", .{arg});
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

fn create_a_viewport(init: std.process.Init) !void {
    var server = try shared.TestServer.concurrent(@src(), init);

    const handle = try shared.client_init(@src(), init);
    defer handle.deinit();

    const vp = try handle.viewport_create(.cpu, .{ .width = 512, .height = 512 }, false);
    vp.destroy();

    try server.await(init);
}

fn render_few_frames_cpu(init: std.process.Init) !void {
    var server = try shared.TestServer.concurrent(@src(), init);

    const handle = try shared.client_init(@src(), init);
    defer handle.deinit();

    const vp = try handle.viewport_create(.cpu, .{ .width = 512, .height = 512 }, false);

    for (0..60) |_| {
        try shared.render_cpu(vp, 0xFFFFFFFF);
        try init.io.sleep(.fromMilliseconds(16), .awake);
    }

    vp.destroy();

    try server.await(init);
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
const Compositor = @import("compositor").Compositor;
const Server = @import("compositor").Server;
const zio = @import("compositor").zio;
const tick = @import("compositor").tick;

const log = std.log;
