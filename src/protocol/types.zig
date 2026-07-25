pub const client_to_server = @import("client_to_server.zig");
pub const server_to_client = @import("server_to_client.zig");

pub const MessageFormat = enum(u32) {
    json,
};

pub const ViewportID = enum(u32) { _ };

pub const BufferID = enum(u32) {
    pub const first: @This() = @enumFromInt(1);

    _,

    pub fn increment(this: *@This()) @This() {
        const int = @intFromEnum(this.*);
        this.* = @enumFromInt(int + 1);
        return @enumFromInt(int);
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

pub const BufferAndTimelineFds = extern struct {
    buffer: c_int,
    acquire_timeline: c_int,
    release_timeline: c_int,
};

pub const WindowCreate = struct {
    viewport_id: ViewportID,
    width: u32,
    height: u32,
    create_sync_timeline: bool,
};

pub const ViewportBuffersSwap = struct {
    viewport_id: ViewportID,
};

pub const ViewportResize = struct {
    viewport_id: ViewportID,
    width: u32,
    height: u32,
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
const constants = @import("../constants.zig");
