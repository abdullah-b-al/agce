const EventQueue = @This();

gpa: std.mem.Allocator,
list: std.DoublyLinkedList,
pool: std.heap.memory_pool.Extra(Node, .{ .growable = false }),
capacity: usize,

pub fn init(gpa: std.mem.Allocator) EventQueue {
    return .{
        .gpa = gpa,
        .list = .{},
        .pool = .empty,
        .capacity = 0,
    };
}

pub fn deinit(q: *EventQueue) void {

    // TODO: leak checking

    // Frees all nodes in and out of .list
    q.pool.deinit(q.gpa);
}

pub fn ensure_unused_capacity(q: *EventQueue, cap: usize) !void {
    if (q.capacity >= cap) return;

    const len = cap - q.capacity;
    for (0..len) |_| {
        try q.pool.addCapacity(q.gpa, 1);
        q.capacity += 1;
    }
}

pub fn create_assume_capacity(q: *EventQueue) *Node {
    std.debug.assert(q.capacity > 0);

    q.capacity -= 1;
    const ptr = q.pool.create(q.gpa) catch unreachable;
    ptr.node = .{};
    return ptr;
}

pub fn destroy(q: *EventQueue, ptr: *Node) void {
    std.debug.assert(ptr.node.next == null);
    std.debug.assert(ptr.node.prev == null);
    q.pool.destroy(ptr);
    q.capacity += 1;
}

pub fn push_assume_capacity(q: *EventQueue, event: Event) void {
    const node = q.create_assume_capacity();
    q.push(node, event);
}

pub fn push(q: *EventQueue, ptr: *Node, event: Event) void {
    std.debug.assert(ptr.node.next == null);
    std.debug.assert(ptr.node.prev == null);
    ptr.* = .{ .event = event, .node = .{} };
    q.list.append(&ptr.node);
}

pub fn pop(q: *EventQueue) ?*Node {
    const node = q.list.popFirst() orelse return null;

    const ptr: *Node = @alignCast(@fieldParentPtr("node", node));

    ptr.node.next = null;
    ptr.node.prev = null;

    return ptr;
}

pub fn peek(q: *EventQueue) ?*Node {
    const node = q.list.first orelse return null;
    const ptr: *Node = @alignCast(@fieldParentPtr("node", node));
    return ptr;
}

pub const Node = struct {
    event: Event,
    node: std.DoublyLinkedList.Node,
};

const std = @import("std");
const Event = @import("Server.zig").Event;
const ptypes = @import("protocol").types;
