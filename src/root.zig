//! By convention, root.zig is the root source file when making a library.
const std = @import("std");
const ts = @import("tree-sitter");

extern fn tree_sitter_python() callconv(.c) *ts.Language;

const Error = error{ Cancelled, InvalidLanguage, Unknown, ParseFailure, InvalidQuery };

const std_names = expandComptime(@embedFile("standard_names.txt"), '\n');
const python_highlight = @embedFile("python_highlight.scm");

pub fn full() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    const python_language = tree_sitter_python();
    defer python_language.destroy();
    const names = try collectNames(allocator, python_language, @embedFile("python_highlight.scm"));
    defer allocator.free(names);

    std.debug.print("Names: {s}\n", .{try std.mem.join(allocator, ", ", &std_names)});

    const HighlightT = createHighlighterEnum(&std_names);
    const highlighterConfig = createHighlighterConfig(HighlightT);
    var highlighter = try highlighterConfig.create(allocator, python_language, python_highlight);
    defer highlighter.destroy();

    const test_text = @embedFile("simple_python.py");
    var iter = try highlighter.highlight(test_text);
    defer iter.destroy();

    while (try iter.next()) |event| {
        std.debug.print("event: {any}\n", .{iter});
        switch (event) {
            .Source => |source| {
                std.debug.print("Source: {d}-{d}:{s}\n", .{ source.start, source.end, test_text[source.start..source.end] });
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

pub fn Queue(comptime Child: type) type {
    return struct {
        const Self = @This();
        const QueueNode = struct {
            data: Child,
            next: ?*QueueNode,
        };
        allocator: std.mem.Allocator,
        start: ?*QueueNode,
        end: ?*QueueNode,
        len: usize = 0,

        pub fn init(allocator: std.mem.Allocator) Self {
            return Self{
                .allocator = allocator,
                .start = null,
                .end = null,
            };
        }
        pub fn peek(self: *Self) ?Child {
            return if (self.start) |start| start.data else null;
        }
        pub fn enqueue(self: *Self, value: Child) !void {
            const node = try self.allocator.create(QueueNode);
            node.* = .{ .data = value, .next = null };
            if (self.end) |end| end.next = node
            else self.start = node;
            self.end = node;
            self.len += 1;
        }
        pub fn dequeue(self: *Self) ?Child {
            const start = self.start orelse return null;
            defer self.allocator.destroy(start);
            if (start.next) |next|
                self.start = next
            else {
                self.start = null;
                self.end = null;
            }
            self.len -= 1;
            return start.data;
        }
        pub fn destroy(self: *Self) void {
            var next: ?*QueueNode = self.start;
            while (next) |node| {
                next = node.next;
                self.allocator.destroy(node);
            }
        }
    };
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
        // Improve: can't use Self twice
        const HighlighterSelf = @This();

        const HighlightEventIterator = struct {
            const Self = @This();

            tree: *ts.Tree,
            source: []const u8,
            highlighter: HighlighterSelf,
            captures: Queue(struct { u32, ts.Query.Match }), // (pattern_index, ts.Query.Match),
            highlight_last_byte_stack: std.ArrayList(u64) = .{},
            offset: u64 = 0,
            last_highlight_range: ?ts.Range = null,
            next_event: ?HighlightEvent = null,

            pub fn emitEvent(self: *Self, offset: u64, event: ?HighlightEvent) ?HighlightEvent {
                if (self.offset < offset) {
                    self.next_event = event;
                    defer self.offset = offset;
                    return HighlightEvent{
                        .Source = .{
                            .start = self.offset,
                            .end = offset,
                        },
                    };
                }
                return event;
            }

            pub fn printState(self: *Self) void {
                std.debug.print("offset: {d}, last_highlight_range: {any}, next_event: {any}, captures.len: {d}\n", .{ self.offset, self.last_highlight_range, self.next_event, self.captures.len });
            }

            pub fn next(self: *Self) !?HighlightEvent {
                while (true) {
                    std.debug.print("in loop: ", .{});
                    self.printState();

                    if (self.next_event) |event| {
                        self.next_event = null;
                        return event;
                    }

                    // if (self.captures.peek() == null) {
                    //     if (self.offset < self.source.len) {
                    //         defer self.offset = self.source.len;
                    //         return HighlightEvent{ .Source = .{
                    //             .start = self.offset,
                    //             .end = self.source.len,
                    //         } };
                    //     } else {
                    //         return null;
                    //     }
                    // }

                    if (self.captures.peek() == null) {
                        if (self.highlight_last_byte_stack.pop()) |_| {
                            return HighlightEvent{
                                .HighlightEnd = {},
                            };
                        }
                        self.offset = self.source.len;
                        return null;
                    }
                    const capture_info = self.captures.peek() orelse unreachable;
                    var match = capture_info[1];
                    var capture = match.captures[capture_info[0]];
                    const range = capture.node.range();

                    if (self.highlight_last_byte_stack.items.len > 0) {
                        const last_highlight_end_byte = self.highlight_last_byte_stack.getLast();
                        if (last_highlight_end_byte <= range.start_byte) {
                            return self.emitEvent(last_highlight_end_byte, HighlightEvent{
                                .HighlightEnd = {},
                            });
                        }
                    }

                    _ = self.captures.dequeue();

                    if (self.last_highlight_range) |last_highlight_range| {
                        if (range.start_byte == last_highlight_range.start_byte and range.end_byte == last_highlight_range.end_byte) {
                            std.debug.print("skipping\n", .{});
                            continue;
                        }
                    }

                    while (self.captures.peek()) |next_capture_info| {
                        const next_match = next_capture_info[1];
                        const next_capture = next_match.captures[next_capture_info[0]];
                        std.debug.print("next_capture.node.start_byte: {d}, capture.node.start_byte: {d}\n", .{ next_capture.node.startByte(), capture.node.startByte() });
                        if (next_capture.node.eql(capture.node)) {
                            _ = self.captures.dequeue();
                            std.debug.print("dequeue\n", .{});

                            capture = next_capture;
                            match = next_match;
                        } else {
                            break;
                        }
                    }

                    // Unreachable because every possible capture should have been collected and added to the capture_map in `create`
                    const current_highlight = self.highlighter.capture_map.get(capture.index) orelse unreachable;

                    self.last_highlight_range = range;
                    try self.highlight_last_byte_stack.append(self.highlighter.allocator, range.end_byte);

                    return self.emitEvent(range.start_byte, HighlightEvent{
                        .HighlightStart = current_highlight,
                    });
                }
            }

            pub fn destroy(self: *Self) void {
                self.tree.destroy();
                self.captures.destroy();
                self.highlight_last_byte_stack.deinit(self.highlighter.allocator);
            }
        };

        allocator: std.mem.Allocator,
        language: *ts.Language,
        parser: *ts.Parser,
        cursor: *ts.QueryCursor,
        query: *ts.Query,
        capture_map: std.AutoHashMap(usize, HighlightT),

        pub fn create(allocator: std.mem.Allocator, language: *ts.Language, query_scm: []const u8) !HighlighterSelf {
            const parser = ts.Parser.create();
            var error_offset: u32 = 0;
            // Improve: surface error information
            const query = ts.Query.create(language, query_scm, &error_offset) catch return Error.InvalidQuery;
            try parser.setLanguage(language);

            // build map of captureId (index in collectNames) -> best match of HighlightT
            var capture_map = std.AutoHashMap(usize, HighlightT).init(allocator);
            const names = try collectNames(allocator, language, query_scm);
            defer allocator.free(names);
            for (names, 0..) |name, i| {
                const best_highlight = matchName(HighlightT, name);
                if (best_highlight == null) {
                    // IMPROVE: surface error information
                    std.debug.panic("unmatched name: {s}", .{name});
                }
                // Unreachable because we check for null above
                try capture_map.put(i, best_highlight orelse unreachable);
            }

            return HighlighterSelf{ .allocator = allocator, .language = language, .parser = parser, .cursor = ts.QueryCursor.create(), .query = query, .capture_map = capture_map };
        }

        pub fn highlight(self: HighlighterSelf, source: []const u8) !HighlightEventIterator {
            // IMPROVE: support cancellation and properly handle different encodings
            const tree = self.parser.parseString(source, null) orelse return Error.ParseFailure;
            self.cursor.exec(self.query, tree.rootNode());
            var captures = Queue(struct { u32, ts.Query.Match }).init(self.allocator);
            while (self.cursor.nextCapture()) |capture| {
                try captures.enqueue(capture);
            }
            return HighlightEventIterator{
                .tree = tree,
                .source = source,
                .highlighter = self,
                .captures = captures,
            };
        }

        // Note: does not destroy the language
        pub fn destroy(self: *HighlighterSelf) void {
            self.parser.destroy();
            self.cursor.destroy();
            self.query.destroy();
            self.capture_map.deinit();
        }
    };
}

pub fn countChars(name: []const u8, needle: u8) comptime_int {
    @setEvalBranchQuota(name.len * 1000);
    var chars = 0;
    for (name) |char| {
        switch (char) {
            needle => chars += 1,
            else => {},
        }
    }
    return chars;
}

pub fn expandComptime(comptime name: []const u8, comptime char: u8) [countChars(std.mem.trim(u8, name, &[_]u8{char}), char) + 1][]const u8 {
    comptime var trimmed = std.mem.trim(u8, name, &[_]u8{char});
    comptime var result: [countChars(trimmed, char) + 1][]const u8 = undefined;

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
pub fn matchName(comptime T: type, captured_name: []const u8) ?T {
    var table = comptime comptimeNameLookup(T);
    var iter = table.iterator();

    var best_match: ?T = null;
    var best_matches: u8 = 0;
    while (iter.next()) |entry| {
        var part_matches: u8 = 0;
        const value = table.get(entry.key) orelse unreachable;
        for (value) |part| {
            var expanded = std.mem.splitScalar(u8, captured_name, '.');
            const found = while (expanded.next()) |expanded_part| {
                if (std.mem.eql(u8, expanded_part, part)) {
                    part_matches += 1;
                    break true;
                }
            } else false;
            if (!found) {
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

    const res = matchName(HighlightEnum, "keyword");
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

test "basic matchName" {
    const HighlightEnum = createHighlighterEnum(&std_names);
    try std.testing.expect(matchName(HighlightEnum, "function.method") != null);
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
    try std.testing.expect(countChars(@embedFile("standard_names.txt"), '\n') == 17);
    try std.testing.expect(expandComptime(@embedFile("standard_names.txt"), '\n').len == 17);
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
