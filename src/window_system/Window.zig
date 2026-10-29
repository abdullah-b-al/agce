const Window = @This();

id: WindowID,
handle: *WindowSystem.WindowHandle,
size: ptypes.Size,

const std = @import("std");
const WindowSystem = @import("WindowSystem.zig");
const WindowID = WindowSystem.WindowID;
const ptypes = @import("protocol").types;
