pub const env_depth_key = "AGCE_TEST_DEPTH";
const max_depth = 5;

pub fn main(init: std.process.Init) !void {
    const depth_string = init.environ_map.get(env_depth_key).?;
    const depth = try std.fmt.parseInt(usize, depth_string, 10);
    std.log.debug("Depth {}", .{depth});
    if (depth > max_depth) {
        return;
    }

    const new_depth = try std.fmt.allocPrint(init.arena.allocator(), "{}", .{depth + 1});
    try init.environ_map.put(env_depth_key, new_depth);
    const handle = try agce.init(
        init.io,
        init.gpa,
        init.environ_map,
    );
    defer handle.deinit();
    std.log.debug("depth {} connected", .{depth});

    const viewport: *agce.ViewportHandle =
        try handle.viewport_create(.cpu, null, .{ .x = 0, .y = 0, .width = 720, .height = 720 }, false);

    defer viewport.destroy();

    std.log.debug("viewport created for depth {}", .{depth});

    var remote_viewport: ?*agce.RemoteViewportHandle = null;
    var maybe_child: ?agce.Process = null;
    defer if (remote_viewport) |rvp| rvp.destroy();
    defer if (maybe_child) |*c| {
        _ = c.wait() catch {};
        c.deinit();
    };

    const rvp_width = @divFloor(viewport.size().width, 3) * 2;
    const rvp_height = @divFloor(viewport.size().height, 3) * 2;
    if (depth < max_depth) {
        var args_iter = try init.minimal.args.iterateAllocator(init.gpa);
        defer args_iter.deinit();
        const self_path = args_iter.next().?;

        std.log.debug("depth {} process_create", .{depth});

        const remote = try handle.remote_client_create();
        var child = try handle.process_init(&.{self_path});

        std.log.debug("depth {} spawn", .{depth});
        try child.spawn(remote, .{
            .stdout = .inherit,
            .stderr = .inherit,
        });
        maybe_child = child;

        std.log.debug("depth {} connected poll", .{depth});
        while (remote.status != .connected) {
            try handle.poll(std.math.maxInt(u64));
        }

        remote_viewport = try handle.remote_viewport_create(viewport, remote, .{
            .x = 100,
            .y = 100,
            .width = rvp_width,
            .height = rvp_height,
        });
    }

    std.log.debug("remote_viewport of depth {} {?}", .{ depth, remote_viewport });

    var rand: std.Random.DefaultPrng = .init(depth);

    var rect: MovingRect = .init(0, 0, rvp_width, rvp_height);

    const color = rand.random().int(u32) | 0xFF000000;
    std.log.debug("depth {} color {}", .{ depth, color });
    var start_count_down = depth == max_depth;
    var ts: Io.Timestamp = .now(init.io, .awake);
    while (true) {
        try handle.poll(1);

        while (viewport.event_pop()) |event| {
            switch (event) {
                .remote_viewport_closed => {
                    if (!start_count_down) {
                        start_count_down = true;
                        ts = .now(init.io, .awake);
                    }
                },
                else => {},
            }
        }

        if (start_count_down and ts.untilNow(init.io, .awake).toSeconds() >= 1) {
            break;
        }

        const size = viewport.size();

        try shared.render_cpu(viewport, color);
        try init.io.sleep(.fromMilliseconds(16), .awake);

        rect.move(size.width, size.height, rand.random());

        if (remote_viewport) |rvp| {
            try rvp.rect_set(.{
                .x = @intCast(@max(0, rect.x)),
                .y = @intCast(@max(0, rect.y)),
                .width = @intCast(rect.w),
                .height = @intCast(rect.h),
            });
        }
    }
}

pub const MovingRect = struct {
    const speed_max = 4;
    const speed_min = 3;

    x: i32,
    y: i32,
    w: i32,
    h: i32,
    velocity_x: i32,
    velocity_y: i32,

    pub fn init(x: i32, y: i32, w: i32, h: i32) MovingRect {
        return .{
            .x = x,
            .y = y,
            .w = w,
            .h = h,
            .velocity_x = 3,
            .velocity_y = 4,
        };
    }

    pub fn move(rect: *MovingRect, width: i32, height: i32, rand: std.Random) void {
        rect.x += rect.velocity_x;
        rect.y += rect.velocity_y;

        const velocity_x_new = rand.intRangeAtMost(i32, speed_min, speed_max);
        const velocity_y_new = rand.intRangeAtMost(i32, speed_min, speed_max);

        if (rect.x <= 0)
            rect.velocity_x = velocity_x_new;

        if (rect.x + rect.w >= width)
            rect.velocity_x = -velocity_x_new;

        if (rect.y <= 0)
            rect.velocity_y = velocity_y_new;

        if (rect.y + rect.h >= height)
            rect.velocity_y = -velocity_y_new;
    }
};

const std = @import("std");
const Io = std.Io;

const agce = @import("client");
const shared = @import("shared.zig");
const constants = @import("constants");
