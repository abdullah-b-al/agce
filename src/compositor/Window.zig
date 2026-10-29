const Window = @This();

id: WindowID,
handle: *Compositor.WindowHandle,
size: ptypes.Size,

const std = @import("std");
const Compositor = @import("Compositor.zig");
const WindowID = Compositor.WindowID;
const ptypes = @import("protocol").types;
