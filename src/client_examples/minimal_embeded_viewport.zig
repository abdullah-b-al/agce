pub fn main(init: std.process.Init) !void {
    const handle = try agce.init(
        init.io,
        init.gpa,
        init.environ_map,
        .{ .name = "minimal_embeded_viewport" },
    );
    defer agce.deinit(handle);

    const viewport = blk: while (true) {
        try agce.poll_once(handle, .none);
        try agce.update(handle);

        if (agce.viewport_pending_peek(handle)) |id| {
            break :blk try agce.cpu_viewport_create_from_pending(handle, id);
        }
    };

    var rand: std.Random.DefaultPrng = .init(0);
    while (true) {
        try agce.poll(handle, .{ .deadline = .{ .raw = .fromNanoseconds(1), .clock = .awake } });
        try agce.update(handle);

        try utils.render(handle, viewport, rand.random().int(u24));
        try init.io.sleep(.fromMilliseconds(1000), .awake);
    }
}

const std = @import("std");
const agce = @import("agce");
const utils = @import("utils.zig");
