const std = @import("std");
const default = @import("default");
const ts = @import("tree-sitter");

extern fn tree_sitter_python() callconv(.c) *ts.Language;

pub fn main() !void {
    var args = std.process.args();
    _ = args.skip();

    const filepath = args.next() orelse {
        std.debug.panic("expected a file", .{});
    };

    if (!std.mem.endsWith(u8, filepath, ".py")) {
        std.debug.panic("only .py files supported for now", .{});
    }

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const contents = try std.fs.Dir.readFileAlloc(std.fs.cwd(), allocator, filepath, 1 << 23);
    defer allocator.free(contents);

    const raw_query = @embedFile("python_highlight.scm");

    const python_language = tree_sitter_python();
    defer python_language.destroy();
    const names = try default.collectNames(allocator, python_language, raw_query);
    defer allocator.free(names);

    const HighlightT = default.std_name_map.HighlightT;
    const highlighterConfig = default.createHighlighterConfig(HighlightT);
    var highlighter = try highlighterConfig.create(allocator, python_language, raw_query);
    defer highlighter.destroy();

    var buf: [1024]u8 = undefined;
    var writer = std.fs.File.stdout().writer(&buf);
    const out = &writer.interface;

    try default.renderHTML(contents, out, highlighter, default.std_name_map.style_map, .{});
}

test "simple test" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(i32) = .empty;
    defer list.deinit(gpa); // Try commenting this out and see if zig detects the memory leak!
    try list.append(gpa, 42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}

test "fuzz example" {
    const Context = struct {
        fn testOne(context: @This(), input: []const u8) anyerror!void {
            _ = context;
            // Try passing `--fuzz` to `zig build test` and see if it manages to fail this test case!
            try std.testing.expect(!std.mem.eql(u8, "canyoufindme", input));
        }
    };
    try std.testing.fuzz(Context{}, Context.testOne, .{});
}
