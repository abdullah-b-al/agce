test "Events" {
    const ExpectEvent = enum {
        mouse_motion,
        mouse_enter,
        mouse_leave,
        mouse_left_pressed,
        mouse_left_released,
        mouse_right_pressed,
        mouse_right_released,
    };
    const black = z2d.Pixel.fromColor(.{ .rgba = .{ 0, 0, 0, 1 } });

    var server = try shared.TestServer.concurrent(@src());
    errdefer server.await() catch {};

    const handle = try shared.client_init(@src());
    defer handle.deinit();

    const vp = try handle.viewport_create(.cpu, .{ .width = 512, .height = 512 }, false);

    var events: std.ArrayList(client.Event) = .empty;
    defer events.deinit(testing.allocator);
    var expect: std.EnumSet(ExpectEvent) = .full;
    while (expect.count() > 0) {
        try handle.poll(0);

        while (vp.event_pop()) |event| {
            try events.append(testing.allocator, event);
        }

        for (events.items) |event| {
            switch (event) {
                .mouse_motion => expect.remove(.mouse_motion),
                .mouse_button => |e| {
                    if (e.button == .left) {
                        if (e.state == .pressed) expect.remove(.mouse_left_pressed);
                        if (e.state == .released) expect.remove(.mouse_left_released);
                    }

                    if (e.button == .right) {
                        if (e.state == .pressed) expect.remove(.mouse_right_pressed);
                        if (e.state == .released) expect.remove(.mouse_right_released);
                    }
                },
                .mouse_enter => expect.remove(.mouse_enter),
                .mouse_leave => expect.remove(.mouse_leave),
                else => {},
            }
        }

        { // render
            const frame = try vp.cpu_frame_begin();
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

            var context = z2d.Context.init(testing.io, testing.allocator, &surface);
            defer context.deinit();

            const font_size = 64;
            context.setSourceToPixel(black);
            context.setAntiAliasingMode(.default);
            context.setFontSize(font_size);
            try context.setFontToBuffer(@embedFile("ProggyClean.ttf"));

            try context.showText("Expecting:", 0, 0);
            var y: i32 = font_size;
            var iter = expect.iterator();
            while (iter.next()) |e| {
                try context.showText(@tagName(e), 0, y);
                y += font_size;
            }

            vp.cpu_frame_end();
            try vp.cpu_frame_present();
        }

        try testing.io.sleep(.fromMilliseconds(16), .awake);
    }

    vp.destroy();

    try server.await();
}

fn inside(x: i32, y: i32, rect: client.Rect) bool {
    const bottom = rect.y + rect.height;
    const right = rect.x + rect.width;

    return x >= rect.x and x <= right and y >= rect.y and y <= bottom;
}

fn draw_rect(ctx: *z2d.Context, rect: client.Rect) !void {
    try ctx.moveTo(rect.x, rect.y);
    try ctx.lineTo(rect.x + rect.width, rect.y);
    try ctx.lineTo(rect.x + rect.width, rect.y + rect.height);
    try ctx.lineTo(rect.x, rect.y + rect.height);
    try ctx.closePath();
    try ctx.stroke();
}

const std = @import("std");
const Io = std.Io;
const testing = std.testing;

const shared = @import("shared.zig");

const z2d = @import("z2d");
const client = @import("client");
const constants = @import("constants");
const glad = @import("glad");
const WindowSystem = @import("main").WindowSystem;
const Server = @import("main").Server;
const zio = @import("main").zio;
const tick = @import("main").tick;
