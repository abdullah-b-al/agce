pub const Embeded = @import("Embeded.zig");
pub const Native = @import("Embeded.zig").Native;
pub const Process = @import("remote_client").Process;
pub const RemoteClient = @import("remote_client").RemoteClient;

const std = @import("std");
const Io = std.Io;
const compositor = @import("compositor");
const zio = @import("zio");
const LocalConnection = @import("LocalConnection.zig");
