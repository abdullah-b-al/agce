pub fn buffers_create(
    comptime Buffer: type,
    comptime count: usize,
    client: *Client,
    collection: *Collection(Buffer),
    buffer_init_args: anytype,
) ![count]Buffer {
    try collection.ensure_unused_capacity(client.gpa, count);
    try client.buffers_status.ensureUnusedCapacity(client.gpa, count);

    var array: [count]Buffer = undefined;

    var created: usize = 0;
    errdefer {
        for (0..created) |i| {
            // TODO: Send destroy message
            array[i].deinit();
        }
    }

    for (&array) |*b| {
        b.* = try @call(.auto, Buffer.init, buffer_init_args);
        created += 1;
    }

    for (array) |b| {
        try b.create_on_server(client);
        while (true) {
            try client.wait_for(.buffer_created);
            try client.update_by_tag(.buffer_created);
            switch (client.buffers_status.get(b.id).?) {
                .failed => return error.BufferCreateFailed,
                .created => {
                    log.debug("Buffer created {f} {}x{}", .{ b.id, b.width, b.height });
                    break;
                },
                .pending => continue,
            }
        }
    }

    return array;
}

pub fn buffers_resize(
    comptime Buffer: type,
    comptime count: usize,
    client: *Client,
    collection: *Collection(Buffer),
    buffer_init_args: anytype,
) !void {
    const array = try buffers_create(Buffer, count, client, collection, buffer_init_args);

    errdefer comptime unreachable;

    for (collection.available.values()) |b| {
        collection.old.putAssumeCapacityNoClobber(b.id, b);
        client.send_buffer_destroy(b.id) catch |err| {
            log.err("Could not send buffer_destroy message {}", .{err});
        };
    }
    collection.available.clearRetainingCapacity();

    for (array) |b| {
        collection.available.putAssumeCapacityNoClobber(b.id, b);
    }
}

pub fn new_dimensions(width: u32, height: u32) struct { u32, u32 } {
    return .{
        dimension_multiple_of(width, 640),
        dimension_multiple_of(height, 480),
    };
}

fn dimension_multiple_of(requested: u32, multiple_of: u32) u32 {
    var result: u32 = 0;

    while (result < requested) {
        result += multiple_of;
    }

    return result;
}

pub fn Collection(comptime Buffer: type) type {
    return struct {
        const Self = @This();

        available: std.array_hash_map.Auto(BufferID, Buffer),
        old: std.array_hash_map.Auto(BufferID, Buffer),

        pub const empty: Self = .{
            .available = .empty,
            .old = .empty,
        };

        pub fn deinit(b: *Self, gpa: std.mem.Allocator) void {
            const buffers = .{
                &b.available,
                &b.old,
            };

            inline for (buffers) |map| {
                for (map.values()) |*buffer| buffer.deinit();
            }

            inline for (buffers) |map| map.deinit(gpa);
        }

        pub fn ensure_unused_capacity(b: *Self, gpa: std.mem.Allocator, unused: usize) !void {
            const maps = .{
                &b.available,
                &b.old,
            };
            inline for (maps) |map| {
                try map.ensureUnusedCapacity(gpa, unused);
            }
        }

        pub fn has(b: *const Self, id: BufferID) bool {
            const maps = .{
                &b.available,
                &b.old,
            };

            inline for (maps) |map| {
                if (map.contains(id)) return true;
            }

            return false;
        }
    };
}

pub const Status = enum {
    available,
    old,
};

pub const CreateStatus = enum {
    created,
    failed,
};

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const ptypes = @import("protocol").types;
const ViewportID = ptypes.ViewportID;
const opengl = @import("opengl.zig");
const c_linux = @import("c_linux");
const glad = @import("glad");
const Client = @import("Client.zig");
const BufferID = ptypes.BufferID;
const log = std.log.scoped(.buffers);
