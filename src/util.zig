const std = @import("std");
const assert = std.debug.assert;
const print = std.debug.print;
const createEnum = @import("root.zig").createEnum;

pub fn dbg(str: []const u8) void {
    print("DBG: {s}\n", .{str});
}

pub const test_names = [_][]const u8{ "function.method", "other" };
pub const TestHighlight = createEnum(&test_names);
