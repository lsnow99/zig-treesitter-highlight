//! By convention, root.zig is the root source file when making a library.
const std = @import("std");
const ts = @import("tree-sitter");

extern fn tree_sitter_python() callconv(.c) *ts.Language;

const Highlight = usize;

const Error = enum { Cancelled, InvalidLanguage, Unknown };

const HighlightEvent = struct {
    Source: struct {
        start: usize,
        end: usize,
    },
};

pub fn full() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    const python_language = tree_sitter_python();
    defer python_language.destroy();
    const names = try collectNames(allocator, python_language, @embedFile("python_highlight.scm"));
    defer allocator.free(names);
    try std.testing.expect(names.len == 17);
    std.debug.print("{any}\n", .{names});
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

    inline while (i < name.len) : (i += 1) {
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

pub fn collectNames(allocator: std.mem.Allocator, language: *ts.Language, query_raw: []const u8) ![][]const u8 {
    var error_offset: u32 = undefined;
    const query = try ts.Query.create(language, query_raw, &error_offset);
    const capture_count = query.captureCount();

    var names: std.ArrayList([]const u8) = .{};
    defer names.deinit(allocator);

    for (0..capture_count) |capture_index| {
        const maybe_name = query.captureNameForId(@intCast(capture_index));
        if (maybe_name) |name| {
            try names.append(allocator, name);
        }
    }
    return names.toOwnedSlice(allocator);
}

// pub fn match(highlight_names: [][]const u8, captured_name: []const u8) ![]const u8{
//     
// }

pub fn makeHighlighterEnum(comptime highlight_names: []const [:0]const u8) type {
    var fields: [highlight_names.len]std.builtin.Type.EnumField = undefined;

    for (highlight_names, 0..) |name, i| {
        fields[i] = .{
            .name = name,
            .value = i,
        };
    }

    return @Type(.{
        .@"enum" = .{
            .tag_type = u32,
            .fields = &fields,
            .decls = &.{},
            .is_exhaustive = true,
        },
    });
}

test "makeHighlighterEnum" {
    const highlight_names = &[_][:0]const u8{
        "Error",
        "Warning",
        "Info",
    };

    const HighlightEnum = makeHighlighterEnum(highlight_names);
    const value: HighlightEnum = .Warning;

    std.debug.print("Enum value = {}\n", .{@intFromEnum(value)});
}

test "basic collectNames" {
    const allocator = std.testing.allocator;
    const python_language = tree_sitter_python();
    defer python_language.destroy();
    const names = try collectNames(allocator, python_language, @embedFile("python_highlight.scm"));
    defer allocator.free(names);
    try std.testing.expect(names.len == 17);
}

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
