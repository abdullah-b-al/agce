pub const socket_name = "agce.sock";
pub const socket_max_path = net.UnixAddress.max_len;

const net = @import("std").Io.net;
