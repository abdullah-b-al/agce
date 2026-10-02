test "Create a viewport" {
    var server = try shared.TestServer.concurrent(@src());

    const handle = try shared.client_init(@src());
    defer handle.deinit();

    const vp = try handle.viewport_create(.cpu, .{ .width = 512, .height = 512 }, false);
    vp.destroy();

    try server.await();
}

test "Render few frames - cpu" {
    var server = try shared.TestServer.concurrent(@src());

    const handle = try shared.client_init(@src());
    defer handle.deinit();

    const vp = try handle.viewport_create(.cpu, .{ .width = 512, .height = 512 }, false);

    for (0..60) |_| {
        try shared.render_cpu(vp, 0xFFFFFFFF);
        try testing.io.sleep(.fromMilliseconds(16), .awake);
    }

    vp.destroy();

    try server.await();
}

test "Render few frames - gl" {
    switch (@import("builtin").os.tag) {
        .linux => {},
        else => {
            return error.TODO;
        },
    }

    var server = try shared.TestServer.concurrent(@src());

    const handle = try shared.client_init(@src());
    defer handle.deinit();

    try handle.init_opengl(3, 3);

    const vp = try handle.viewport_create(.gl, .{ .width = 512, .height = 512 }, false);

    for (0..60) |_| {
        try shared.render_gl(vp);
        try testing.io.sleep(.fromMilliseconds(16), .awake);
    }

    vp.destroy();

    try server.await();
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
