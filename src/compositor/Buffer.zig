pub const Buffer = @This();

backend: Backend,

pub fn init(backend: Backend) Buffer {
    return .{ .backend = backend };
}

pub fn deinit(b: *Buffer) void {
    b.backend.deinit();
}

pub fn init_wayland(b: Wayland.Buffer) Buffer {
    return .init(.{ .wayland = b });
}

pub fn init_win32(b: Win32.Buffer) Buffer {
    return .init(b);
}

pub fn format(b: Buffer) BufferFormat {
    return b.backend.format();
}

pub const Linux = union(enum) {
    wayland: Wayland.Buffer,

    pub fn format(b: Linux) ptypes.BufferFormat {
        return switch (b) {
            inline else => |v| v.format(),
        };
    }
};

pub const Backend = switch (os) {
    .linux => Linux,
    .windows => Win32.Buffer,
    else => unreachable,
};

const BufferFormat = ptypes.BufferFormat;
const ptypes = @import("protocol").types;
const cwl = @import("wayland").client.wl;
const xdg = @import("wayland").client.xdg;
const zwp = @import("wayland").client.zwp;
const wp = @import("wayland").client.wp;
const Wayland = @import("wayland/Wayland.zig");
const Win32 = @import("win32/Win32.zig");
const Compositor = @import("Compositor.zig");
const os = @import("builtin").os.tag;
