//! By convention, root.zig is the root source file when making a library.
const std = @import("std");
const ts = @import("tree-sitter");

extern fn tree_sitter_python() callconv(.c) *ts.Language;

const Error = enum { Cancelled, InvalidLanguage, Unknown };

const stdNames = expandComptime(@embedFile("standard_names.txt"), '.');

pub fn full() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    const python_language = tree_sitter_python();
    defer python_language.destroy();
    const names = try collectNames(allocator, python_language, @embedFile("python_highlight.scm"));
    defer allocator.free(names);

    std.debug.print("Names: {s}\n", .{try std.mem.join(allocator, ", ", &stdNames)});

    const HighlightT = createHighlighterEnum(&stdNames);
    const highlighterConfig = createHighlighterConfig(HighlightT);
    var highlighter = highlighterConfig.create(python_language);
    defer highlighter.destroy();

    const events = highlighter.highlight(@embedFile("simple_python.py"));
    for (events) |event| {
        switch (event) {
            .Source => |source| {
                std.debug.print("Source: {d}-{d}\n", .{ source.start, source.end });
            },
            .HighlightStart => |highlight| {
                std.debug.print("HighlightStart: {any}\n", .{highlight});
            },
            .HighlightEnd => {
                std.debug.print("HighlightEnd\n", .{});
            },
        }
    }
}

pub fn createHighlighterConfig(HighlightT: type) type {
    const HighlightEvent = union(enum) {
        Source: struct {
            start: usize,
            end: usize,
        },
        HighlightStart: HighlightT,
        HighlightEnd: void,
    };

    return struct {
        language: *ts.Language,

        pub fn create(language: *ts.Language) @This() {
            return @This(){ .language = language };
        }

        pub fn highlight(self: @This(), source: []const u8) []const HighlightEvent {
            _ = self;
            _ = source;
            return &[_]HighlightEvent{};
        }

        // Note: does not destroy the language
        pub fn destroy(self: *@This()) void {
            _ = self;
        }
    };
}

pub fn min(a: comptime_int, b: comptime_int) comptime_int {
    return if (a < b) a else b;
}

pub fn countSequence(haystack: []const u8, needle: u8, start: comptime_int, step: comptime_int) comptime_int {
    var i = start;
    var count = 0;
    inline while (i < haystack.len and i >= 0) : (i += step) {
        switch (haystack[i]) {
            needle => {
                count += 1;
            },
            else => {
                break;
            },
        }
    }
    return count;
}

pub fn countChars(name: []const u8, needle: u8) comptime_int {
    var chars = 0;
    for (name) |char| {
        switch (char) {
            needle => chars += 1,
            else => {},
        }
    }
    return chars;
}

pub fn trimInner(haystack: []const u8, needle: u8, start: comptime_int, step: comptime_int) [haystack.len - countSequence(haystack, needle, start, step)]u8 {
    comptime var result: [haystack.len - countSequence(haystack, needle, start, step)][]const u8 = undefined;

    comptime var i = start;

    inline while (i < haystack.len and i >= 0) : (i += step) {
        switch (haystack[i]) {
            needle => {},
            else => {
                break;
            },
        }
    }

    comptime var j = i;
    inline while (j < haystack.len and j >= 0) : (j += step) {
        @compileLog(j);
        result[j - i] = haystack[j];
    }
    return result;
}

pub fn trimStart(haystack: []const u8, needle: u8) [haystack.len - countSequence(haystack, needle, 0, 1)]u8 {
    return trimInner(haystack, needle, 0, 1);
}

pub fn trimEnd(haystack: []const u8, needle: u8) [haystack.len - countSequence(haystack, needle, haystack.len, -1)]u8 {
    return trimInner(haystack, needle, haystack.len, -1);
}

pub fn trim(haystack: []const u8, needle: u8) [trimEnd(trimStart(haystack, needle), needle).len]u8 {
    return trimEnd(trimStart(haystack, needle), needle);
}

pub fn expandComptime(comptime name: []const u8, comptime char: u8) [countChars(trim(name, char), char)][]const u8 {
    comptime var trimmed = trim(name, char);
    comptime var result: [countChars(trimmed)][]const u8 = undefined;

    comptime var result_index = 0;
    comptime var i = 0;

    inline while (i < trimmed.len) : (i += 1) {
        const start_index = i;
        inline while (i < trimmed.len) : (i += 1) {
            switch (trimmed[i]) {
                char => break,
                else => {},
            }
        }
        const end_index = i;

        result[result_index] = trimmed[start_index..end_index];
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
                var field_list: [enumInfo.fields.len]struct { []const u8, []const []const u8 } = undefined;
                var i = 0;
                var map = std.EnumMap(T, []const []const u8).init(.{});
                for (enumInfo.fields) |field| {
                    field_list[i] = .{ field.name, &expandComptime(field.name, '.') };
                    i += 1;
                    map.put(@enumFromInt(field.value), &expandComptime(field.name, '.'));
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

pub fn createHighlighterEnum(comptime highlight_names: []const []const u8) type {
    var fields: [highlight_names.len]std.builtin.Type.EnumField = undefined;

    for (highlight_names, 0..) |name, i| {
        fields[i] = .{
            .name = name ++ [1:0]u8{0},
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

test "createHighlighterEnum" {
    const highlight_names = &[_][]const u8{
        "punctuation.special",
        "keyword",
    };

    const HighlightEnum = createHighlighterEnum(highlight_names);
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
    try std.testing.expect(expandComptime("foo.bar.baz", '.').len == 3);
    try std.testing.expect(std.mem.eql(u8, expandComptime("foo.bar.baz", '.')[0], "foo"));
    try std.testing.expect(std.mem.eql(u8, expandComptime("foo.bar.baz", '.')[1], "bar"));
    try std.testing.expect(std.mem.eql(u8, expandComptime("foo.bar.baz", '.')[2], "baz"));
}

test "expandComptime with line break" {
    try std.testing.expect(expandComptime("a\nb\nc", '\n').len == 3);
    try std.testing.expect(std.mem.eql(u8, expandComptime("a\nb\nc", '\n')[0], "a"));
    try std.testing.expect(std.mem.eql(u8, expandComptime("a\nb\nc", '\n')[1], "b"));
    try std.testing.expect(std.mem.eql(u8, expandComptime("a\nb.\nc", '\n')[2], "c"));
}

test "expandComptime with line break from embedded file" {
    try std.testing.expect(countChars(@embedFile("standard_names.txt"), '\n') == 6);
    try std.testing.expect(expandComptime(@embedFile("standard_names.txt"), '\n').len == 6);
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
