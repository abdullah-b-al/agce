pub const socket_name = "agce.sock";
pub const socket_max_path = net.UnixAddress.max_len;
pub const env_expect_viewport_key = "AGCE_EXPECT_VIEWPORT";
pub const env_expect_viewport_true = "1";
pub const env_client_full_id = "AGCE_CLIENT_FULL_ID";

const net = @import("std").Io.net;
