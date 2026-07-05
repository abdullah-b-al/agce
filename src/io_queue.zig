pub fn IoQueue(comptime T: type) type {
    return struct {
        io: Io,
        gpa: std.mem.Allocator,
        buffer: []T,
        queue: Io.Queue(T),

        pub const Event = T;

        pub fn create(io: Io, gpa: std.mem.Allocator) !*@This() {
            const queue = try gpa.create(@This());
            errdefer gpa.destroy(queue);
            queue.* = try .init(io, gpa);
            return queue;
        }

        pub fn init(io: Io, gpa: std.mem.Allocator) !@This() {
            const buffer = try gpa.alloc(T, 512);
            return .{
                .io = io,
                .gpa = gpa,
                .buffer = buffer,
                .queue = .init(buffer),
            };
        }

        pub fn put(queue: *@This(), event: T) void {
            queue.queue.putOneUncancelable(queue.io, event) catch |err| switch (err) {
                error.Closed => unreachable,
            };
        }

        pub fn get(queue: *@This()) T {
            return queue.queue.getOneUncancelable(queue.io) catch |err| switch (err) {
                error.Closed => unreachable,
            };
        }
    };
}

const std = @import("std");
const Io = std.Io;
