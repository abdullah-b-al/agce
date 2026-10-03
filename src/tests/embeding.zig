test "Embed sub-viewports" {
    var buf: [constants.socket_max_path]u8 = undefined;
    const testing_path_len = try std.process.executableDirPath(
        testing.io,
        &buf,
    );
    const path = try std.fs.path.join(testing.allocator, &.{
        buf[0..testing_path_len],
        "sub_viewport_recursive",
    });
    defer testing.allocator.free(path);

    var server = try shared.TestServer.concurrent(@src());
    errdefer server.await() catch {};

    try testing.io.sleep(.fromMilliseconds(500), .awake); // wait for server to start up

    var environ_map = try shared.environ_map_create(@src());
    defer environ_map.deinit();
    try environ_map.put(@import("sub_viewport_recursive.zig").env_depth_key, "0");

    var child = try std.process.spawn(testing.io, .{
        .argv = &.{path},
        .environ_map = &environ_map,
    });
    const exit = try child.wait(testing.io);
    try testing.expect(exit == .exited);
    try testing.expect(exit.exited == 0);

    try server.await();
}

test "Hide sub-viewports" {
    var buf: [constants.socket_max_path]u8 = undefined;
    const testing_path_len = try std.process.executableDirPath(
        testing.io,
        &buf,
    );
    const path = try std.fs.path.join(testing.allocator, &.{
        buf[0..testing_path_len],
        "sub_viewport_filled_rect",
    });
    defer testing.allocator.free(path);

    var server = try shared.TestServer.concurrent(@src());
    errdefer server.await() catch {};

    try testing.io.sleep(.fromMilliseconds(500), .awake); // wait for server to start up

    var environ_map = try shared.environ_map_create(@src());
    defer environ_map.deinit();

    const handle = try client.init(
        testing.io,
        testing.allocator,
        &environ_map,
    );
    defer handle.deinit();

    const vp = try handle.viewport_create(.cpu, .{ .width = 720, .height = 720 }, false);

    const child = try handle.process_create(&.{path});
    while (child.status() != .can_spawn) {
        try handle.poll(std.math.maxInt(u64));
    }
    try child.spawn(.{ .stdout = .inherit, .stderr = .inherit });
    while (child.status() != .connected) {
        try handle.poll(std.math.maxInt(u64));
    }

    const svp_width = @divFloor(vp.size().width, 3) * 2;
    const svp_height = @divFloor(vp.size().height, 3) * 2;
    const sub_viewport = try handle.sub_viewport_embed(vp, child, .{
        .x = 100,
        .y = 100,
        .width = svp_width,
        .height = svp_height,
    });

    var ts: Io.Timestamp = .now(testing.io, .awake);
    outer: while (true) {
        try handle.poll(0);

        while (vp.event_pop()) |event| {
            switch (event) {
                .viewport_resize => |e| vp.resize(e.size),
                .viewport_close => break :outer,
                else => {},
            }
        }

        try shared.render_cpu(vp, 0x00_00_00_00);
        try testing.io.sleep(.fromMilliseconds(33), .awake);

        const until_now = ts.untilNow(testing.io, .awake).toSeconds();
        // toggle every second
        const state: client.ViewportDisplayState =
            if (@mod(until_now, 2) == 0) .shown else .hidden;

        try sub_viewport.display_state_set(state);
    }

    sub_viewport.destroy();
    child.kill();

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
