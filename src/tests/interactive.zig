var io: Io = undefined;
var gpa: std.mem.Allocator = undefined;

pub fn interactive_events(init: std.process.Init) !void {
    io = init.io;
    gpa = init.gpa;
    var server = try shared.TestServer.concurrent(@src(), init);
    errdefer server.await(init) catch {};

    const handle = try shared.client_init(@src(), init);
    defer handle.deinit();

    try events_resize(handle);
    try events_mouse(handle);
    try events_keys(handle);
    try events_cursor_shape(handle);

    try server.await(init);
}

fn events_resize(handle: *client.ClientHandle) !void {
    const ExpectEvent = enum {
        resize_to_480,
        resize_to_720,
        resize_to_900,
    };

    const vp = try handle.viewport_create(.cpu, .{ .width = 512, .height = 512 }, false);
    defer vp.destroy();

    var events: std.ArrayList(client.Event) = .empty;
    defer events.deinit(gpa);
    var expect: std.EnumSet(ExpectEvent) = .full;
    var current_size = vp.size();
    while (expect.count() > 0) {
        try handle.poll(0);

        while (vp.event_pop()) |event| {
            const e = switch (event) {
                .viewport_resize => |e| e,
                else => continue,
            };
            current_size = e.size;

            const margin = 50;
            if (between(e.size.width, 480 - margin, 480 + margin)) {
                expect.remove(.resize_to_480);
            }

            if (between(e.size.width, 720 - margin, 720 + margin)) {
                expect.remove(.resize_to_720);
            }

            if (between(e.size.width, 900 - margin, 900 + margin)) {
                expect.remove(.resize_to_900);
            }
        }

        const current_size_text = try std.fmt.allocPrint(
            gpa,
            "Current width {}",
            .{current_size.width},
        );
        defer gpa.free(current_size_text);
        try render_enums_with_header(vp, current_size_text, ExpectEvent, &expect);
    }
}

fn events_mouse(handle: *client.ClientHandle) !void {
    const ExpectEvent = enum {
        mouse_motion,
        mouse_enter,
        mouse_leave,
        mouse_left_pressed,
        mouse_left_released,
        mouse_right_pressed,
        mouse_right_released,
    };
    const vp = try handle.viewport_create(.cpu, .{ .width = 512, .height = 512 }, false);
    defer vp.destroy();

    var events: std.ArrayList(client.Event) = .empty;
    defer events.deinit(gpa);
    var expect: std.EnumSet(ExpectEvent) = .full;
    while (expect.count() > 0) {
        try handle.poll(0);

        while (vp.event_pop()) |event| {
            try events.append(gpa, event);
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

        try render_enums_with_header(vp, "Expecting:", ExpectEvent, &expect);
    }
}

fn events_keys(handle: *client.ClientHandle) !void {
    const ExpectEvent = enum {
        key_a_pressed,
        key_a_released,
        key_a_repeat,
    };
    const vp = try handle.viewport_create(.cpu, .{ .width = 512, .height = 512 }, false);
    defer vp.destroy();

    var events: std.ArrayList(client.Event) = .empty;
    defer events.deinit(gpa);
    var expect: std.EnumSet(ExpectEvent) = .full;
    while (expect.count() > 0) {
        try handle.poll(0);

        while (vp.event_pop()) |event| {
            try events.append(gpa, event);
        }

        for (events.items) |event| {
            switch (event) {
                .keyboard_key => |e| {
                    if (e.key == .a and e.state == .pressed) {
                        expect.remove(.key_a_pressed);
                    }

                    if (e.key == .a and e.state == .released) {
                        expect.remove(.key_a_released);
                    }

                    if (e.key == .a and e.state == .repeat) {
                        expect.remove(.key_a_repeat);
                    }
                },
                else => {},
            }
        }

        try render_enums_with_header(vp, "Expecting:", ExpectEvent, &expect);
    }
}

fn events_cursor_shape(handle: *client.ClientHandle) !void {
    const vp = try handle.viewport_create(.cpu, .{ .width = 512, .height = 512 }, false);
    defer vp.destroy();

    var events: std.ArrayList(client.Event) = .empty;
    defer events.deinit(gpa);
    var expect: std.EnumSet(client.CursorShape) = .full;
    var mouse_x: i32 = 0;
    var mouse_y: i32 = 0;
    var current_cursor: ?client.CursorShape = null;
    var hover_time: Io.Timestamp = .now(io, .awake);
    while (expect.count() > 0) {
        try handle.poll(0);
        try handle.update();

        var clicked = false;
        while (vp.event_pop()) |event| {
            switch (event) {
                .mouse_motion => |e| {
                    mouse_x = @trunc(e.x);
                    mouse_y = @trunc(e.y);
                },
                .viewport_resize => |e| vp.resize(e.size),
                .mouse_button => |e| clicked = e.button == .left and e.state == .pressed,
                else => {},
            }
        }

        const black = z2d.Pixel.fromColor(.{ .rgba = .{ 0, 0, 0, 1 } });

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

        var context = z2d.Context.init(io, gpa, &surface);
        defer context.deinit();

        const line_size = 64;
        context.setSourceToPixel(black);
        context.setAntiAliasingMode(.default);
        context.setFontSize(line_size);
        try context.setFontToBuffer(@embedFile("ProggyClean.ttf"));

        try context.showText("Click to remove", 0, 0);
        var y: i32 = line_size;
        var iter = expect.iterator();
        while (iter.next()) |e| {
            try context.showText(@tagName(e), 0, y);
            if (mouse_y >= y and mouse_y <= y + line_size) {
                try handle.cursor_shape_set(vp.id(), e);
                if (current_cursor == null) {
                    hover_time = .now(io, .awake);
                    current_cursor = e;
                }

                if (clicked) {
                    expect.remove(e);
                    current_cursor = null;
                }
            }
            y += line_size;
        }

        vp.cpu_frame_end();
        try vp.cpu_frame_present();

        try io.sleep(.fromMilliseconds(33), .awake);
    }
}
fn render_enums_with_header(vp: *client.ViewportHandle, header_text: []const u8, comptime E: type, expect: *const std.EnumSet(E)) !void {
    const black = z2d.Pixel.fromColor(.{ .rgba = .{ 0, 0, 0, 1 } });

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

    var context = z2d.Context.init(io, gpa, &surface);
    defer context.deinit();

    const font_size = 64;
    context.setSourceToPixel(black);
    context.setAntiAliasingMode(.default);
    context.setFontSize(font_size);
    try context.setFontToBuffer(@embedFile("ProggyClean.ttf"));

    try context.showText(header_text, 0, 0);
    var y: i32 = font_size;
    var iter = expect.iterator();
    while (iter.next()) |e| {
        try context.showText(@tagName(e), 0, y);
        y += font_size;
    }

    vp.cpu_frame_end();
    try vp.cpu_frame_present();

    try io.sleep(.fromMilliseconds(33), .awake);
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

fn between(value: anytype, min: @TypeOf(value), max: @TypeOf(value)) bool {
    return value >= min and value <= max;
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
