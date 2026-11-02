pub fn main(init: std.process.Init) !void {
    const handle = try agce.init(
        init.io,
        init.gpa,
        init.environ_map,
    );
    defer handle.deinit();

    std.debug.assert(handle.expect_viewport());
    const viewport: *agce.ViewportHandle = blk: while (true) {
        try handle.poll(std.math.maxInt(u64));

        if (handle.viewport_pending_peek()) |result| {
            break :blk try handle.viewport_create_from_pending(
                .cpu,
                result.id,
                result.requsted_size,
                false,
            );
        }
        return;
    };
    defer viewport.destroy();

    const time = Io.Timestamp.now(init.io, .awake);
    var rand: std.Random.DefaultPrng = .init(@intCast(time.nanoseconds));

    const color = rand.random().int(u32) | 0xFF000000;
    while (true) {
        try handle.poll(1);

        try shared.render_cpu(viewport, color);
        try init.io.sleep(.fromMilliseconds(16), .awake);
    }
}

const std = @import("std");
const Io = std.Io;

const agce = @import("client");
const shared = @import("shared.zig");
