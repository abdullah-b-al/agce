pub const Message = struct {
    header: MessageHeader,
    data: []const u8,

    pub fn init(data: []const u8, format: MessageFormat, tag: MessageTag) Message {
        return .{
            .header = .{
                .len = @intCast(data.len + @sizeOf(MessageHeader)),
                .format = format,
                .message_tag = tag,
            },
            .data = data,
        };
    }
};

pub const MessageHeader = extern struct {
    len: u32,
    format: MessageFormat,
    message_tag: MessageTag,

    comptime {
        if (@sizeOf(MessageHeader) != 12) {
            @compileError("Header size changed. It must always be 12 bytes long");
        }
    }

    pub fn parse(data: []const u8) !MessageHeader {
        std.debug.assert(@sizeOf(MessageHeader) == data.len);

        const header_len = parse_len(data);
        const header_format = try parse_format(data);
        const header_message_tag = try parse_message_tag(data);

        return .{
            .len = header_len,
            .format = header_format,
            .message_tag = header_message_tag,
        };
    }

    fn parse_len(data: []const u8) @FieldType(MessageHeader, "len") {
        return parse_int_of("len", data);
    }

    fn parse_format(data: []const u8) error{HeaderInvalidFormat}!@FieldType(MessageHeader, "format") {
        const int = parse_int_of("format", data);
        return std.enums.fromInt(MessageFormat, int) orelse error.HeaderInvalidFormat;
    }

    fn parse_message_tag(data: []const u8) error{HeaderInvalidMessageTag}!@FieldType(MessageHeader, "message_tag") {
        const int = parse_int_of("message_tag", data);
        return std.enums.fromInt(MessageTag, int) orelse error.HeaderInvalidMessageTag;
    }

    fn parse_int_of(comptime name: []const u8, data: []const u8) u32 {
        std.debug.assert(data.len >= @sizeOf(MessageHeader));

        const F = @FieldType(MessageHeader, name);
        const offset = @offsetOf(MessageHeader, name);
        const len = @sizeOf(F);

        const slice = data[offset..][0..len];
        const int = std.mem.bytesToValue(u32, slice);
        return int;
    }
};

pub const MessageFormat = enum(u32) {
    json,
};

pub const MessageTag = enum(u32) {
    viewport_create_with_fds,
    viewport_buffers_swap,
    window_create,
};

pub const ViewportID = enum(u32) { _ };
pub const ViewportFds = extern struct {
    front: c_int,
    back: c_int,
};

pub const ViewportSize = struct {
    width: u32,
    height: u32,
    bpp: u8,
};

pub const MessageFromClient = union(MessageTag) {
    viewport_create_with_fds: ViewportCreateWithSharedFd,
    viewport_buffers_swap: ViewportBuffersSwap,

    window_create: WindowCreate,

    pub const ViewportCreateWithSharedFd = struct {
        id: ViewportID,
        size: ViewportSize,
        fds: ViewportFds,
    };
};

pub const MessageToServer = union(MessageTag) {
    viewport_create_with_fds: ViewportCreateWithSharedFd,
    viewport_buffers_swap: ViewportBuffersSwap,

    window_create: WindowCreate,

    pub const ViewportCreateWithSharedFd = struct {
        id: ViewportID,
        size: ViewportSize,
    };
};

const WindowCreate = struct {
    viewport_id: ViewportID,
};

const ViewportBuffersSwap = struct {
    viewport_id: ViewportID,
};

const std = @import("std");
