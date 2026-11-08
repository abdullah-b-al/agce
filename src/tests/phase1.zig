pub fn main(init: std.process.Init) !void {
    try create_a_viewport(init);
    try render_few_frames_cpu(init);
    try render_text(init);
}

fn create_a_viewport(init: std.process.Init) !void {
    var server = try shared.TestServer.concurrent(@src(), init);

    const handle = try shared.client_init(@src(), init);
    defer handle.deinit();

    const vp = try handle.viewport_create(.cpu, .{ .width = 512, .height = 512 }, false);

    try init.io.sleep(.fromSeconds(1), .awake);

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

fn render_text(init: std.process.Init) !void {
    var server = try shared.TestServer.concurrent(@src(), init);
    errdefer server.await(init) catch {};

    const handle = try shared.client_init(@src(), init);
    defer handle.deinit();

    const vp = try handle.viewport_create(.cpu, .{ .width = 750, .height = 512 }, false);

    for (0..5) |_| {
        try handle.poll(0);
        try render_text_inner(init.io, init.gpa, vp, "This should be black text on white background");
        try init.io.sleep(.fromSeconds(1), .awake);
    }

    vp.destroy();
    try server.await(init);
}

fn render_text_inner(
    io: Io,
    gpa: std.mem.Allocator,
    vp: *client.ViewportHandle,
    text: []const u8,
) !void {
    const black = z2d.Pixel.fromColor(.{ .rgba = .{ 0, 0, 0, 1 } });

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

    const font_size = 32;
    context.setSourceToPixel(black);
    context.setAntiAliasingMode(.default);
    context.setFontSize(font_size);
    try context.setFontToBuffer(@embedFile("ProggyClean.ttf"));

    try context.showText(text, 0, 0);

    try vp.cpu_present();
}

const std = @import("std");
const Io = std.Io;
const testing = std.testing;

const shared = @import("shared.zig");

const client = @import("client");
const constants = @import("constants");
const z2d = @import("z2d");
const Compositor = @import("compositor").Compositor;
const Server = @import("compositor").Server;
const zio = @import("compositor").zio;
const tick = @import("compositor").tick;

const log = std.log;
