pub const socket_name = "agce.sock";
pub const socket_max_path = net.UnixAddress.max_len;

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const math = std.math;
