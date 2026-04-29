//! buffer_extended_test.zig — extended unit tests for buffer.zig
//!
//! Complements the inline tests already in buffer.zig with edge-case coverage.

const std = @import("std");
const buf_mod = @import("../src/editor/buffer.zig");
const Line = buf_mod.Line;
const Buffer = buf_mod.Buffer;

// ── Line tests ────────────────────────────────────────────────────────────────

test "Line: insert at position 0 (prepend)" {
    const a = std.testing.allocator;
    var line = try Line.fromSlice(a, "bc");
    defer line.deinit();

    try line.insert(0, 'a');

    const s = try line.slice(a);
    defer a.free(s);
    try std.testing.expectEqualStrings("abc", s);
}

test "Line: insert at len() (append)" {
    const a = std.testing.allocator;
    var line = try Line.fromSlice(a, "ab");
    defer line.deinit();

    try line.insert(line.len(), 'c');

    const s = try line.slice(a);
    defer a.free(s);
    try std.testing.expectEqualStrings("abc", s);
}

test "Line: deleteBack at pos 0 returns false (no-op)" {
    const a = std.testing.allocator;
    var line = try Line.fromSlice(a, "abc");
    defer line.deinit();

    const deleted = line.deleteBack(0);
    try std.testing.expect(!deleted);

    const s = try line.slice(a);
    defer a.free(s);
    try std.testing.expectEqualStrings("abc", s);
}

test "Line: ensureGap triggers realloc (insert > 32 chars)" {
    const a = std.testing.allocator;
    // A fresh line has a 32-byte gap; inserting 40 chars forces realloc.
    var line = try Line.init(a);
    defer line.deinit();

    for (0..40) |i| {
        try line.insert(i, 'x');
    }
    try std.testing.expectEqual(@as(usize, 40), line.len());
}

test "Line: writeTo respects max_len" {
    const a = std.testing.allocator;
    var line = try Line.fromSlice(a, "hello world");
    defer line.deinit();

    var out = std.ArrayListUnmanaged(u8).empty;
    defer out.deinit(a);

    try line.writeTo(out.writer(a), 5);
    try std.testing.expectEqualStrings("hello", out.items);
}

test "Line: len() is zero for empty line" {
    const a = std.testing.allocator;
    var line = try Line.init(a);
    defer line.deinit();
    try std.testing.expectEqual(@as(usize, 0), line.len());
}

// ── Buffer tests ──────────────────────────────────────────────────────────────

fn makeBuffer(a: std.mem.Allocator, lines_text: []const []const u8) !Buffer {
    var b = Buffer{
        .lines = std.ArrayList(Line).empty,
        .allocator = a,
    };
    for (lines_text) |t| {
        try b.lines.append(a, try Line.fromSlice(a, t));
    }
    if (b.lines.items.len == 0) {
        try b.lines.append(a, try Line.init(a));
    }
    return b;
}

test "Buffer: insertChar out-of-bounds row is no-op" {
    const a = std.testing.allocator;
    var b = try makeBuffer(a, &[_][]const u8{"hello"});
    defer b.deinit();

    // Row 99 does not exist — must not panic or corrupt state.
    try b.insertChar(99, 0, 'x');
    try std.testing.expectEqual(@as(usize, 1), b.lines.items.len);
    const s = try b.lines.items[0].slice(a);
    defer a.free(s);
    try std.testing.expectEqualStrings("hello", s);
}

test "Buffer: insertChar marks buffer dirty" {
    const a = std.testing.allocator;
    var b = try makeBuffer(a, &[_][]const u8{"hi"});
    defer b.deinit();

    try std.testing.expect(!b.is_dirty);
    try b.insertChar(0, 0, 'X');
    try std.testing.expect(b.is_dirty);
}

test "Buffer: insertNewline splits line at mid-position" {
    const a = std.testing.allocator;
    var b = try makeBuffer(a, &[_][]const u8{"abcde"});
    defer b.deinit();

    try b.insertNewline(0, 2); // split after "ab"
    try std.testing.expectEqual(@as(usize, 2), b.lines.items.len);

    const s0 = try b.lines.items[0].slice(a);
    defer a.free(s0);
    try std.testing.expectEqualStrings("ab", s0);

    const s1 = try b.lines.items[1].slice(a);
    defer a.free(s1);
    try std.testing.expectEqualStrings("cde", s1);
}

test "Buffer: insertNewline at col 0 prepends empty line" {
    const a = std.testing.allocator;
    var b = try makeBuffer(a, &[_][]const u8{"hello"});
    defer b.deinit();

    try b.insertNewline(0, 0);
    try std.testing.expectEqual(@as(usize, 2), b.lines.items.len);

    const s0 = try b.lines.items[0].slice(a);
    defer a.free(s0);
    try std.testing.expectEqualStrings("", s0);

    const s1 = try b.lines.items[1].slice(a);
    defer a.free(s1);
    try std.testing.expectEqualStrings("hello", s1);
}

test "Buffer: deleteCharBack mid-line returns false (no merge)" {
    const a = std.testing.allocator;
    var b = try makeBuffer(a, &[_][]const u8{"abc"});
    defer b.deinit();

    const merged = try b.deleteCharBack(0, 2); // delete 'b'
    try std.testing.expect(!merged);
    try std.testing.expectEqual(@as(usize, 1), b.lines.items.len);

    const s = try b.lines.items[0].slice(a);
    defer a.free(s);
    try std.testing.expectEqualStrings("ac", s);
}

test "Buffer: deleteCharBack at (0,0) is a no-op" {
    const a = std.testing.allocator;
    var b = try makeBuffer(a, &[_][]const u8{"abc"});
    defer b.deinit();

    const merged = try b.deleteCharBack(0, 0);
    try std.testing.expect(!merged);

    const s = try b.lines.items[0].slice(a);
    defer a.free(s);
    try std.testing.expectEqualStrings("abc", s);
}

test "Buffer: getRange single line" {
    const a = std.testing.allocator;
    var b = try makeBuffer(a, &[_][]const u8{"hello world"});
    defer b.deinit();

    const got = try b.getRange(0, 6, 0, 11);
    defer a.free(got);
    try std.testing.expectEqualStrings("world", got);
}

test "Buffer: getRange multi-line includes newline" {
    const a = std.testing.allocator;
    var b = try makeBuffer(a, &[_][]const u8{ "abc", "def" });
    defer b.deinit();

    const got = try b.getRange(0, 1, 1, 2);
    defer a.free(got);
    try std.testing.expectEqualStrings("bc\nde", got);
}

test "Buffer: deleteRange single line" {
    const a = std.testing.allocator;
    var b = try makeBuffer(a, &[_][]const u8{"flamingo"});
    defer b.deinit();

    try b.deleteRange(0, 3, 0, 6); // remove "min"
    const s = try b.lines.items[0].slice(a);
    defer a.free(s);
    try std.testing.expectEqualStrings("flago", s);
}

test "Buffer: swapLines exchanges content and sets dirty" {
    const a = std.testing.allocator;
    var b = try makeBuffer(a, &[_][]const u8{ "first", "second" });
    defer b.deinit();

    b.swapLines(0, 1);
    try std.testing.expect(b.is_dirty);

    const s0 = try b.lines.items[0].slice(a);
    defer a.free(s0);
    try std.testing.expectEqualStrings("second", s0);

    const s1 = try b.lines.items[1].slice(a);
    defer a.free(s1);
    try std.testing.expectEqualStrings("first", s1);
}

// ── countDigits ───────────────────────────────────────────────────────────────

test "countDigits: boundary values" {
    try std.testing.expectEqual(@as(usize, 1), buf_mod.countDigits(0));
    try std.testing.expectEqual(@as(usize, 1), buf_mod.countDigits(1));
    try std.testing.expectEqual(@as(usize, 1), buf_mod.countDigits(9));
    try std.testing.expectEqual(@as(usize, 2), buf_mod.countDigits(10));
    try std.testing.expectEqual(@as(usize, 2), buf_mod.countDigits(99));
    try std.testing.expectEqual(@as(usize, 3), buf_mod.countDigits(100));
    try std.testing.expectEqual(@as(usize, 3), buf_mod.countDigits(999));
    try std.testing.expectEqual(@as(usize, 4), buf_mod.countDigits(1000));
}

// ── getCharClass ──────────────────────────────────────────────────────────────

test "getCharClass: spaces and tabs" {
    try std.testing.expectEqual(buf_mod.CharClass.Space, buf_mod.getCharClass(' '));
    try std.testing.expectEqual(buf_mod.CharClass.Space, buf_mod.getCharClass('\t'));
    try std.testing.expectEqual(buf_mod.CharClass.Space, buf_mod.getCharClass('\n'));
}

test "getCharClass: alphanumeric and underscore" {
    try std.testing.expectEqual(buf_mod.CharClass.Alphanum, buf_mod.getCharClass('a'));
    try std.testing.expectEqual(buf_mod.CharClass.Alphanum, buf_mod.getCharClass('Z'));
    try std.testing.expectEqual(buf_mod.CharClass.Alphanum, buf_mod.getCharClass('0'));
    try std.testing.expectEqual(buf_mod.CharClass.Alphanum, buf_mod.getCharClass('_'));
}

test "getCharClass: punctuation" {
    try std.testing.expectEqual(buf_mod.CharClass.Punctuation, buf_mod.getCharClass('.'));
    try std.testing.expectEqual(buf_mod.CharClass.Punctuation, buf_mod.getCharClass('!'));
    try std.testing.expectEqual(buf_mod.CharClass.Punctuation, buf_mod.getCharClass('{'));
}
