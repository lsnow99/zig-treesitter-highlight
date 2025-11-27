const std = @import("std");

fn QueueNodeT(Child: type) type {
    return struct {
        data: Child,
        next: ?*QueueNodeT(Child),
    };
}
fn IteratorT(Child: type) type {
    return struct {
        cur: ?*QueueNodeT(Child),

        pub fn next(self: *@This()) ?Child {
            if (self.cur) |cur| {
                self.cur = cur.next;
                return cur.data;
            }
            return null;
        }
    };
}

pub fn ComptimeBufferedQueue(comptime Child: type, buffer_size: comptime_int) type {
    return struct {
        const Self = @This();

        buffer: [buffer_size]?Child = [buffer_size]?Child{},
        start: usize = 0,
        len: usize = 0,

        pub fn peek(self: *Self) ?Child {
            if (self.len == 0) {
                return null;
            }
            std.debug.assert(self.start >= 0);
            std.debug.assert(self.start < buffer_size);
            return self.buffer[self.start];
        }

        pub fn enqueue(self: *Self, value: Child) void {
            const next_ix = (self.start + self.len) % buffer_size;
            self.buffer[next_ix] = value;
            self.len += 1;
            std.debug.assert(self.len > 0);
            std.debug.assert(self.len <= buffer_size);
        }

        pub fn dequeue(self: *Self) ?Child {
            if (self.len == 0) {
                return null;
            }
            const last_ix = (self.start + self.len - 1) % buffer_size;
            self.start = (self.start + 1) % buffer_size;
            self.len -= 1;
            std.debug.assert(self.len >= 0);
            std.debug.assert(self.len < buffer_size);
            return self.buffer[last_ix];
        }

        pub fn pushLeft(self: *Self, value: Child) void {
            self.start = (self.start - 1) % buffer_size;
            self.len += 1;
            self.buffer[self.start] = value;
            std.debug.assert(self.len > 0);
            std.debug.assert(self.len <= buffer_size);
        }

        pub fn clear(self: *Self, zero: bool) void {
            if (zero) {
                for (0..buffer_size) |i| {
                    self.buffer[i] = null;
                }
            }
            self.start = 0;
            self.len = 0;
        }

        // Modifying the queue while iterating is undefined.
        // pub fn iter(self: *Self) type {
        //     return struct {
        //         num_returned: usize,
        //         queue: *Self,
        //
        //         pub fn next(self: *@This()) ?Child {
        //             if (num_returned == self.queue.len) {
        //                 return null;
        //             }
        //             const next_ix = (self.start + self.num_returned) % buffer_size;
        //             self.num_returned += 1;
        //             return self.queue.buffer[next_ix];
        //         }
        //     };
        // }
    };
}

pub fn Queue(comptime Child: type) type {
    return struct {
        const Self = @This();
        const QueueNode = QueueNodeT(Child);

        arena: std.heap.ArenaAllocator,
        start: ?*QueueNode,
        end: ?*QueueNode,
        len: usize = 0,

        pub fn init(allocator: std.mem.Allocator) Self {
            return Self{
                .arena = std.heap.ArenaAllocator.init(allocator),
                .start = null,
                .end = null,
            };
        }
        pub fn peek(self: *Self) ?Child {
            return if (self.start) |start| start.data else null;
        }
        pub fn enqueue(self: *Self, value: Child) !void {
            const node = try self.arena.allocator().create(QueueNode);
            node.* = .{ .data = value, .next = null };
            if (self.end) |end| end.next = node else self.start = node;
            self.end = node;
            self.len += 1;
        }
        pub fn pushLeft(self: *Self, value: Child) !void {
            const node = try self.arena.allocator().create(QueueNode);
            node.* = .{ .data = value, .next = self.start };
            if (self.end) |_| {} else self.end = node;
            self.start = node;
            self.len += 1;
        }
        pub fn dequeue(self: *Self) ?Child {
            const start = self.start orelse return null;
            defer self.arena.allocator().destroy(start);
            if (start.next) |next|
                self.start = next
            else {
                self.start = null;
                self.end = null;
            }
            self.len -= 1;
            return start.data;
        }
        // Destroys the queue. Future calls to queue methods are undefined after destroy()
        pub fn destroy(self: *Self) void {
            self.arena.deinit();
        }
        // Clears the queue but does not destroy the backing allocator
        pub fn clear(self: *Self, mode: ?std.heap.ArenaAllocator.ResetMode) void {
            self.allocator.reset(mode orelse .free_all);
            self.start = null;
            self.end = null;
            self.len = 0;
        }
        pub fn iter(self: *Self) IteratorT(Child) {
            return IteratorT(Child){
                .cur = self.start,
            };
        }
    };
}

test "queue" {
    var queue = Queue(u32).init(std.testing.allocator);
    defer queue.destroy();
    try queue.enqueue(1);
    try queue.enqueue(2);
    try queue.enqueue(3);
    try std.testing.expect(queue.peek() == 1);
    try std.testing.expect(queue.dequeue() == 1);
    try std.testing.expect(queue.peek() == 2);
    try std.testing.expect(queue.dequeue() == 2);
    try std.testing.expect(queue.peek() == 3);
    try std.testing.expect(queue.dequeue() == 3);
    try std.testing.expect(queue.peek() == null);
}
