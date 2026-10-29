pub fn embed_sub_viewports(init: std.process.Init) !void {
    var buf: [constants.socket_max_path]u8 = undefined;
    const testing_path_len = try std.process.executableDirPath(
        init.io,
        &buf,
    );
    const path = try std.fs.path.join(init.gpa, &.{
        buf[0..testing_path_len],
        "sub_viewport_recursive",
    });
    defer init.gpa.free(path);

    var server = try shared.TestServer.concurrent(@src(), init);
    errdefer server.await(init) catch {};

    try init.io.sleep(.fromMilliseconds(500), .awake); // wait for server to start up

    var environ_map = try shared.environ_map_create(@src(), init);
    defer environ_map.deinit();
    try environ_map.put(@import("sub_viewport_recursive.zig").env_depth_key, "0");

    var child = try std.process.spawn(init.io, .{
        .argv = &.{path},
        .environ_map = &environ_map,
    });
    const exit = try child.wait(init.io);
    std.debug.assert(exit == .exited);
    std.debug.assert(exit.exited == 0);

    try server.await(init);
}

pub fn hide_sub_viewports(init: std.process.Init) !void {
    var buf: [constants.socket_max_path]u8 = undefined;
    const testing_path_len = try std.process.executableDirPath(
        init.io,
        &buf,
    );
    const path = try std.fs.path.join(init.gpa, &.{
        buf[0..testing_path_len],
        "sub_viewport_filled_rect",
    });
    defer init.gpa.free(path);

    var server = try shared.TestServer.concurrent(@src(), init);
    errdefer server.await(init) catch {};

    try init.io.sleep(.fromMilliseconds(500), .awake); // wait for server to start up

    var environ_map = try shared.environ_map_create(@src(), init);
    defer environ_map.deinit();

    const handle = try client.init(
        init.io,
        init.gpa,
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

    var ts: Io.Timestamp = .now(init.io, .awake);
    outer: while (true) {
        try handle.poll(0);

        while (vp.event_pop()) |event| {
            switch (event) {
                .viewport_resize => |e| try vp.resize(e.size),
                .viewport_close => break :outer,
                else => {},
            }
        }

        try shared.render_cpu(vp, 0x00_00_00_00);
        try init.io.sleep(.fromMilliseconds(33), .awake);

        const until_now = ts.untilNow(init.io, .awake).toSeconds();
        // toggle every second
        const state: client.ViewportDisplayState =
            if (@mod(until_now, 2) == 0) .shown else .hidden;

        try sub_viewport.display_state_set(state);
    }

    sub_viewport.destroy();
    child.kill();

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
