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

pub fn countDots(comptime name: []const u8) comptime_int {
    comptime var dots = 0;
    inline for (name) |char| {
        switch (char) {
            '.' => dots += 1,
            else => {},
        }
    }
    return dots;
}

pub fn expand(comptime name: []const u8) [countDots(name) + 1][]const u8 {
    comptime var result: [countDots(name) + 1][]const u8 = undefined;

    comptime var result_index = 0;
    comptime var i = 0;

    inline while (true) {
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
        i += 1;

        if (i >= name.len) {
            break;
        }
    }

    return result;
}

pub fn match(comptime names: []const []const u8, name: []const u8) []type {
    comptime var i = 0;
    inline while (true) {
        const start_index = i;
        inline while (i < name.len) : (i += 1) {
            switch (name[i]) {
                '.' => break,
                else => {},
            }
        }
        const end_index = i;
        const name_slice = name[start_index..end_index];
    }
}

test "basic expand" {
    try std.testing.expect(expand("foo.bar.baz").len == 3);
    try std.testing.expect(std.mem.eql(u8, expand("foo.bar.baz")[0], "foo"));
    try std.testing.expect(std.mem.eql(u8, expand("foo.bar.baz")[1], "bar"));
    try std.testing.expect(std.mem.eql(u8, expand("foo.bar.baz")[2], "baz"));
}

test "basic match" {
    const names = .{
        "foo.bar.baz",
        "foo",
    };

    try std.testing.expect(match(names, "foo.bar.baz").len == 2);
}
