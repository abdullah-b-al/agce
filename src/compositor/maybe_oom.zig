var rand: std.Random.DefaultPrng = .init(0);

pub fn maybe_oom() error{OutOfMemory}!void {
    if (builtin.mode != .debug) return;

    const v = rand.random().float(f32);
    if (v <= 0.1) {
        return error.OutOfMemory;
    }
}

const std = @import("std");
const builtin = @import("builtin");
