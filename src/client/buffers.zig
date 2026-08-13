pub fn Buffers(comptime Buffer: type) type {
    return struct {
        const Self = @This();

        available: std.ArrayList(Buffer),
        pending: std.ArrayList(Buffer),
        old: std.ArrayList(Buffer),

        pub const empty: Self = .{
            .available = .empty,
            .pending = .empty,
            .old = .empty,
        };

        pub fn deinit(b: *Self, gpa: std.mem.Allocator) void {
            const buffers_table = .{
                &b.old,
                &b.pending,
                &b.available,
            };

            // TODO: Add a check that the buffer must be released. Failure means a leaked buffer.
            inline for (buffers_table) |list| {
                for (list.items) |*buffer| buffer.deinit();
            }

            inline for (buffers_table) |list| {
                list.deinit(gpa);
            }
        }

        pub fn ensure_unused_capacity(b: *Self, gpa: std.mem.Allocator, unused: usize) !void {
            try b.pending.ensureUnusedCapacity(gpa, unused);
            try b.old.ensureUnusedCapacity(gpa, unused);
            try b.available.ensureUnusedCapacity(gpa, unused);
        }

        pub fn has(b: *const Self, id: BufferID) bool {
            const buffers_table = .{
                b.old.items,
                b.pending.items,
                b.available.items,
            };

            inline for (buffers_table) |items| {
                for (items) |buffer| {
                    if (buffer.id == id) {
                        return true;
                    }
                }
            }

            return false;
        }

        pub fn pending_index_from_id(b: *Self, id: BufferID) ?usize {
            for (b.pending.items, 0..) |buffer, i| {
                if (buffer.id == id) {
                    return i;
                }
            }
            return null;
        }

        pub fn available_index_from_id(b: *Self, id: BufferID) ?usize {
            for (b.available.items, 0..) |buffer, i| {
                if (buffer.id == id) {
                    return i;
                }
            }
            return null;
        }

        pub fn buffer_created(b: *Self, id: BufferID) void {
            const index = b.pending_index_from_id(id) orelse return;
            const buffer = b.pending.orderedRemove(index);
            b.available.appendAssumeCapacity(buffer);
        }
    };
}

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
