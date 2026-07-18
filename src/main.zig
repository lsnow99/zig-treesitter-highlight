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
    var highlighter_cfg = try default.createHighlighterConfig(HighlightT).create(allocator, python_language, raw_query);
    defer highlighter_cfg.destroy();
    var highlighter = try highlighter_cfg.highlight(contents, null);
    defer highlighter.destroy();
    const highlight_iter = highlighter.iter();

    var buf: [1024]u8 = undefined;
    var writer = std.fs.File.stdout().writer(&buf);
    const out = &writer.interface;

    try default.renderTerminal(HighlightT, contents, out, highlight_iter, default.std_name_map.terminal_code_map);
}
