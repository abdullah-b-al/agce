pub fn main(init: std.process.Init) !void {
    const handle = try agce.init(
        init.io,
        init.gpa,
        init.environ_map,
        null,
    );
    defer handle.deinit();

    const viewport: *agce.ViewportHandle = try .create(handle, .cpu, 720, 720, false);

    var args_iter = try init.minimal.args.iterateAllocator(init.gpa);
    defer args_iter.deinit();

    _ = args_iter.skip();
    const program_to_embed = args_iter.next() orelse return error.MissingProgramPath;
    std.log.info("Will run {s}", .{program_to_embed});

    var child = try std.process.spawn(init.io, .{ .argv = &.{program_to_embed} });
    defer child.kill(init.io);

    const client_to_embed, const name = blk: while (true) {
        try handle.poll(.{ .deadline = .{ .raw = .fromNanoseconds(1), .clock = .awake } });
        try handle.update();

        // Rendering one frame is enough. Needed on wayland to display the window
        try utils.render(viewport, 0);

        var iter = handle.client_info_iterator();
        while (iter.next()) |result| {
            if (std.mem.eql(u8, result.info.name, "minimal_embeded_viewport")) {
                break :blk .{ result.client_id, result.info.name };
            }
        }
    };
    std.log.info("Will embed {s} {f}", .{ name, client_to_embed });

    const sub_viewport = try viewport.sub_viewport_embed(client_to_embed, .{
        .x = 100,
        .y = 100,
        .width = 100,
        .height = 100,
    });

    var rand: std.Random.DefaultPrng = .init(0);

    const width = 100;
    const height = 100;
    const speed_max = 4;
    const speed_min = 3;

    var x: i32 = 0;
    var y: i32 = 0;
    var velocity_x: i32 = 3;
    var velocity_y: i32 = 4;

    const begin: std.Io.Timestamp = .now(init.io, .awake);
    const fade_period: i64 = std.time.ms_per_s * 7.5;
    const vp_size = viewport.size();
    while (true) {
        const color = utils.fade_color(
            begin.untilNow(init.io, .awake),
            fade_period,
            255,
            255,
            255,
        );

        try utils.render(viewport, color);
        try init.io.sleep(.fromMilliseconds(16), .awake);

        x += velocity_x;
        y += velocity_y;

        const velocity_x_new = rand.random().intRangeAtMost(i32, speed_min, speed_max);
        const velocity_y_new = rand.random().intRangeAtMost(i32, speed_min, speed_max);
        if (x <= 0)
            velocity_x = velocity_x_new;

        if (x + width >= vp_size[0])
            velocity_x = -velocity_x_new;

        if (y <= 0)
            velocity_y = velocity_y_new;

        if (y + height >= vp_size[1])
            velocity_y = -velocity_y_new;

        try handle.sub_viewport_rect_set(sub_viewport, .{
            .x = @intCast(@max(0, x)),
            .y = @intCast(@max(0, y)),
            .width = width,
            .height = height,
        });
    }
}

const std = @import("std");
const agce = @import("agce");
const utils = @import("utils.zig");
