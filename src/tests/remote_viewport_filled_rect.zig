pub fn main(init: std.process.Init) !void {
    const handle = try agce.init(
        init.io,
        init.gpa,
        init.environ_map,
    );
    defer handle.deinit();

    const viewport: *agce.ViewportHandle = try handle.viewport_create(
        .cpu,
        null,
        .{ .x = 0, .y = 0, .width = 0, .height = 0 },
        false,
    );
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
