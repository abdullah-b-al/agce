pub const WindowBase = @This();

id: WindowID,
viewport_key: ViewportKey,

pub const WindowID = enum(u32) {
    pub const first: WindowID = @enumFromInt(1);
    _,
};

const WindowSystem = @import("WindowSystem.zig");
const ViewportKey = WindowSystem.ViewportKey;
