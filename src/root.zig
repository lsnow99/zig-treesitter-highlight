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

pub fn comptimeNameLookup(comptime T: type) std.EnumMap(T, []const []const u8) {
    comptime {
        switch (@typeInfo(T)) {
            .@"enum" => |enumInfo| {
                var field_list: [enumInfo.fields.len]struct{ []const u8, []const [] const u8} = undefined;
                var i = 0;
                var map = std.EnumMap(T, []const []const u8).init(.{});
                for (enumInfo.fields) |field| {
                    field_list[i] = .{ field.name, &expandComptime(field.name)};
                    i += 1;
                    map.put(@enumFromInt(field.value), &expandComptime(field.name));
                }
                return map;
            },
            else => @compileError("T must be an enum"),
        }
    }
}


// Finds the best match for a captured name among a list of recognized names.
// Expands the recognized names (split on '.') and finds the recognized name
// that has the most number of parts that are present in the captured name.
// All parts of the recognized name must be present in the captured name.
pub fn match(comptime T: type, captured_name: []const u8) ?T {
    var table = comptime comptimeNameLookup(T);
    var iter = table.iterator();

    var best_match: ?T = null;
    var best_matches: u8 = 0;
    while (iter.next()) |entry| {
        var part_matches: u8 = 0;
        const value = table.get(entry.key) orelse unreachable;
        for (value) |part| {
            if (std.mem.eql(u8, captured_name, part)) {
                part_matches += 1;
            } else {
                part_matches = 0;
                break;
            }
        }
        if (best_matches < part_matches) {
            best_matches = part_matches;
            best_match = entry.key;
        }
    }

    return best_match;
}

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

pub fn getFirstValue(comptime EnumType: type) EnumType {
    return @enumFromInt(0);
}

test "makeHighlighterEnum" {
    const highlight_names = &[_][:0]const u8{
        "punctuation.special",
        "keyword",
    };

    const HighlightEnum = makeHighlighterEnum(highlight_names);
    const value: HighlightEnum = .@"punctuation.special";

    switch (getFirstValue(HighlightEnum)) {
        .keyword => {},
        .@"punctuation.special" => {},
    }

    std.debug.print("Enum value = {}\n", .{@intFromEnum(value)});

    const res = match(HighlightEnum, "keyword");
    if (res) |r| {
        switch (r) {
            .keyword => {
                std.debug.print("Matched keyword\n", .{});
            },
            .@"punctuation.special" => {
                std.debug.print("matched punctuation", .{});
            },
        }
    }
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
