pub fn render(viewport: *agce.ViewportHandle, color: u24) !void {
    const frame = try viewport.cpu_frame_begin();
    std.debug.assert(frame.bytes_per_pixel == 4);
    const ptr: [*]u32 = @ptrCast(@alignCast(frame.buffer.ptr));
    const buffer: []u32 = ptr[0 .. frame.buffer.len / frame.bytes_per_pixel];
    const a: u32 = 0xFF_00_00_00;
    const r: u32 = color & 0xFF_00_00;
    const g: u32 = color & 0x00_FF_00;
    const b: u32 = color & 0x00_00_FF;
    for (buffer) |*p| {
        p.* = a | r | g | b;
    }

    viewport.cpu_frame_end();
    try viewport.cpu_frame_present();
}

pub fn fade_color(
    elabsed_time: std.Io.Duration,
    fade_period: f64,
    red: f32,
    green: f32,
    blue: f32,
) u24 {
    const until_now: f64 = @floatFromInt(elabsed_time.toMilliseconds());
    const t = (@mod(until_now, fade_period)) / fade_period;

    const fade: f64 = if (t < 0.5)
        t * 2
    else
        (1 - t) * 2;

    // const ucolor: u32 = @intFromFloat(fade * target_color);
    // const color: u24 = @intCast((ucolor << 16) | (ucolor << 8) | ucolor);
    const r: u24 = @as(u24, @intFromFloat(fade * red)) << 16;
    const g: u24 = @as(u24, @intFromFloat(fade * green)) << 8;
    const b: u24 = @as(u24, @intFromFloat(fade * blue));
    return r | g | b;
}

const std = @import("std");
const agce = @import("agce");
