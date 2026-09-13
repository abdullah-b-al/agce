pub const Linux = union(enum) {
    wayland: Wayland.Buffer,
};

pub const Buffer = switch (os) {
    .linux => Linux,
    .windows => void,
    else => unreachable,
};

const BufferFormat = ptypes.BufferFormat;
const ptypes = @import("protocol").types;
const cwl = @import("wayland").client.wl;
const xdg = @import("wayland").client.xdg;
const zwp = @import("wayland").client.zwp;
const wp = @import("wayland").client.wp;
const Wayland = @import("../wayland/Wayland.zig");
const WindowSystem = @import("../WindowSystem.zig");
const os = @import("builtin").os.tag;
