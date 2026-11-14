pub fn present_many_viewports_cpu(init: std.process.Init) !void {
    var server = try shared.TestServer.concurrent(@src(), init);
    errdefer server.await(init) catch {};

    const handle = try shared.client_init(@src(), init);
    defer handle.deinit();

    const viewports = try init.arena.allocator().alloc(*client.ViewportHandle, 10);

    const width = 512;
    const height = 512;
    for (viewports) |*vp| {
        vp.* = try handle.viewport_create(.cpu, null, .{ .x = 0, .y = 0, .width = width, .height = height }, false);
    }

    var x: i32 = 0;
    var y: i32 = 0;
    while (true) {
        const rect_width = 50;
        const rect_height = 50;
        for (viewports) |vp| {
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

            var context = z2d.Context.init(init.io, init.gpa, &surface);
            defer context.deinit();

            context.setSourceToPixel(.{ .argb = .{ .r = 0xFF, .g = 0, .b = 0, .a = 0xFF } });
            try fill_rect(&context, .{
                .x = x,
                .y = y,
                .width = rect_width,
                .height = rect_height,
            });
        }

        for (viewports) |vp| {
            try vp.cpu_present();
        }

        try init.io.sleep(.fromMilliseconds(16), .awake);

        const step_x = 10;
        const step_y = 50;
        x += step_x;
        if (x + rect_width >= width) {
            x = 0;
            y += step_y;
        }

        if (y + rect_height >= height) {
            break;
        }
    }

    for (viewports) |vp| vp.destroy();
    try init.io.sleep(.fromMilliseconds(500), .awake);

    try server.await(init);
}

fn fill_rect(ctx: *z2d.Context, rect: client.Rect) !void {
    try ctx.moveTo(rect.x, rect.y);
    try ctx.lineTo(rect.x + rect.width, rect.y);
    try ctx.lineTo(rect.x + rect.width, rect.y + rect.height);
    try ctx.lineTo(rect.x, rect.y + rect.height);
    try ctx.closePath();
    try ctx.fill();
}

pub fn present_many_viewports_d11(init: std.process.Init) !void {
    if (!constants.os_has_d3d) return;

    var server = try shared.TestServer.concurrent(@src(), init);
    errdefer server.await(init) catch {};

    const handle = try shared.client_init(@src(), init);
    defer handle.deinit();

    try handle.init_d3d11();

    const viewports = try init.arena.allocator().alloc(*client.ViewportHandle, 10);

    for (viewports) |*vp| {
        vp.* = try handle.viewport_create(.d11, null, .{ .x = 0, .y = 0, .width = 512, .height = 512 }, false);
    }

    const white: [4]f32 = .{ 1, 1, 1, 1 };

    const ts: Io.Timestamp = .now(init.io, .awake);
    while (ts.untilNow(init.io, .awake).toSeconds() <= 10) {
        for (viewports) |vp| {
            const frame = try vp.d11_buffer_get();
            frame.context.ClearRenderTargetView(frame.rtv, @ptrCast(&white));
            try vp.d11_present();
        }

        try init.io.sleep(.fromMilliseconds(16), .awake);
    }

    for (viewports) |vp| vp.destroy();
    try init.io.sleep(.fromSeconds(1), .awake);

    try server.await(init);
}

const std = @import("std");
const Io = std.Io;
const testing = std.testing;

const shared = @import("shared.zig");
const client = @import("client");
const z2d = @import("z2d");
const constants = @import("constants");
