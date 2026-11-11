pub fn format_field(value: anytype, comptime field_name: []const u8, writer: *Io.Writer) Io.Writer.Error!void {
    const field = @field(value, field_name);
    const T = @TypeOf(field);
    const is_container = switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum" => true,
        else => false,
    };

    try writer.print(".{s} = ", .{field_name});
    if (is_container and @hasDecl(T, "format")) {
        try writer.print("{f}", .{field});
    } else {
        try writer.print("{}", .{field});
    }
}

pub fn format_union(value: anytype, writer: *Io.Writer) Io.Writer.Error!void {
    switch (value) {
        inline else => |v, tag| {
            try format_active_union_field(v, @tagName(tag), writer);
        },
    }
}

pub fn format_active_union_field(value: anytype, comptime tag: []const u8, writer: *Io.Writer) Io.Writer.Error!void {
    const info = @typeInfo(@TypeOf(value));

    switch (info) {
        .@"struct" => {
            try writer.print(".{{ .{s} = ", .{tag});
            try format_struct(value, writer);
            try writer.print(" }}", .{});
        },
        .@"enum" => {
            if (@hasDecl(@TypeOf(value), "format")) {
                try writer.print("{f}", .{value});
            } else {
                try writer.print("{}", .{value});
            }
        },
        .void => {
            try writer.print(".{s}", .{tag});
        },
        else => |t| @compileError("TODO: " ++ @tagName(t)),
    }
}

pub fn format_struct(value: anytype, writer: *Io.Writer) Io.Writer.Error!void {
    try writer.print(".{{ ", .{});

    const info = @typeInfo(@TypeOf(value)).@"struct";
    inline for (info.fields, 0..) |field, i| {
        try format_field(value, field.name, writer);
        if (i < info.fields.len - 1) {
            try writer.print(", ", .{});
        }
    }

    try writer.print(" }}", .{});
}

pub fn new_dimensions(width: i32, height: i32) struct { i32, i32 } {
    return .{
        dimension_multiple_of(width, 640),
        dimension_multiple_of(height, 480),
    };
}

fn dimension_multiple_of(requested: i32, multiple_of: i32) i32 {
    var result: i32 = 0;

    while (result < requested) {
        result += multiple_of;
    }

    return result;
}

pub fn ErrorSetOf(comptime func: anytype) type {
    const T = @typeInfo(@TypeOf(func)).@"fn".return_type.?;
    return @typeInfo(T).error_union.error_set;
}

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const constants = @import("constants");
const known_folders = @import("known-folders");
