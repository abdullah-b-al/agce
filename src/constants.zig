pub const socket_name = "agce.sock";
pub const socket_max_path = net.UnixAddress.max_len;
pub const env_flag_expect_viewport_key = "AGCE_EXPECT_VIEWPORT";
pub const env_flag_expect_viewport_true = "1";

const net = @import("std").Io.net;
