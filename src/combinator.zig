const std = @import("std");
const HighlightRange = @import("root.zig").HighlightRange;
const EventIteratorT = @import("root.zig").EventIteratorT;
const HighlightEventT = @import("root.zig").HighlightEventT;
const StaticIterator = @import("root.zig").StaticIterator;
const StaticHighlighter = @import("root.zig").StaticHighlighter;
const dbg = @import("util.zig").dbg;
const print = @import("std").debug.print;
const assert = @import("std").debug.assert;
const util = @import("util.zig");

// Combine two iterators, where iter_a always has priority over iter_b. That is, for regions where highlights from
// iter_a overlap highlighted regions from iter_b, the source will be highlighted based on the highlights from
// iter_a. Iterators are assumed to never have more than one open HighlightEvent at a time. Does not allocate.
pub fn IteratorCombinator(Highlight: type) type {
    const IterT = EventIteratorT(HighlightEventT(Highlight));

    const ValuedHighlightRange = struct {
        start: u64,
        end: u64,
        highlight: Highlight,

        pub fn asRange(self: @This()) HighlightRange {
            return HighlightRange{.start = self.start, .end = self.end};
        }
    };

    const IterState = struct {
        const Self = @This();
        iterator: IterT,
        cur_range: ?ValuedHighlightRange = null,

        fn updateRange(self: *Self, start_ix: u64) !void {
            if (self.cur_range) |range| {
                if (range.end > start_ix) {
                    // Clamp the start index
                    self.cur_range.?.start = @max(start_ix, range.start);
                    return;
                }
            }

            var cur_hl: ?Highlight = null;
            while (try self.iterator.next()) |evt| {
                switch (evt) {
                    .HighlightStart => |hl| {
                        cur_hl = hl;
                    },
                    .Source => |range| {
                        if (cur_hl) |hl| {
                            if (range.end > start_ix) {
                                self.cur_range = .{
                                    .highlight = hl,
                                    .start = @max(start_ix, range.start), 
                                    .end = range.end,
                                };
                                return;
                            }
                        }
                    },
                    .HighlightEnd => {
                        cur_hl = null;
                    },
                }
            }

            self.cur_range = null;
        }
    };

    return struct {
        const Self = @This();
        a_state: IterState,
        b_state: IterState,
        cur_ix: u64 = 0,
        first_event: ?HighlightEventT(Highlight) = null,
        second_event: ?HighlightEventT(Highlight) = null,
        source: []const u8,

        pub fn init(source: []const u8, iter_a: IterT, iter_b: IterT) Self {
            return Self{
                .a_state = IterState{ .iterator = iter_a },
                .b_state = IterState{ .iterator = iter_b },
                .source = source,
            };
        }

        pub fn iter(self: *Self) EventIteratorT(HighlightEventT(Highlight)) {
            return EventIteratorT(HighlightEventT(Highlight)).init(self);
        }

        fn emitEvent(self: *Self, evt: HighlightEventT(Highlight)) HighlightEventT(Highlight) {
            switch (evt) {
                .Source => |range| {
                    self.cur_ix = range.end;
                },
                else => {},
            }
            return evt;
        }

        fn emitHighlight(self: *Self, highlight: Highlight, end: u64) ?HighlightEventT(Highlight) {
            assert(self.first_event == null);
            assert(self.second_event == null);
            self.first_event = .{ .Source = .{ .start = self.cur_ix, .end = end } };
            self.second_event = .{ .HighlightEnd = {} };
            return self.emitEvent(.{ .HighlightStart = highlight });
        }

        pub fn next(self: *Self) !?HighlightEventT(Highlight) {
            if (self.first_event) |evt| {
                self.first_event = self.second_event;
                self.second_event = null;
                return self.emitEvent(evt);
            }

            try self.a_state.updateRange(self.cur_ix);
            try self.b_state.updateRange(self.cur_ix);

            if (self.a_state.cur_range) |a_range| {
                if (self.b_state.cur_range) |b_range| {
                    const first = @min(a_range.start, b_range.start);
                    if (self.cur_ix < first) {
                        return self.emitEvent(.{ .Source = .{ .start = self.cur_ix, .end = first } });
                    }
                    if (b_range.start < a_range.start) {
                        assert(b_range.start == self.cur_ix);
                        return self.emitHighlight(b_range.highlight, @min(a_range.start, b_range.end));
                    } else {
                        assert(a_range.start == self.cur_ix);
                        return self.emitHighlight(a_range.highlight, a_range.end);
                    }
                } else {
                    if (self.cur_ix < a_range.start) {
                        return self.emitEvent(.{ .Source = .{ .start = self.cur_ix, .end = a_range.start } });
                    }
                    assert(a_range.start == self.cur_ix);
                    return self.emitHighlight(a_range.highlight, a_range.end);
                }
            } else if (self.b_state.cur_range) |b_range| {
                if (self.cur_ix < b_range.start) {
                    return self.emitEvent(.{ .Source = .{ .start = self.cur_ix, .end = b_range.start } });
                }
                assert(b_range.start == self.cur_ix);
                return self.emitHighlight(b_range.highlight, b_range.end);
            } else {
                // Flush to end
                return self.emitEvent(.{ .Source = .{ .start = self.cur_ix, .end = self.source.len } });
            }
        }
    };
}

fn testIteratorCombinator(
    Highlight: type,
    source: []const u8,
    a_highlight: Highlight,
    b_highlight: Highlight,
    a_ranges: []const HighlightRange,
    b_ranges: []const HighlightRange,
    expected_events: []const HighlightEventT(Highlight),
) !void {
    var a_range_iter = StaticIterator(HighlightRange).init(a_ranges[0..]);
    var a_static_highlighter = StaticHighlighter(Highlight).init(source, a_range_iter.iter(), a_highlight);

    var b_range_iter = StaticIterator(HighlightRange).init(b_ranges[0..]);
    var b_static_highlighter = StaticHighlighter(Highlight).init(source, b_range_iter.iter(), b_highlight);

    var combo = IteratorCombinator(Highlight).init(source, a_static_highlighter.iter(), b_static_highlighter.iter());
    const combo_highlighter = combo.iter();

    for (expected_events) |expected| {
        const highlight_event = try combo_highlighter.next();
        if (highlight_event) |actual| {
            try std.testing.expectEqualDeep(expected, actual);
        } else {
            unreachable;
        }
    }
}

test "Basic Combination" {
    const a_highlight = .@"function.method";
    const b_highlight = .other;
    const EventT = HighlightEventT(util.TestHighlight);
    const source = "abckdfjsl3hdlzn";

    const a_ranges = [_]HighlightRange{.{ .start = 5, .end = 7 }};
    const b_ranges = [_]HighlightRange{};

    const expected_events = [_]EventT{
        EventT{ .Source = .{ .start = 0, .end = 5 } },
        EventT{ .HighlightStart = a_highlight },
        EventT{ .Source = .{ .start = 5, .end = 7 } },
        EventT{ .HighlightEnd = {} },
        EventT{ .Source = .{ .start = 7, .end = source.len } },
    };

    try testIteratorCombinator(util.TestHighlight, source, a_highlight, b_highlight, &a_ranges, &b_ranges, &expected_events);
}

test "Back Overlapping Combination" {
    const a_highlight = .@"function.method";
    const b_highlight = .other;
    const EventT = HighlightEventT(util.TestHighlight);
    const source = "abckdfjsl3hdlzn";

    const a_ranges = [_]HighlightRange{.{ .start = 5, .end = 7 }};
    const b_ranges = [_]HighlightRange{.{ .start = 6, .end = 8 }};

    const expected_events = [_]EventT{
        EventT{ .Source = .{ .start = 0, .end = 5 } },
        EventT{ .HighlightStart = a_highlight },
        EventT{ .Source = .{ .start = 5, .end = 7 } },
        EventT{ .HighlightEnd = {} },
        EventT{ .HighlightStart = b_highlight },
        EventT{ .Source = .{ .start = 7, .end = 8 } },
        EventT{ .HighlightEnd = {} },
        EventT{ .Source = .{ .start = 8, .end = source.len } },
    };

    try testIteratorCombinator(util.TestHighlight, source, a_highlight, b_highlight, &a_ranges, &b_ranges, &expected_events);
}

test "Front Overlapping Combination" {
    const a_highlight = .@"function.method";
    const b_highlight = .other;
    const EventT = HighlightEventT(util.TestHighlight);
    const source = "abckdfjsl3hdlzn";

    const a_ranges = [_]HighlightRange{.{ .start = 6, .end = 8 }};
    const b_ranges = [_]HighlightRange{.{ .start = 5, .end = 7 }};

    const expected_events = [_]EventT{
        EventT{ .Source = .{ .start = 0, .end = 5 } },
        EventT{ .HighlightStart = b_highlight },
        EventT{ .Source = .{ .start = 5, .end = 6 } },
        EventT{ .HighlightEnd = {} },
        EventT{ .HighlightStart = a_highlight },
        EventT{ .Source = .{ .start = 6, .end = 8 } },
        EventT{ .HighlightEnd = {} },
        EventT{ .Source = .{ .start = 8, .end = source.len } },
    };

    try testIteratorCombinator(util.TestHighlight, source, a_highlight, b_highlight, &a_ranges, &b_ranges, &expected_events);
}

test "Only B Combination" {
    const a_highlight = .@"function.method";
    const b_highlight = .other;
    const EventT = HighlightEventT(util.TestHighlight);
    const source = "abckdfjsl3hdlzn";

    const a_ranges = [_]HighlightRange{};
    const b_ranges = [_]HighlightRange{.{ .start = 5, .end = 7 }};

    const expected_events = [_]EventT{
        EventT{ .Source = .{ .start = 0, .end = 5 } },
        EventT{ .HighlightStart = b_highlight },
        EventT{ .Source = .{ .start = 5, .end = 7 } },
        EventT{ .HighlightEnd = {} },
        EventT{ .Source = .{ .start = 7, .end = source.len } },
    };

    try testIteratorCombinator(util.TestHighlight, source, a_highlight, b_highlight, &a_ranges, &b_ranges, &expected_events);
}

test "Hidden B Combination" {
    const a_highlight = .@"function.method";
    const b_highlight = .other;
    const EventT = HighlightEventT(util.TestHighlight);
    const source = "abckdfjsl3hdlzn";

    const a_ranges = [_]HighlightRange{
        .{ .start = 5, .end = 8 },
    };
    const b_ranges = [_]HighlightRange{
        .{ .start = 5, .end = 7 },
        .{ .start = 9, .end = 10 },
    };

    const expected_events = [_]EventT{
        EventT{ .Source = .{ .start = 0, .end = 5 } },
        EventT{ .HighlightStart = a_highlight },
        EventT{ .Source = .{ .start = 5, .end = 8 } },
        EventT{ .HighlightEnd = {} },
        EventT{ .Source = .{ .start = 8, .end = 9 } },
        EventT{ .HighlightStart = b_highlight },
        EventT{ .Source = .{ .start = 9, .end = 10 } },
        EventT{ .HighlightEnd = {} },
        EventT{ .Source = .{ .start = 10, .end = source.len } },
    };

    try testIteratorCombinator(
        util.TestHighlight,
        source,
        a_highlight,
        b_highlight,
        &a_ranges,
        &b_ranges,
        &expected_events,
    );
}

test "Double Overlapping B Combination" {
    const a_highlight = .@"function.method";
    const b_highlight = .other;
    const EventT = HighlightEventT(util.TestHighlight);
    const source = "abckdfjsl3hdlzn";

    const a_ranges = [_]HighlightRange{
        .{ .start = 5, .end = 8 },
        .{ .start = 9, .end = 12 },
    };
    const b_ranges = [_]HighlightRange{
        .{ .start = 7, .end = 10 },
    };

    const expected_events = [_]EventT{
        EventT{ .Source = .{ .start = 0, .end = 5 } },
        EventT{ .HighlightStart = a_highlight },
        EventT{ .Source = .{ .start = 5, .end = 8 } },
        EventT{ .HighlightEnd = {} },
        EventT{ .HighlightStart = b_highlight },
        EventT{ .Source = .{ .start = 8, .end = 9 } },
        EventT{ .HighlightEnd = {} },
        EventT{ .HighlightStart = a_highlight },
        EventT{ .Source = .{ .start = 9, .end = 12 } },
        EventT{ .HighlightEnd = {} },
        EventT{ .Source = .{ .start = 12, .end = source.len } },
    };

    try testIteratorCombinator(
        util.TestHighlight,
        source,
        a_highlight,
        b_highlight,
        &a_ranges,
        &b_ranges,
        &expected_events,
    );
}
