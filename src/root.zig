//! By convention, root.zig is the root source file when making a library.
const std = @import("std");
const ts = @import("tree-sitter");
const Queue = @import("queue.zig").Queue;
const ComptimeBufferedQueue = @import("queue.zig").ComptimeBufferedQueue;

extern fn tree_sitter_python() callconv(.c) *ts.Language;

const Error = error{ Cancelled, InvalidLanguage, Unknown, ParseFailure, InvalidQuery };

const std_lines = splitComptime(@embedFile("standard_names"), '\n');
const python_highlight = @embedFile("python_highlight.scm");

const std_names = [_][]const u8{ "function.method", "" };

pub fn filterNonNullComptime(T: type, values: []const ?T) []const T {
    var filtered: []const T = &[_]T{};
    for (values) |value| {
        if (value) |v| {
            filtered = filtered ++ &[_]T{v};
        }
    }
    return filtered;
}

pub fn itemType(T: type) type {
    switch (@typeInfo(T)) {
        .pointer => |pointer| {
            return pointer.child;
        },
        else => @compileError("T must be a pointer"),
    }
}

pub fn collectUniqueComptime(T: type, values: []const T) []const T {
    var unique: []const T = &[_]T{};
    for (values) |value| {
        comptime outer: {
            for (unique) |unique_value| {
                if (std.mem.eql(itemType(T), value, unique_value)) {
                    break :outer;
                }
            }
            unique = unique ++ &[_]T{value};
        }
    }
    return unique;
}

pub fn buildTerminalStyleMap(HighlightT: type, color_map: std.EnumMap(HighlightT, []const u8)) std.EnumMap(HighlightT, []const u8) {
    var colors: [color_map.count()]?[]const u8 = [_]?[]const u8{null} ** color_map.count();

    comptime var i: comptime_int = 0;

    inline while (i < color_map.count()) : (i += 1) {
        colors[i] = color_map.get(@enumFromInt(i)) orelse unreachable;
    }

    const filtered = filterNonNullComptime([]const u8, &colors);
    const unique = collectUniqueComptime([]const u8, filtered);

    const ColorT = comptime createEnum(unique);

    const code_map = comptime blk: {
        var map = std.EnumMap(ColorT, []const u8).init(.{});
        switch (@typeInfo(ColorT)) {
            .@"enum" => |enumInfo| {
                for (enumInfo.fields) |field| {
                    const colorEnum: ColorT = @enumFromInt(field.value);
                    const code = switch (colorEnum) {
                        // .red => "31",
                        .green => "32",
                        .yellow => "33",
                        .blue => "34",
                        .purple => "35",
                        .cyan => "36",
                        // IMPROVE: should we return null instead?
                        .none => "37",
                        .white => "37",
                    };
                    map.put(colorEnum, code);
                }
                break :blk map;
            },
            else => @compileError("unexpected ColorT not an enum"),
        }
    };

    const highlight_map = comptime blk: {
        var map = std.EnumMap(HighlightT, []const u8).init(.{});
        switch (@typeInfo(HighlightT)) {
            .@"enum" => |enumInfo| {
                for (enumInfo.fields) |field| {
                    const highlightEnum: HighlightT = @enumFromInt(field.value);
                    const colorEnum = std.meta.stringToEnum(ColorT, color_map.get(highlightEnum) orelse unreachable) orelse unreachable;
                    map.put(highlightEnum, code_map.get(colorEnum) orelse unreachable);
                }
                break :blk map;
            },
            else => @compileError("unexpected HighlightT not an enum"),
        }
    };

    return highlight_map;
}

pub fn parseNameMap(contents: []const u8) type {
    const lines = splitComptime(contents, '\n');
    comptime var names: [lines.len][]const u8 = undefined;
    comptime var pairs: [lines.len]struct { []const u8, []const u8 } = undefined;

    var i: comptime_int = 0;
    while (i < lines.len) : (i += 1) {
        const lineSplit = splitComptime(lines[i], ',');
        names[i] = lineSplit[0];
        pairs[i] = .{ lineSplit[0], lineSplit[1] };
    }

    const HighlightTLocal = createEnum(&names);
    var base_map = std.StaticStringMap([]const u8).initComptime(pairs);

    const html_map = comptime blk: {
        var map = std.EnumMap(HighlightTLocal, []const u8).init(.{});
        switch (@typeInfo(HighlightTLocal)) {
            .@"enum" => |enumInfo| {
                for (enumInfo.fields) |field| {
                    map.put(@enumFromInt(field.value), base_map.get(field.name) orelse unreachable);
                }
                break :blk map;
            },
            else => @compileError("T must be an enum"),
        }
    };

    const terminal_map = comptime buildTerminalStyleMap(HighlightTLocal, html_map);

    return struct {
        pub const HighlightT = HighlightTLocal;
        pub var html_class_map = html_map;
        pub var terminal_code_map = terminal_map;
    };
}

const RendererOpts = struct {
    base_tree: ?*ts.Tree = null,
};

pub fn renderHTML(source: []const u8, out: *std.io.Writer, highlighter: anytype, class_map: std.EnumMap(@TypeOf(highlighter).InternalHighlightT, []const u8), opts: RendererOpts) !void {
    var iter = try highlighter.highlight(source, opts.base_tree);
    defer iter.destroy();
    while (try iter.next()) |event| {
        switch (event) {
            .Source => |range| {
                try out.print("{s}", .{source[range.start..range.end]});
            },
            .HighlightStart => |highlight_val| {
                try out.print("<span style=\"{s}\">", .{class_map.get(highlight_val) orelse unreachable});
            },
            .HighlightEnd => {
                try out.print("</span>", .{});
            },
        }
        try out.flush();
    }
}

pub fn renderTerminal(Highlight: type, source: []const u8, out: *std.io.Writer, highlighter: EventIteratorT(HighlightEventT(Highlight)), code_map: std.EnumMap(Highlight, []const u8)) !void {
    var delim_iter = HighlightDelimitedIterator(Highlight).init('\n', highlighter, source);
    defer delim_iter.destroy();
    while (try delim_iter.next()) |event| {
        switch (event) {
            .Source => |range| {
                try out.print("{s}", .{source[range.start..range.end]});
            },
            .HighlightStart => |highlight_val| {
                try out.print("\x1b[{s}m", .{code_map.get(highlight_val) orelse unreachable});
            },
            .HighlightEnd => {
                try out.print("\x1b[0m", .{});
            },
            .DelimStart => {},
            .DelimEnd => {
                try out.print("\n", .{});
            },
        }
    }
    try out.flush();
}

pub fn renderHTMLLines(source: []const u8, out: *std.io.Writer, highlighter: anytype, class_map: std.EnumMap(@TypeOf(highlighter).InternalHighlightT, []const u8), opts: RendererOpts) !void {
    try out.print("<ul>", .{});
    var iter = try highlighter.highlightLines(source, opts.base_tree);
    defer iter.destroy();
    while (try iter.next()) |event| {
        switch (event) {
            .Source => |range| {
                try out.print("{s}", .{source[range.start..range.end]});
            },
            .HighlightStart => |highlight_val| {
                try out.print("<span style=\"{s}\">", .{class_map.get(highlight_val) orelse unreachable});
            },
            .HighlightEnd => {
                try out.print("</span>", .{});
            },
            .DelimStart => {
                try out.print("<li>", .{});
            },
            .DelimEnd => {
                try out.print("</li>", .{});
            },
        }
    }
    try out.print("</ul>", .{});
    try out.flush();
}

pub const std_name_map = parseNameMap(@embedFile("standard_names"));

const HighlightTree = union(enum) {
    Owned: *ts.Tree,
    Borrowed: *ts.Tree,
};

pub const HighlightRange = struct {
    start: usize,
    end: usize,
};

// Combine two iterators, where iter_a always has priority over iter_b. That is, for regions where highlights from
// iter_a overlap highlighted regions from iter_b, the source will be highlighted based on the highlights from
// iter_a. Iterators are assumed to never have more than one open HighlightEvent at a time. Does not allocate.
// pub fn combineIterators(HighlightT: type, iter_a: EventIteratorT(HighlightT), iter_b: EventIteratorT(HighlightT)) !HighlightEventIteratorT(HighlightT) {
//     const IterState = struct {
//         cur_highlight: ?HighlightT = null,
//         next_highlight: ?HighlightT = null,
//         cur_range: ?HighlightRange = null,
//         next_range: ?HighlightRange = null,
//     };
//
//     var a_state = IterState{};
//     var b_state = IterState{};
//
//     _ = iter_a.next();
//
//     // if it is a highlight event, then emit right away
//
//     _ = a_state;
//     _ = b_state;
//
//     while (a_state.cur_range == null) {
//
//     }
//
//     return struct {
//         const Self = @This();
//         pub fn next(self: Self) !?HighlightT {
//
//         }
//     };
// }

pub fn HighlightEventT(HighlightT: type) type {
    return union(enum) {
        Source: HighlightRange,
        HighlightStart: HighlightT,
        HighlightEnd: void,
    };
}

pub fn HighlightDelimitedEventT(HighlightT: type) type {
    return union(enum) {
        Source: HighlightRange,
        HighlightStart: HighlightT,
        HighlightEnd: void,
        DelimStart: void,
        DelimEnd: void,

        const Self = @This();

        pub fn print(self: Self, source: []const u8) void {
            switch (self) {
                .Source => |range| {
                    std.debug.print("Source: {d}-{d} <{s}>\n", .{ range.start, range.end, source[range.start..range.end] });
                },
                .HighlightStart => |highlight_val| {
                    std.debug.print("HighlightStart: {}\n", .{highlight_val});
                },
                .HighlightEnd => {
                    std.debug.print("HighlightEnd\n", .{});
                },
                .DelimStart => {
                    std.debug.print("DelimStart\n", .{});
                },
                .DelimEnd => {
                    std.debug.print("DelimEnd\n", .{});
                },
            }
        }
    };
}

pub fn EventIteratorT(EventT: type) type {
    // Approach inspired by Karl Seguin's [Zig Interfaces](https://www.openmymind.net/Zig-Interfaces/)
    return struct {
        ptr: *anyopaque,
        nextFn: *const fn (ptr: *anyopaque) anyerror!?EventT,

        fn init(ptr: anytype) @This() {
            const T = @TypeOf(ptr);
            const ptr_info = @typeInfo(T);

            const gen = struct {
                pub fn next(pointer: *anyopaque) !?EventT {
                    const self: T = @ptrCast(@alignCast(pointer));
                    return ptr_info.pointer.child.next(self);
                }
            };

            return .{
                .ptr = ptr,
                .nextFn = gen.next,
            };
        }

        pub fn next(self: @This()) !?EventT {
            // TODO: test passing self to check for errors
            return self.nextFn(self.ptr);
        }
    };
}

const RangeIterator = EventIteratorT(HighlightRange);

pub fn StaticHighlighter(Highlight: type) type {
    return struct {
        const Self = @This();

        source: []const u8,
        range_iter: RangeIterator,
        needs_open: bool = false,
        last_emitted_ix: ?u64 = null,
        cur_range: ?HighlightRange = null,
        highlight: Highlight,

        pub fn init(source: []const u8, range_iter: RangeIterator, highlight: Highlight) Self {
            return Self{
                .source = source,
                .range_iter = range_iter,
                .highlight = highlight,
            };
        }

        pub fn iter(self: *Self) EventIteratorT(HighlightEventT(Highlight)) {
            return EventIteratorT(HighlightEventT(Highlight)).init(self);
        }

        fn emitRange(self: *Self, range: HighlightRange) HighlightEventT(Highlight) {
            self.last_emitted_ix = range.end;
            return .{ .Source = range };
        }

        pub fn next(self: *Self) !?HighlightEventT(Highlight) {
            if (self.needs_open) {
                self.needs_open = false;
                return .{ .HighlightStart = self.highlight };
            }

            if (self.cur_range) |range| {
                if (self.last_emitted_ix == null or self.last_emitted_ix.? != range.end) {
                    return self.emitRange(range);
                }
                self.cur_range = null;
                return .{ .HighlightEnd = {} };
            }

            if (try self.range_iter.next()) |range| {
                self.cur_range = range;
                std.debug.assert(self.last_emitted_ix == null or range.start > self.last_emitted_ix.?);
                if (self.last_emitted_ix == null or range.start > self.last_emitted_ix.? + 1) {
                    self.needs_open = true;
                    const start = if (self.last_emitted_ix) |ix| ix + 1 else 0;
                    return self.emitRange(.{ .start = start, .end = range.start });
                }
                return .{ .HighlightStart = self.highlight };
            }

            if (self.last_emitted_ix == null or self.last_emitted_ix.? < self.source.len) {
                const start = if (self.last_emitted_ix) |ix| ix else 0;
                return self.emitRange(.{ .start = start, .end = self.source.len });
            }

            return null;
        }

        pub fn destroy(self: *Self) void {
            self.range_iter.destroy();
        }
    };
}

pub fn StaticIterator(EventT: type) type {
    return struct {
        const Self = @This();

        items: []const EventT,
        ix: usize = 0,

        pub fn init(items: []const EventT) Self {
            return Self{
                .items = items,
            };
        }

        pub fn iter(self: *Self) EventIteratorT(EventT) {
            return EventIteratorT(EventT).init(self);
        }

        pub fn next(self: *Self) ?EventT {
            if (self.ix < self.items.len) {
                defer self.ix = self.ix + 1;
                return self.items[self.ix];
            }
            return null;
        }
    };
}

test "StaticHighlighter" {
    const Highlight = createEnum(&std_names);
    const highlight = .@"function.method";
    const source = "abckdfjsl3hdlzn";
    const ranges = [_]HighlightRange{.{ .start = 5, .end = 7 }};
    const EventT = HighlightEventT(Highlight);
    const expected_events = [_]EventT{
        EventT{ .Source = .{ .start = 0, .end = 5 } },
        EventT{ .HighlightStart = highlight },
        EventT{ .Source = .{ .start = 5, .end = 7 } },
        EventT{ .HighlightEnd = {} },
        EventT{ .Source = .{ .start = 7, .end = source.len } },
    };
    var static_iter = StaticIterator(HighlightRange).init(ranges[0..]);
    const range_iter = static_iter.iter();

    var static_highlighter = StaticHighlighter(Highlight).init(source, range_iter, .@"function.method");
    for (expected_events) |expected| {
        const highlight_event = try static_highlighter.next();
        if (highlight_event) |actual| {
            try std.testing.expectEqualDeep(expected, actual);
        } else {
            unreachable;
        }
    }
}

pub fn HighlightDelimitedIterator(Highlight: type) type {
    const HighlightDelimitedEvent = HighlightDelimitedEventT(Highlight);
    const HighlightEvent = HighlightEventT(Highlight);

    return struct {
        const Self = @This();

        delimiter: u8,
        base_iterator: EventIteratorT(HighlightEventT(Highlight)),
        source: []const u8,

        current_highlight: ?Highlight = null,
        next_event: ?HighlightDelimitedEvent = null,
        next_range: ?HighlightRange = null,
        last_event_was_line_end: bool = false,
        in_a_line: bool = false,
        did_emit: bool = false,

        pub fn init(delimiter: u8, base_iterator: EventIteratorT(HighlightEventT(Highlight)), source: []const u8) Self {
            return Self{
                .delimiter = delimiter,
                .base_iterator = base_iterator,
                .source = source,
            };
        }

        pub fn transformEvent(evt: HighlightEvent) HighlightDelimitedEvent {
            switch (evt) {
                .HighlightStart => {
                    return HighlightDelimitedEvent{ .HighlightStart = evt.HighlightStart };
                },
                .HighlightEnd => {
                    return HighlightDelimitedEvent{ .HighlightEnd = {} };
                },
                .Source => |range| {
                    return HighlightDelimitedEvent{ .Source = .{ .start = range.start, .end = range.end } };
                },
            }
        }

        fn updateNextRange(self: *Self, start: usize, end: usize) void {
            if (end - start <= 0) {
                self.next_range = null;
            } else {
                self.next_range = HighlightRange{ .start = start, .end = end };
            }
        }

        pub fn handleSource(self: *Self, range: HighlightRange) !HighlightDelimitedEvent {
            const sliced = self.source[range.start..range.end];

            std.debug.assert(sliced.len > 0);

            if (std.mem.indexOfScalar(u8, sliced, self.delimiter)) |i| {
                if (i > 0) {
                    const next_start = range.start + i;
                    self.updateNextRange(next_start, range.end);
                    return HighlightDelimitedEvent{ .Source = .{ .start = range.start, .end = next_start } };
                } else {
                    self.updateNextRange(range.start + 1, range.end);
                    if (self.current_highlight) |_| {
                        self.next_event = HighlightDelimitedEvent{ .DelimEnd = {} };
                        return HighlightDelimitedEvent{ .HighlightEnd = {} };
                    }
                    self.next_event = HighlightDelimitedEvent{ .DelimStart = {} };
                    return HighlightDelimitedEvent{ .DelimEnd = {} };
                }
            }

            self.next_range = null;
            return HighlightDelimitedEvent{ .Source = range };
        }

        pub fn emitEvent(self: *Self, event: ?HighlightDelimitedEvent) !?HighlightDelimitedEvent {
            self.last_event_was_line_end = if (event) |ev| ev == .DelimEnd else false;
            self.in_a_line |= if (event) |ev| ev == .DelimStart else false;
            self.in_a_line &= !self.last_event_was_line_end;
            self.did_emit = true;
            if (event) |ev| {
                switch (ev) {
                    .HighlightStart => |highlight_val| {
                        self.current_highlight = highlight_val;
                    },
                    .HighlightEnd => {
                        self.current_highlight = null;
                    },
                    else => {},
                }
            }
            return event;
        }

        pub fn iter(self: *Self) EventIteratorT(HighlightDelimitedEvent) {
            return EventIteratorT(HighlightDelimitedEvent).init(self);
        }

        pub fn next(self: *Self) !?HighlightDelimitedEvent {
            if (self.next_event) |event| {
                switch (event) {
                    .DelimEnd => {
                        self.next_event = HighlightDelimitedEvent{ .DelimStart = {} };
                    },
                    else => {
                        self.next_event = null;
                    },
                }
                return try self.emitEvent(event);
            }

            if (self.next_range) |range| {
                return try self.emitEvent(try self.handleSource(range));
            }

            if (!self.did_emit and self.source.len > 0) {
                return try self.emitEvent(HighlightDelimitedEvent{ .DelimStart = {} });
            }

            if (try self.base_iterator.next()) |event| {
                switch (event) {
                    .Source => |range| {
                        return self.emitEvent(try self.handleSource(range));
                    },
                    else => return self.emitEvent(HighlightDelimitedIterator(Highlight).transformEvent(event)),
                }
            }

            if (self.in_a_line and !self.last_event_was_line_end) {
                return self.emitEvent(HighlightDelimitedEvent{ .DelimEnd = {} });
            }

            return self.emitEvent(null);
        }

        pub fn destroy(_: *Self) void {
            // Nothing to free
        }
    };
}

pub fn createHighlighterConfig(HighlightT: type) type {
    const HighlightEvent = HighlightEventT(HighlightT);

    return struct {
        // Improve: can't use Self twice
        const HighlighterSelf = @This();
        const InternalHighlightT = HighlightT;

        const HighlightEventIterator = struct {
            const Self = @This();

            tree: HighlightTree,
            source: []const u8,
            highlighter: HighlighterSelf,
            captures: Queue(ts.Query.Capture), // (capture_index, ts.Query.Match),
            highlight_last_byte_stack: std.ArrayList(u64) = .{},
            offset: u64 = 0,
            last_highlight_range: ?ts.Range = null,
            next_event: ?HighlightEvent = null,

            pub fn emitEvent(self: *Self, offset: u64, event: ?HighlightEvent) ?HighlightEvent {
                if (self.offset < offset) {
                    self.next_event = event;
                    const evt = HighlightEvent{
                        .Source = .{
                            .start = self.offset,
                            .end = offset,
                        },
                    };
                    self.offset = offset;
                    return evt;
                }
                return event;
            }

            pub fn printState(self: *Self) void {
                std.debug.print("offset: {d}, last_highlight_range: {any}, next_event: {any}, captures.len: {d}\n", .{ self.offset, self.last_highlight_range, self.next_event, self.captures.len });
            }

            pub fn iter(self: *Self) EventIteratorT(HighlightEventT(HighlightT)) {
                return EventIteratorT(HighlightEventT(HighlightT)).init(self);
            }

            pub fn next(self: *Self) !?HighlightEvent {
                while (true) {
                    if (self.next_event) |event| {
                        self.next_event = null;
                        return event;
                    }

                    if (self.captures.peek() == null) {
                        if (self.highlight_last_byte_stack.pop()) |end_byte| {
                            return self.emitEvent(end_byte, HighlightEvent{
                                .HighlightEnd = {},
                            });
                        }
                        return self.emitEvent(self.source.len, null);
                    }
                    var capture = self.captures.peek() orelse unreachable;
                    const range = capture.node.range();

                    if (self.highlight_last_byte_stack.items.len > 0) {
                        const last_highlight_end_byte = self.highlight_last_byte_stack.getLast();
                        if (last_highlight_end_byte <= range.start_byte) {
                            _ = self.highlight_last_byte_stack.pop();
                            return self.emitEvent(last_highlight_end_byte, HighlightEvent{
                                .HighlightEnd = {},
                            });
                        }
                    }

                    _ = self.captures.dequeue();

                    if (self.last_highlight_range) |last_highlight_range| {
                        if (range.start_byte == last_highlight_range.start_byte and range.end_byte == last_highlight_range.end_byte) {
                            continue;
                        }
                    }

                    while (self.captures.peek()) |next_capture| {
                        if (next_capture.node.eql(capture.node)) {
                            _ = self.captures.dequeue();

                            capture = next_capture;
                        } else {
                            break;
                        }
                    }

                    // Unreachable because every possible capture should have been collected and added to the capture_map in `create`
                    const current_highlight = self.highlighter.capture_map.get(capture.index) orelse {
                        std.debug.print("Unrecognized capture index: {d} in map of length {d}", .{ capture.index, self.highlighter.capture_map.count() });
                        unreachable;
                    };

                    self.last_highlight_range = range;
                    try self.highlight_last_byte_stack.append(self.highlighter.allocator, range.end_byte);

                    return self.emitEvent(range.start_byte, HighlightEvent{
                        .HighlightStart = current_highlight,
                    });
                }
            }

            pub fn destroy(self: *Self) void {
                switch (self.tree) {
                    .Owned => |t| t.destroy(),
                    .Borrowed => {},
                }
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

        pub fn parseSource(self: HighlighterSelf, source: []const u8) !HighlightTree {
            // IMPROVE: support cancellation and properly handle different encodings
            return HighlightTree{ .Owned = self.parser.parseString(source, null) orelse return error.ParseFailure };
        }

        pub fn highlight(self: HighlighterSelf, source: []const u8, tree: ?*ts.Tree) !HighlightEventIterator {
            const tagged_tree = if (tree) |t| HighlightTree{ .Borrowed = t } else try self.parseSource(source);
            self.cursor.exec(self.query, switch (tagged_tree) {
                inline else => |t| t.rootNode(),
            });
            var captures = Queue(ts.Query.Capture).init(self.allocator);
            while (self.cursor.nextCapture()) |match_info| {
                const match = match_info[1];
                const capture = match.captures[match_info[0]];
                try captures.enqueue(capture);
            }
            return HighlightEventIterator{
                .tree = tagged_tree,
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

pub fn splitComptime(comptime name: []const u8, comptime char: u8) [countChars(std.mem.trim(u8, name, &[_]u8{char}), char) + 1][]const u8 {
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
                    field_list[i] = .{ field.name, &splitComptime(field.name, '.') };
                    i += 1;
                    map.put(@enumFromInt(field.value), &splitComptime(field.name, '.'));
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

pub fn createEnum(comptime highlight_names: []const []const u8) type {
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

test "createEnum" {
    const highlight_names = &[_][]const u8{
        "punctuation.special",
        "keyword",
    };

    const HighlightEnum = createEnum(highlight_names);
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
    const HighlightEnum = createEnum(&std_names);
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

test "basic splitComptime" {
    try std.testing.expect(splitComptime("foo.bar.baz", '.').len == 3);
    try std.testing.expect(std.mem.eql(u8, splitComptime("foo.bar.baz", '.')[0], "foo"));
    try std.testing.expect(std.mem.eql(u8, splitComptime("foo.bar.baz", '.')[1], "bar"));
    try std.testing.expect(std.mem.eql(u8, splitComptime("foo.bar.baz", '.')[2], "baz"));
}

test "splitComptime with line break" {
    try std.testing.expect(splitComptime("a\nb\nc", '\n').len == 3);
    try std.testing.expect(std.mem.eql(u8, splitComptime("a\nb\nc", '\n')[0], "a"));
    try std.testing.expect(std.mem.eql(u8, splitComptime("a\nb\nc", '\n')[1], "b"));
    try std.testing.expect(std.mem.eql(u8, splitComptime("a\nb.\nc", '\n')[2], "c"));
}

test "splitComptime with line break from embedded file" {
    try std.testing.expect(countChars(@embedFile("standard_names"), '\n') == 17);
    try std.testing.expect(splitComptime(@embedFile("standard_names"), '\n').len == 17);
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
