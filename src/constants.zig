pub const socket_dir_name = "agce";
pub const socket_mux_file_name = "mux" ++ "." ++ socket_extension;
pub const socket_extension = "sock";
pub const socket_max_path = net.UnixAddress.max_len;
pub const env_agce_socket_path = "AGCE_SOCKET_PATH";
pub const env_client_uuid = "AGCE_CLIENT_UUID";
pub const payload_max_size = 512;

pub const os_has_gbm = switch (os) {
    .linux => true,
    else => false,
};

pub const os_has_d3d = switch (os) {
    .windows => true,
    else => false,
};

pub const os_supports_fd = switch (os) {
    .linux => true,
    else => false,
};

pub const os_supports_wayland = switch (os) {
    .linux => true,
    else => false,
};

const net = @import("std").Io.net;
const os = @import("builtin").os.tag;
