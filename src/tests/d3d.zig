pub fn d3d11_share_texture(init: std.process.Init) !void {
    if (!constants.os_has_d3d) return;

    var server = try shared.TestServer.concurrent(@src(), init);
    errdefer server.await(init) catch {};

    const handle = try shared.client_init(@src(), init);
    defer handle.deinit();

    try handle.init_d3d11();

    const vp = try handle.viewport_create(.d11, .{ .width = 512, .height = 512 }, false);
    try init.io.sleep(.fromSeconds(1), .awake);

    vp.destroy();
    try init.io.sleep(.fromSeconds(1), .awake);

    try server.await(init);
}

pub fn d3d11_clear_screen(init: std.process.Init) !void {
    if (!constants.os_has_d3d) return;

    var server = try shared.TestServer.concurrent(@src(), init);
    errdefer server.await(init) catch {};

    const handle = try shared.client_init(@src(), init);
    defer handle.deinit();

    try handle.init_d3d11();

    const vp = try handle.viewport_create(.d11, .{ .width = 512, .height = 512 }, false);

    const red: [4]f32 = .{ 1, 0, 0, 1 };
    const green: [4]f32 = .{ 0, 1, 0, 1 };
    const blue: [4]f32 = .{ 0, 0, 1, 1 };

    for (0..30) |i| {
        const color = ([_][4]f32{ red, green, blue })[i % 3];

        const frame = try vp.d11_frame_begin();

        frame.context.ClearRenderTargetView(frame.rtv, @ptrCast(&color));

        vp.d11_frame_end();
        try vp.d11_frame_present();

        try init.io.sleep(.fromSeconds(1), .awake);
    }

    vp.destroy();
    try init.io.sleep(.fromSeconds(1), .awake);

    try server.await(init);
}

const std = @import("std");
const Io = std.Io;
const testing = std.testing;

const shared = @import("shared.zig");

const client = @import("client");
const constants = @import("constants");
const glad = @import("glad");
const WindowSystem = @import("main").WindowSystem;
const Server = @import("main").Server;
const zio = @import("main").zio;
const tick = @import("main").tick;
