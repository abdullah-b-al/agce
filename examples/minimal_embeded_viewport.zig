pub fn main(init: std.process.Init) !void {
    const handle = try agce.init(
        init.io,
        init.gpa,
        init.environ_map,
        .{ .name = "minimal_embeded_viewport" },
    );
    defer handle.deinit();

    const viewport = blk: while (true) {
        try handle.poll_once(.none);
        try handle.update();

        if (handle.viewport_pending_peek()) |result| {
            break :blk try agce.ViewportHandle.create_from_pending(
                handle,
                .cpu,
                result.id,
                result.requsted_width,
                result.requsted_height,
                false,
            );
        }
    };

    var rand: std.Random.DefaultPrng = .init(0);
    while (true) {
        try handle.poll(.{ .duration = .{ .raw = .fromNanoseconds(1), .clock = .awake } });
        try handle.update();

        try utils.render(viewport, rand.random().int(u24));
        try init.io.sleep(.fromMilliseconds(1000), .awake);
    }
}

const std = @import("std");
const agce = @import("agce");
const utils = @import("utils.zig");
