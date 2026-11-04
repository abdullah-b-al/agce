const Window = @This();

id: WindowID,
handle: *Compositor.WindowHandle,
size: ptypes.Size,

pub fn init(args: Compositor.WindowRegister) Window {
    return .{
        .handle = args.handle,
        .id = args.id,
        .size = args.size,
    };
}

const std = @import("std");
const Compositor = @import("Compositor.zig");
const WindowID = Compositor.WindowID;
const ptypes = @import("protocol").types;
