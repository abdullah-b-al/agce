pub const MessageFormat = enum(u32) {
    json,
};

pub const ClientID = enum(u32) {
    pub const first: ClientID = @enumFromInt(1);
    _,

    pub fn increment(id: *ClientID) ClientID {
        const int = @intFromEnum(id.*);
        id.* = @enumFromInt(int + 1);
        return @enumFromInt(int);
    }

    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("ClientID({})", .{@intFromEnum(self)});
    }
};

pub const ClientFingerprint = enum(u32) {
    _,

    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("ClientFingerprint({})", .{@intFromEnum(self)});
    }
};

pub const ClientFullID = struct {
    const env_string_delimiter = ',';
    const env_string_fmt = "{}" ++ .{env_string_delimiter} ++ "{}";
    pub const env_string_max_len = blk: {
        const out = std.fmt.comptimePrint(env_string_fmt, .{
            std.math.maxInt(u32),
            std.math.maxInt(u32),
        });
        break :blk out.len;
    };

    id: ClientID,
    fingerprint: ClientFingerprint,

    pub fn to_env_string(fid: ClientFullID, buf: []u8) []const u8 {
        std.debug.assert(buf.len >= env_string_max_len);

        return std.fmt.bufPrint(buf, env_string_fmt, .{
            @intFromEnum(fid.id),
            @intFromEnum(fid.fingerprint),
        }) catch unreachable;
    }

    pub fn from_env_string(string: []const u8) ?ClientFullID {
        var iter = std.mem.splitScalar(u8, string, env_string_delimiter);
        const id = iter.next() orelse return null;
        const fp = iter.next() orelse return null;

        return .{
            .id = @enumFromInt(std.fmt.parseInt(u32, id, 10) catch return null),
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

pub const SubViewportID = enum(u32) {
    pub const first: @This() = @enumFromInt(1);

    _,

    pub fn increment(id: *SubViewportID) SubViewportID {
        const int = @intFromEnum(id.*);
        id.* = @enumFromInt(int + 1);
        return @enumFromInt(int);
    }

    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("SubViewportID({})", .{@intFromEnum(self)});
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

pub const CpuBufferFd = enum(c_int) {
    pub const is_fd = true;

    invalid_fd = -1,
    _,
};

pub const GpuBufferFd = enum(c_int) {
    pub const is_fd = true;

    invalid_fd = -1,
    _,
};

pub const AcquireTimelineFd = enum(c_int) {
    pub const is_fd = true;

    invalid_fd = -1,
    _,
};

pub const ReleaseTimelineFd = enum(c_int) {
    pub const is_fd = true;

    invalid_fd = -1,
    _,
};

pub const Status = enum { success, failure };

pub const AcquireTimelineHandle = enum(u32) { _ };
pub const ReleaseTimelineHandle = enum(u32) { _ };

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
    x: u32,
    y: u32,
    width: u32,
    height: u32,
};

pub const BufferFormat = enum {
    argb8888,

    pub fn bytes_per_pixel(fmt: BufferFormat) u8 {
        return switch (fmt) {
            .argb8888 => 4,
        };
    }
};

pub const BufferAndTimelineFds = extern struct {
    pub const invalid_fd: BufferAndTimelineFds = .{
        .buffer = .invalid_fd,
        .acquire_timeline = .invalid_fd,
        .release_timeline = .invalid_fd,
    };

    buffer: GpuBufferFd,
    acquire_timeline: AcquireTimelineFd,
    release_timeline: ReleaseTimelineFd,
};

pub const WindowCreate = struct {
    viewport_id: ViewportID,
    width: u32,
    height: u32,
    create_sync_timeline: bool,
    vsync: bool,
};

pub const ViewportResize = struct {
    viewport_id: ViewportID,
    width: u32,
    height: u32,
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

pub const ClientInfo = struct {
    pub const empty: ClientInfo = .{
        .name = &.{},
    };

    name: []const u8,
};

pub const ClientInfoCloneManaged = struct {
    gpa: std.mem.Allocator,
    unmanaged: ClientInfoClone,

    pub fn clone(gpa: std.mem.Allocator, info: ClientInfo) !ClientInfoCloneManaged {
        return .{ .gpa = gpa, .unmanaged = try .clone(gpa, info) };
    }

    pub fn deinit(managed: *ClientInfoCloneManaged) void {
        managed.unmanaged.deinit(managed.gpa);
    }
};

pub const ClientInfoClone = struct {
    strings: []const u8,

    name: String,

    pub fn clone(gpa: std.mem.Allocator, info: ClientInfo) !ClientInfoClone {
        const len = info.name.len;
        const strings = try gpa.alloc(u8, len);
        errdefer comptime unreachable;

        var builder: StringsBuilder = .{ .buffer = strings, .i = 0 };

        const result: ClientInfoClone = .{
            .strings = strings,
            .name = builder.copy(info.name),
        };

        std.debug.assert(builder.i == strings.len);

        return result;
    }

    pub fn dupe(gpa: std.mem.Allocator, info: ClientInfoClone) error{OutOfMemory}!ClientInfoClone {
        return .{
            .strings = try gpa.dupe(u8, info.strings),
            .name = info.name,
        };
    }

    pub fn deinit(info: *ClientInfoClone, gpa: std.mem.Allocator) void {
        gpa.free(info.strings);
        info.strings = undefined;
    }

    pub const String = struct { offset: u32, len: u32 };

    const StringsBuilder = struct {
        buffer: []u8,
        i: u32,

        pub fn copy(builder: *StringsBuilder, string: []const u8) String {
            const result: String = .{ .offset = builder.i, .len = @intCast(string.len) };
            std.mem.copyForwards(u8, builder.buffer[builder.i..], string);
            builder.i += @intCast(string.len);
            return result;
        }
    };
};

pub fn MessageHeaderGeneric(comptime MessageTag: type) type {
    return extern struct {
        const Header = @This();

        len: u32,
        format: MessageFormat,
        message_tag: MessageTag,

        comptime {
            if (@sizeOf(Header) != 12) {
                @compileError("Header size changed. It must always be 12 bytes long");
            }
        }

        pub fn parse(data: []const u8) !Header {
            std.debug.assert(@sizeOf(Header) == data.len);

            const header_len = parse_len(data);
            const header_format = try parse_format(data);
            const header_message_tag = try parse_message_tag(data);

            return .{
                .len = header_len,
                .format = header_format,
                .message_tag = header_message_tag,
            };
        }

        fn parse_len(data: []const u8) @FieldType(Header, "len") {
            return parse_int_of("len", data);
        }

        fn parse_format(data: []const u8) error{HeaderInvalidFormat}!@FieldType(Header, "format") {
            const int = parse_int_of("format", data);
            return std.enums.fromInt(MessageFormat, int) orelse error.HeaderInvalidFormat;
        }

        fn parse_message_tag(data: []const u8) error{HeaderInvalidMessageTag}!@FieldType(Header, "message_tag") {
            const int = parse_int_of("message_tag", data);
            return std.enums.fromInt(MessageTag, int) orelse error.HeaderInvalidMessageTag;
        }

        fn parse_int_of(comptime name: []const u8, data: []const u8) u32 {
            std.debug.assert(data.len >= @sizeOf(Header));

            const F = @FieldType(Header, name);
            const offset = @offsetOf(Header, name);
            const len = @sizeOf(F);

            const slice = data[offset..][0..len];
            const int = std.mem.bytesToValue(u32, slice);
            return int;
        }
    };
}

const std = @import("std");
