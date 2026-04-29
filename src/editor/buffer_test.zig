const std = @import("std");
const buffer = @import("buffer.zig");
const Line = buffer.Line;

test "Line: basic insert and delete" {
    const allocator = std.testing.allocator;
    var line = try Line.init(allocator);
    defer line.deinit();

    try line.insert(0, 'a');
    try line.insert(1, 'b');
    try line.insert(2, 'c');

    const s = try line.slice(allocator);
    defer allocator.free(s);
    try std.testing.expectEqualStrings("abc", s);

    _ = line.deleteBack(2);
    const s2 = try line.slice(allocator);
    defer allocator.free(s2);
    try std.testing.expectEqualStrings("ac", s2);
}

test "Buffer: merge lines on deleteCharBack" {
    const allocator = std.testing.allocator;
    var buf = Buffer{
        .lines = std.ArrayList(Line).empty,
        .allocator = allocator,
    };
    defer buf.deinit();

    try buf.lines.append(allocator, try Line.fromSlice(allocator, "first"));
    try buf.lines.append(allocator, try Line.fromSlice(allocator, "second"));

    // Delete at start of second line should merge
    const merged = try buf.deleteCharBack(1, 0);
    try std.testing.expect(merged);
    try std.testing.expectEqual(@as(usize, 1), buf.lines.items.len);

    const s = try buf.lines.items[0].slice(allocator);
    defer allocator.free(s);
    try std.testing.expectEqualStrings("firstsecond", s);
}

const Buffer = struct {
    lines: std.ArrayListUnmanaged(Line),
    allocator: std.mem.Allocator,
    is_dirty: bool = false,

    pub fn deinit(self: *Buffer) void {
        for (self.lines.items) |*l| l.deinit();
        self.lines.deinit(self.allocator);
    }

    pub fn deleteCharBack(self: *Buffer, row: usize, col: usize) !bool {
        // Redefine here for test or import from buffer.zig if accessible
        // (Actually it's better to make the original file testable)
        return @import("buffer.zig").Buffer.deleteCharBack(self, row, col);
    }
};
