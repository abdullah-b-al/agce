pub const MessageFormat = enum(u32) {
    json,
};

pub const ClientUUID = enum(uuid.Uuid) {
    _,

    pub fn new(io: std.Io) ClientUUID {
        return @fromBackingInt(@intCast(uuid.v4.fromIo(io)));
    }

    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("ClientUUID({s})", .{uuid.urn.serialize(@backingInt(self))});
    }

    pub fn jsonParse(_: std.mem.Allocator, source: *std.json.Scanner, _: std.json.ParseOptions) std.json.ParseError(std.json.Scanner)!ClientUUID {
        const token = try source.next();
        const slice = switch (token) {
            .string => |slice| slice,
            else => return error.UnexpectedToken,
        };

        return deserialize(slice) catch |err| switch (err) {
            error.InvalidHexChar, error.MalformedUrn => return error.InvalidNumber,
        };
    }

    pub fn viewport_key(cuuid: ClientUUID, vp_id: ViewportID) ViewportKey {
        return .{ .client_uuid = cuuid, .viewport_id = vp_id };
    }

    pub fn jsonStringify(self: ClientUUID, stringify: *std.json.Stringify) error{WriteFailed}!void {
        try stringify.write(self.serialize());
    }

    pub fn serialize(id: ClientUUID) uuid.urn.Urn {
        return uuid.urn.serialize(@backingInt(id));
    }

    pub fn deserialize(slice: []const u8) !ClientUUID {
        return @fromBackingInt(@intCast(try uuid.urn.deserialize(slice)));
    }
};

pub const PID = enum(u32) {
    _,

    pub fn increment(id: *PID) PID {
        const int = @backingInt(id.*);
        id.* = @fromBackingInt(@intCast(int + 1));
        return @fromBackingInt(@intCast(int));
    }
};

pub const RequestID = enum(u32) {
    pub const first: @This() = @fromBackingInt(@intCast(1));

    _,

    pub fn increment(id: *RequestID) RequestID {
        const int = @backingInt(id.*);
        id.* = @fromBackingInt(@intCast(int + 1));
        return @fromBackingInt(@intCast(int));
    }
};

pub const ViewportID = enum(u32) {
    first_for_client = 1,
    first_for_server = std.math.maxInt(u16) + 1,

    _,

    pub fn increment_for_client(id: *ViewportID) ViewportID {
        std.debug.assert(!id.is_server_id());

        const int = @backingInt(id.*);
        id.* = @fromBackingInt(@intCast(int + 1));
        return @fromBackingInt(@intCast(int));
    }

    pub fn increment_for_server(id: *ViewportID) ViewportID {
        std.debug.assert(id.is_server_id());

        const int = @backingInt(id.*);
        id.* = @fromBackingInt(@intCast(int + 1));
        return @fromBackingInt(@intCast(int));
    }

    pub fn is_server_id(id: ViewportID) bool {
        return @backingInt(id) >= @backingInt(ViewportID.first_for_server);
    }

    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("ViewportID({})", .{@backingInt(self)});
    }
};

pub const RemoteViewportID = enum(u32) {
    pub const first: @This() = @fromBackingInt(@intCast(1));

    _,

    pub fn increment(id: *RemoteViewportID) RemoteViewportID {
        const int = @backingInt(id.*);
        id.* = @fromBackingInt(@intCast(int + 1));
        return @fromBackingInt(@intCast(int));
    }

    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("RemoteViewportID({})", .{@backingInt(self)});
    }
};

pub const BufferID = enum(u32) {
    pub const first: @This() = @fromBackingInt(@intCast(1));

    _,

    pub fn increment(this: *@This()) @This() {
        const int = @backingInt(this.*);
        this.* = @fromBackingInt(@intCast(int + 1));
        return @fromBackingInt(@intCast(int));
    }

    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("BufferID({})", .{@backingInt(self)});
    }
};

pub const ViewportKey = struct {
    client_uuid: ClientUUID,
    viewport_id: ViewportID,
};

pub const Status = enum { success, failure };

pub const RequestFailureReason = enum {
    unknown,
};

pub const AcquireTimelinePoint = enum(u64) {
    _,

    pub fn advance(p: *AcquireTimelinePoint) void {
        const int = @backingInt(p.*);
        p.* = @fromBackingInt(@intCast(int + 1));
    }

    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("AcquireTimelinePoint({})", .{@backingInt(self)});
    }
};

pub const ReleaseTimelinePoint = enum(u64) {
    _,

    pub fn advance(p: *ReleaseTimelinePoint) void {
        const int = @backingInt(p.*);
        p.* = @fromBackingInt(@intCast(int + 1));
    }

    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("ReleaseTimelinePoint({})", .{@backingInt(self)});
    }
};

pub const Rect = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,

    pub fn init(p: Pos, s: Size) Rect {
        return .{ .x = p.x, .y = p.y, .width = s.width, .height = s.height };
    }

    pub fn pos(r: Rect) Pos {
        return .{ .x = r.x, .y = r.y };
    }

    pub fn size(r: Rect) Size {
        return .{ .width = r.width, .height = r.height };
    }
};

pub const Pos = struct {
    x: i32,
    y: i32,

    pub fn from_rect(r: Rect) Pos {
        return .{ .x = r.x, .y = r.y };
    }
};

pub const Size = struct {
    width: i32,
    height: i32,

    pub fn from_rect(r: Rect) Size {
        return .{ .width = r.width, .height = r.height };
    }

    pub fn eql(a: Size, b: Size) bool {
        return a.width == b.width and
            a.height == b.height;
    }
};

pub const BufferFormat = enum {
    argb8888,

    pub fn bytes_per_pixel(fmt: BufferFormat) u8 {
        return switch (fmt) {
            .argb8888 => 4,
        };
    }
};

pub const BufferType = enum {
    cpu,
    gbm_bo,
    d11,
};

pub const ViewportDisplayState = enum {
    shown,
    hidden,
};

pub const ScrollAxis = enum(u8) {
    vertical,
    horizontal,
};

// Taken from wayland's cursor shape type
pub const CursorShape = enum {
    default,
    none,
    context_menu,
    help,
    pointer,
    progress,
    wait,
    cell,
    crosshair,
    text,
    vertical_text,
    alias,
    copy,
    move,
    no_drop,
    not_allowed,
    grab,
    grabbing,
    e_resize,
    n_resize,
    ne_resize,
    nw_resize,
    s_resize,
    se_resize,
    sw_resize,
    w_resize,
    ew_resize,
    ns_resize,
    nesw_resize,
    nwse_resize,
    col_resize,
    row_resize,
    all_scroll,
    zoom_in,
    zoom_out,
};

pub const CpuBufferHandle = switch (os) {
    .linux => Fd(opaque {}),
    .windows => WindowsHandle(opaque {}),
    else => unreachable,
};

////////////////////////////////////////////////////////////////////////////////
// Linux types

pub const GbmBoFd = Fd(opaque {});
pub const DrmSyncobjAcquireTimelineFd = Fd(opaque {});
pub const DrmSyncobjReleaseTimelineFd = Fd(opaque {});
pub const DrmSyncobjAcquireTimelineHandle = enum(u32) { _ };
pub const DrmSyncobjReleaseTimelineHandle = enum(u32) { _ };

pub const BufferAndTimelineFds = extern struct {
    pub const invalid: BufferAndTimelineFds = .{
        .buffer = .invalid,
        .acquire_timeline = .invalid,
        .release_timeline = .invalid,
    };

    buffer: GbmBoFd,
    acquire_timeline: DrmSyncobjAcquireTimelineFd,
    release_timeline: DrmSyncobjReleaseTimelineFd,
};

comptime {
    const A = Fd(opaque {});
    const B = Fd(opaque {});
    std.debug.assert(A != B);
}
pub fn Fd(comptime Opaque: type) type {
    return enum(c_int) {
        pub const is_fd = true;

        invalid = -1,
        _,

        pub fn close(fd: @This()) void {
            _ = std.os.linux.close(@backingInt(fd));
        }

        comptime {
            _ = Opaque;
        }
    };
}

// Linux types
////////////////////////////////////////////////////////////////////////////////

////////////////////////////////////////////////////////////////////////////////
// Windows types

pub fn WindowsHandle(comptime Opaque: type) type {
    const BackingInt = switch (@sizeOf(std.os.windows.HANDLE)) {
        8 => usize,
        else => unreachable,
    };

    return enum(BackingInt) {
        _,

        pub fn to_HANDLE(h: @This()) std.os.windows.HANDLE {
            if (os != .windows) @compileError("Windows only");

            return @ptrFromInt(@backingInt(h));
        }

        pub fn from_HANDLE(h: std.os.windows.HANDLE) @This() {
            if (os != .windows) @compileError("Windows only");

            return @fromBackingInt(@intCast(@intFromPtr(h)));
        }

        pub fn close(h: @This()) void {
            std.os.windows.CloseHandle(h.to_HANDLE());
        }

        comptime {
            _ = Opaque;
        }
    };
}

pub const D3DVersion = enum {
    d3d11,
};

pub const D3DTextureSharedHandle = WindowsHandle(opaque {});
pub const D3DAcquireFenceSharedHandle = WindowsHandle(opaque {});
pub const D3DReleaseFenceSharedHandle = WindowsHandle(opaque {});

// Windows types
////////////////////////////////////////////////////////////////////////////////

const std = @import("std");
const os = @import("builtin").os.tag;
const uuid = @import("uuid");
