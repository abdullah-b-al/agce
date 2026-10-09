pub fn share_d3d11_texture(init: std.process.Init) !void {
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
