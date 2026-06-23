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

const std = @import("std");
const constants = @import("../constants.zig");
