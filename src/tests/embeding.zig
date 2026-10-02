test "Embed sub-viewports" {
    var buf: [constants.socket_max_path]u8 = undefined;
    const testing_path_len = try std.process.executableDirPath(
        testing.io,
        &buf,
    );
    const path = try std.fs.path.join(testing.allocator, &.{
        buf[0..testing_path_len],
        "sub_viewport_process",
    });
    defer testing.allocator.free(path);

    var server = try shared.TestServer.concurrent(@src());
    errdefer server.await() catch {};

    try testing.io.sleep(.fromMilliseconds(500), .awake); // wait for server to start up

    var environ_map = try shared.environ_map_create(@src());
    defer environ_map.deinit();
    try environ_map.put(@import("sub_viewport_process.zig").env_depth_key, "0");

    var child = try std.process.spawn(testing.io, .{
        .argv = &.{path},
        .environ_map = &environ_map,
    });
    const exit = try child.wait(testing.io);
    try testing.expect(exit == .exited);
    try testing.expect(exit.exited == 0);

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
