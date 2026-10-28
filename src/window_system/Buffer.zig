pub const Buffer = @This();

native: Native,

pub fn init(native: Native) Buffer {
    return .{ .native = native };
}

pub fn deinit(b: *Buffer) void {
    b.native.deinit();
}

pub fn init_wayland(b: Wayland.Buffer) Buffer {
    return .init(.{ .wayland = b });
}

pub fn init_win32(b: Win32.Buffer) Buffer {
    return .init(b);
}

pub fn format(b: Buffer) BufferFormat {
    return b.native.format();
}

pub const Linux = union(enum) {
    wayland: Wayland.Buffer,

    pub fn format(b: Linux) ptypes.BufferFormat {
        return switch (b) {
            inline else => |v| v.format(),
        };
    }
};

pub const Native = switch (os) {
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
const WindowSystem = @import("WindowSystem.zig");
const os = @import("builtin").os.tag;
