pub const Embeded = @import("Embeded.zig");
pub const Native = @import("Embeded.zig").Native;

const std = @import("std");
const Io = std.Io;
const compositor = @import("compositor");
const zio = @import("zio");
const LocalConnection = @import("LocalConnection.zig");
const log = std.log.scoped(.agce_embeded);
