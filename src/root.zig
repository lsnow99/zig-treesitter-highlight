//! By convention, root.zig is the root source file when making a library.
const std = @import("std");

const Highlight = usize;

const Error = enum {
    Cancelled,
    InvalidLanguage,
    Unknown
};

const HighlightEvent = struct {
    Source: struct {
        start: usize,
        end: usize,
    },
};

pub fn full() !void {
    
}

pub fn countDots(name: []const u8) comptime_int {
    var dots = 0;
    for (name) |char| {
        switch (char) {
            '.' => dots += 1,
            else => {},
        }
    }
    return dots;
}

pub fn expandComptime(comptime name: []const u8) [countDots(name) + 1][]const u8 {
    comptime var result: [countDots(name) + 1][]const u8 = undefined;

    comptime var result_index = 0;
    comptime var i = 0;

    inline while (i < name.len) : (i += 1){
        const start_index = i;
        inline while (i < name.len) : (i += 1) {
            switch (name[i]) {
                '.' => break,
                else => {},
            }
        }
        const end_index = i;

        result[result_index] = name[start_index..end_index];
        result_index += 1;
    }

    return result;
}

pub fn expand(allocator: std.mem.Allocator, name: []const u8) ![][]const u8 {
    var result: std.ArrayList([]const u8) = .{};
    defer result.deinit(allocator);
    var parts = std.mem.splitScalar(u8, name, '.');
    while (parts.next()) |part| {
        try result.append(allocator, part);
    }
    return result.toOwnedSlice(allocator);
}

// pub fn match(comptime names: []const []const u8, name: []const u8) []type {
//     comptime var i = 0;
//     inline while (true) {
//         const start_index = i;
//         inline while (i < name.len) : (i += 1) {
//             switch (name[i]) {
//                 '.' => break,
//                 else => {},
//             }
//         }
//         const end_index = i;
//         const name_slice = name[start_index..end_index];
//     }
// }

test "basic expandComptime" {
    try std.testing.expect(expandComptime("foo.bar.baz").len == 3);
    try std.testing.expect(std.mem.eql(u8, expandComptime("foo.bar.baz")[0], "foo"));
    try std.testing.expect(std.mem.eql(u8, expandComptime("foo.bar.baz")[1], "bar"));
    try std.testing.expect(std.mem.eql(u8, expandComptime("foo.bar.baz")[2], "baz"));
}

test "basic expand" {
    const allocator = std.testing.allocator;

    const expanded = (try expand(allocator, "foo.bar.baz"));
    defer allocator.free(expanded);

    try std.testing.expect(expanded.len == 3);

    const foo = expanded[0];
    const bar = expanded[1];
    const baz = expanded[2];

    try std.testing.expect(std.mem.eql(u8, foo, "foo"));
    try std.testing.expect(std.mem.eql(u8, bar, "bar"));
    try std.testing.expect(std.mem.eql(u8, baz, "baz"));
}

// test "basic match" {
//     const names = .{
//         "foo.bar.baz",
//         "foo",
//     };
//
//     try std.testing.expect(match(names, "foo.bar.baz").len == 2);
// }
