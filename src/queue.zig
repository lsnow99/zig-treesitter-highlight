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

pub fn RingBufferDeque(comptime Child: type, buffer_size: comptime_int) type {
    return struct {
        const Self = @This();

        const DequeIter = struct {
            num_returned: usize,
            deque: *Self,

            fn init(deque: *Self) @This() {
                return @This(){
                    .num_returned = 0,
                    .deque = deque,
                };
            }

            pub fn next(self: *@This()) ?Child {
                if (self.num_returned == self.deque.len) {
                    return null;
                }
                const next_ix = (self.deque.start + self.num_returned) % buffer_size;
                self.num_returned += 1;
                return self.deque.buffer[next_ix];
            }
        };

        buffer: [buffer_size]?Child = undefined,
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
            const first_ix = self.start;
            self.start = (self.start + 1) % buffer_size;
            self.len -= 1;
            std.debug.assert(self.len >= 0);
            std.debug.assert(self.len < buffer_size);
            return self.buffer[first_ix];
        }

        pub fn removeRight(self: *Self) ?Child {
            if (self.len == 0) {
                return null;
            }
            const last_ix = (self.start + self.len - 1) % buffer_size;
            self.len -= 1;
            std.debug.assert(self.len >= 0);
            std.debug.assert(self.len < buffer_size);
            return self.buffer[last_ix];
        }

        pub fn pushLeft(self: *Self, value: Child) void {
            if (self.start == 0) {
                self.start = buffer_size - 1;
            } else {
                self.start = (self.start - 1);
            }
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
        pub fn iter(self: *Self) DequeIter {
            return DequeIter.init(self);
        }
    };
}

test "Ring buffer deque" {
    var deque: RingBufferDeque(u64, 4) = .{};
    deque.enqueue(7);
    std.debug.assert(deque.len == 1);
    std.debug.assert(deque.peek() == 7);
    deque.pushLeft(6);
    std.debug.assert(deque.len == 2);
    std.debug.assert(deque.peek() == 6);
    deque.enqueue(8);
    std.debug.assert(deque.peek() == 6);
    std.debug.assert(deque.len == 3);
    deque.pushLeft(5);
    std.debug.assert(deque.peek() == 5);
    std.debug.assert(deque.len == 4);
    std.debug.assert(deque.removeRight() == 8);
    std.debug.assert(deque.peek() == 5);
    std.debug.assert(deque.len == 3);
    deque.enqueue(9);
    std.debug.assert(deque.len == 4);
    std.debug.assert(deque.peek() == 5);
    std.debug.assert(deque.dequeue() == 5);
    deque.pushLeft(4);
    std.debug.assert(deque.peek() == 4);

    var iter = deque.iter();
    var i: usize = 0;
    const expected = [_]u64{ 4, 6, 7, 9 };
    while (iter.next()) |item| : (i += 1) {
        std.debug.assert(item == expected[i]);
    }

    deque.clear(false);
    std.debug.assert(deque.len == 0);
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
