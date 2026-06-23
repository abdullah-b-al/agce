pub fn unix_address_path(environ: *const std.process.Environ.Map, buf: []u8) []const u8 {
    std.debug.assert(buf.len >= constants.socket_max_path);

    if (environ.get("XDG_RUNTIME_DIR")) |value| {
        std.debug.assert(value.len + constants.socket_name.len <= buf.len);
        return std.fmt.bufPrint(
            buf,
            "{s}{c}{s}",
            .{ value, std.fs.path.sep, constants.socket_name },
        ) catch unreachable;
    }

    std.mem.copyForwards(u8, buf, constants.socket_name);
    return buf[0..constants.socket_name.len];
}

pub const DimensionData = struct {
    width: i32,
    height: i32,
    bpp: u8,
};

pub fn pixels_copy(target: []u8, target_data: DimensionData, source: []const u8, source_data: DimensionData) void {
    std.debug.assert(target_data.bpp == source_data.bpp);

    const min_height = @min(source_data.height, target_data.height);
    const min_width = @min(source_data.width, target_data.width);

    const source_full_stride: usize = @intCast(source_data.width * source_data.bpp);
    const target_full_stride: usize = @intCast(target_data.width * target_data.bpp);

    const source_min_stride: usize = @intCast(min_width * source_data.bpp);
    const target_min_stride: usize = @intCast(min_width * target_data.bpp);

    var source_i: usize = 0;
    var target_j: usize = 0;
    for (0..@intCast(min_height)) |_| {
        const s = source[source_i..][0..source_min_stride];
        const t = target[target_j..][0..target_min_stride];

        std.mem.copyForwards(u8, t, s);

        source_i += source_full_stride;
        target_j += target_full_stride;
    }
}

const std = @import("std");
const constants = @import("../constants.zig");
