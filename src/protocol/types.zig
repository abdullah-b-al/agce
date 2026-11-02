pub const MessageFormat = enum(u32) {
    json,
};

pub const ClientUUID = enum(uuid.Uuid) {
    _,

    pub fn new(io: std.Io) ClientUUID {
        return @enumFromInt(uuid.v4.new(io));
    }

    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("ClientUUID({s})", .{uuid.urn.serialize(@intFromEnum(self))});
    }

    pub fn jsonParse(_: std.mem.Allocator, source: *std.json.Scanner, _: std.json.ParseOptions) std.json.ParseError(std.json.Scanner)!ClientUUID {
        const token = try source.next();
        const slice = switch (token) {
            .string => |slice| slice,
            else => return error.UnexpectedToken,
        };

        const int = uuid.urn.deserialize(slice) catch |err| switch (err) {
            error.InvalidHexChar, error.MalformedUrn => return error.InvalidNumber,
        };

        return @enumFromInt(int);
    }

    pub fn jsonStringify(self: ClientUUID, stringify: *std.json.Stringify) error{WriteFailed}!void {
        const slice = uuid.urn.serialize(@intFromEnum(self));
        try stringify.write(slice);
    }
};

pub const ClientFingerprint = enum(u32) {
    _,

    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("ClientFingerprint({})", .{@intFromEnum(self)});
    }
};

pub const PID = enum(u32) {
    _,

    pub fn increment(id: *PID) PID {
        const int = @intFromEnum(id.*);
        id.* = @enumFromInt(int + 1);
        return @enumFromInt(int);
    }
};

pub const ClientFullID = struct {
    id: ClientUUID,
    fingerprint: ClientFingerprint,

    const env_string_delimiter = ',';
    const env_string_fmt = "{s}" ++ .{env_string_delimiter} ++ "{}";
    pub const env_string_max_len = blk: {
        const out = std.fmt.comptimePrint(",{}", .{
            std.math.maxInt(u32),
        });
        break :blk out.len + @sizeOf(uuid.urn.Urn);
    };

    pub fn to_env_string(fid: ClientFullID, buf: []u8) []const u8 {
        std.debug.assert(buf.len >= env_string_max_len);

        return std.fmt.bufPrint(buf, env_string_fmt, .{
            uuid.urn.serialize(@intFromEnum(fid.id)),
            @intFromEnum(fid.fingerprint),
        }) catch unreachable;
    }

    pub fn from_env_string(string: []const u8) ?ClientFullID {
        var iter = std.mem.splitScalar(u8, string, env_string_delimiter);
        const id = iter.next() orelse return null;
        const fp = iter.next() orelse return null;

        return .{
            .id = @enumFromInt(uuid.urn.deserialize(id) catch return null),
            .fingerprint = @enumFromInt(std.fmt.parseInt(u32, fp, 10) catch return null),
        };
    }

    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("ClientFullID({},{})", .{
            @intFromEnum(self.id),
            @intFromEnum(self.fingerprint),
        });
    }
};

pub const ViewportID = enum(u32) {
    first_for_client = 1,
    first_for_server = std.math.maxInt(u16) + 1,

    _,

    pub fn increment_for_client(id: *ViewportID) ViewportID {
        std.debug.assert(!id.is_server_id());

        const int = @intFromEnum(id.*);
        id.* = @enumFromInt(int + 1);
        return @enumFromInt(int);
    }

    pub fn increment_for_server(id: *ViewportID) ViewportID {
        std.debug.assert(id.is_server_id());

        const int = @intFromEnum(id.*);
        id.* = @enumFromInt(int + 1);
        return @enumFromInt(int);
    }

    pub fn is_server_id(id: ViewportID) bool {
        return @intFromEnum(id) >= @intFromEnum(ViewportID.first_for_server);
    }

    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("ViewportID({})", .{@intFromEnum(self)});
    }
};

pub const RemoteViewportID = enum(u32) {
    pub const first: @This() = @enumFromInt(1);

    _,

    pub fn increment(id: *RemoteViewportID) RemoteViewportID {
        const int = @intFromEnum(id.*);
        id.* = @enumFromInt(int + 1);
        return @enumFromInt(int);
    }

    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("RemoteViewportID({})", .{@intFromEnum(self)});
    }
};

pub const BufferID = enum(u32) {
    pub const first: @This() = @enumFromInt(1);

    _,

    pub fn increment(this: *@This()) @This() {
        const int = @intFromEnum(this.*);
        this.* = @enumFromInt(int + 1);
        return @enumFromInt(int);
    }

    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("BufferID({})", .{@intFromEnum(self)});
    }
};

pub const ViewportKey = struct {
    client_uuid: ClientUUID,
    viewport_id: ViewportID,
};

pub const Status = enum { success, failure };

pub const AcquireTimelinePoint = enum(u64) {
    _,

    pub fn advance(p: *AcquireTimelinePoint) void {
        const int = @intFromEnum(p.*);
        p.* = @enumFromInt(int + 1);
    }

    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("AcquireTimelinePoint({})", .{@intFromEnum(self)});
    }
};

pub const ReleaseTimelinePoint = enum(u64) {
    _,

    pub fn advance(p: *ReleaseTimelinePoint) void {
        const int = @intFromEnum(p.*);
        p.* = @enumFromInt(int + 1);
    }

    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("ReleaseTimelinePoint({})", .{@intFromEnum(self)});
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
};

pub const BufferFormat = enum {
    argb8888,

    pub fn bytes_per_pixel(fmt: BufferFormat) u8 {
        return switch (fmt) {
            .argb8888 => 4,
        };
    }
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
            _ = std.os.linux.close(@intFromEnum(fd));
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

            return @ptrFromInt(@intFromEnum(h));
        }

        pub fn from_HANDLE(h: std.os.windows.HANDLE) @This() {
            if (os != .windows) @compileError("Windows only");

            return @enumFromInt(@intFromPtr(h));
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
