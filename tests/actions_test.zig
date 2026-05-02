//! actions_test.zig — unit tests for actions.zig
//!
//! Tests copy, cut, paste, line manipulation, and multi-cursor actions.

const std = @import("std");
const actions = @import("../src/editor/actions.zig");
const editor_mod = @import("../src/editor/editor.zig");
const buffer_mod = @import("../src/editor/model/buffer.zig");
const th = @import("test_helpers.zig");

// ── Helpers ───────────────────────────────────────────────────────────────────

fn expectLine(a: std.mem.Allocator, ed: *editor_mod.Editor, row: usize, expected: []const u8) !void {
    const s = try th.lineText(a, ed, row);
    defer a.free(s);
    try std.testing.expectEqualStrings(expected, s);
}

fn setSelection(ed: *editor_mod.Editor, s_row: usize, s_col: usize, e_row: usize, e_col: usize) void {
    const tab = ed.currentTab().?;
    const mc = tab.mainCursor();
    mc.selection_start = .{ .row = s_row, .col = s_col };
    mc.row = e_row;
    mc.col = e_col;
}

// ── copy ──────────────────────────────────────────────────────────────────────

test "copy: no selection copies current line" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{"flamingo"});
    defer ed.deinit();

    try actions.copy(&ed);
    try std.testing.expect(ed.state.clipboard != null);
    try std.testing.expectEqualStrings("flamingo", ed.state.clipboard.?);
}

test "copy: with selection copies range only" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{"hello world"});
    defer ed.deinit();

    setSelection(&ed, 0, 6, 0, 11); // select "world"
    try actions.copy(&ed);
    try std.testing.expect(ed.state.clipboard != null);
    try std.testing.expectEqualStrings("world", ed.state.clipboard.?);
}

test "copy: multi-line selection includes newline" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{ "abc", "def" });
    defer ed.deinit();

    setSelection(&ed, 0, 1, 1, 2); // "bc\nde"
    try actions.copy(&ed);
    try std.testing.expect(ed.state.clipboard != null);
    try std.testing.expectEqualStrings("bc\nde", ed.state.clipboard.?);
}

// ── cut ───────────────────────────────────────────────────────────────────────

test "cut: no selection removes current line" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{ "first", "second" });
    defer ed.deinit();

    const tab = ed.currentTab().?;
    tab.mainCursor().row = 0;
    try actions.cut(&ed);

    try std.testing.expectEqual(@as(usize, 1), tab.buf.lines.items.len);
    try expectLine(a, &ed, 0, "second");
    try std.testing.expectEqualStrings("first", ed.state.clipboard.?);
}

test "cut: on last line buffer stays non-empty" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{"only line"});
    defer ed.deinit();

    try actions.cut(&ed);
    try std.testing.expect(ed.currentTab().?.buf.lines.items.len >= 1);
}

test "cut: with selection removes the selected range" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{"hello world"});
    defer ed.deinit();

    setSelection(&ed, 0, 6, 0, 11); // "world"
    try actions.cut(&ed);
    try expectLine(a, &ed, 0, "hello ");
    try std.testing.expectEqualStrings("world", ed.state.clipboard.?);
}

// ── paste ─────────────────────────────────────────────────────────────────────

test "paste: no selection inserts at cursor" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{"world"});
    defer ed.deinit();

    ed.state.clipboard = try a.dupe(u8, "hello ");
    const tab = ed.currentTab().?;
    tab.mainCursor().col = 0;

    try actions.paste(&ed);
    try expectLine(a, &ed, 0, "hello world");
}

test "paste: with selection replaces it" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{"foo BAR baz"});
    defer ed.deinit();

    setSelection(&ed, 0, 4, 0, 7); // "BAR"
    ed.state.clipboard = try a.dupe(u8, "qux");
    try actions.paste(&ed);
    try expectLine(a, &ed, 0, "foo qux baz");
}

test "paste: multiline content splits into multiple lines" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{""});
    defer ed.deinit();

    ed.state.clipboard = try a.dupe(u8, "line1\nline2\nline3");
    try actions.paste(&ed);

    const tab = ed.currentTab().?;
    try std.testing.expectEqual(@as(usize, 3), tab.buf.lines.items.len);
    try expectLine(a, &ed, 0, "line1");
    try expectLine(a, &ed, 1, "line2");
    try expectLine(a, &ed, 2, "line3");
}

// ── moveLineUp / moveLineDown ──────────────────────────────────────────────────

test "moveLineUp: swaps with previous row" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{ "first", "second" });
    defer ed.deinit();

    ed.currentTab().?.mainCursor().row = 1;
    actions.moveLineUp(&ed);

    try expectLine(a, &ed, 0, "second");
    try expectLine(a, &ed, 1, "first");
    try std.testing.expectEqual(@as(usize, 0), ed.currentTab().?.mainCursor().row);
}

test "moveLineUp: at row 0 is a no-op" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{ "first", "second" });
    defer ed.deinit();

    ed.currentTab().?.mainCursor().row = 0;
    actions.moveLineUp(&ed);
    try expectLine(a, &ed, 0, "first");
}

test "moveLineDown: swaps with next row" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{ "first", "second" });
    defer ed.deinit();

    ed.currentTab().?.mainCursor().row = 0;
    actions.moveLineDown(&ed);

    try expectLine(a, &ed, 0, "second");
    try expectLine(a, &ed, 1, "first");
    try std.testing.expectEqual(@as(usize, 1), ed.currentTab().?.mainCursor().row);
}

test "moveLineDown: at last row is a no-op" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{ "first", "second" });
    defer ed.deinit();

    ed.currentTab().?.mainCursor().row = 1;
    actions.moveLineDown(&ed);
    try expectLine(a, &ed, 1, "second");
}

// ── duplicateLine ─────────────────────────────────────────────────────────────

test "duplicateLine: inserts a copy below current row" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{"flamingo"});
    defer ed.deinit();

    try actions.duplicateLine(&ed);

    const tab = ed.currentTab().?;
    try std.testing.expectEqual(@as(usize, 2), tab.buf.lines.items.len);
    try expectLine(a, &ed, 0, "flamingo");
    try expectLine(a, &ed, 1, "flamingo");
    try std.testing.expect(tab.buf.is_dirty);
}

// ── deleteLine ────────────────────────────────────────────────────────────────

test "deleteLine: removes mid-buffer line" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{ "a", "b", "c" });
    defer ed.deinit();

    ed.currentTab().?.mainCursor().row = 1;
    try actions.deleteLine(&ed);

    const tab = ed.currentTab().?;
    try std.testing.expectEqual(@as(usize, 2), tab.buf.lines.items.len);
    try expectLine(a, &ed, 0, "a");
    try expectLine(a, &ed, 1, "c");
}

test "deleteLine: last line leaves buffer with at least one line" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{"only"});
    defer ed.deinit();

    try actions.deleteLine(&ed);
    try std.testing.expect(ed.currentTab().?.buf.lines.items.len >= 1);
}

test "deleteLine: final row removes the line instead of merging it" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{ "first", "second" });
    defer ed.deinit();

    ed.currentTab().?.mainCursor().row = 1;
    try actions.deleteLine(&ed);

    const tab = ed.currentTab().?;
    try std.testing.expectEqual(@as(usize, 1), tab.buf.lines.items.len);
    try expectLine(a, &ed, 0, "first");
    try std.testing.expect(tab.buf.lastEditDelta() != null);
}

// ── multi-cursor ──────────────────────────────────────────────────────────────

test "addCursorAbove: adds cursor on row above" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{ "row0", "row1", "row2" });
    defer ed.deinit();

    ed.currentTab().?.mainCursor().row = 2;
    ed.currentTab().?.mainCursor().col = 2;
    try actions.addCursorAbove(&ed);

    const tab = ed.currentTab().?;
    try std.testing.expectEqual(@as(usize, 2), tab.cursors.items.len);
    // new cursor is on row 1
    try std.testing.expectEqual(@as(usize, 1), tab.cursors.items[0].row);
}

test "addCursorAbove: at row 0 is a no-op" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{ "a", "b" });
    defer ed.deinit();

    ed.currentTab().?.mainCursor().row = 0;
    try actions.addCursorAbove(&ed);
    try std.testing.expectEqual(@as(usize, 1), ed.currentTab().?.cursors.items.len);
}

test "addCursorBelow: adds cursor on row below" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{ "row0", "row1", "row2" });
    defer ed.deinit();

    ed.currentTab().?.mainCursor().row = 0;
    ed.currentTab().?.mainCursor().col = 2;
    try actions.addCursorBelow(&ed);

    const tab = ed.currentTab().?;
    try std.testing.expectEqual(@as(usize, 2), tab.cursors.items.len);
    const new_cursor = tab.cursors.items[1];
    try std.testing.expectEqual(@as(usize, 1), new_cursor.row);
}

test "addCursorBelow: at last row is a no-op" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{ "a", "b" });
    defer ed.deinit();

    ed.currentTab().?.mainCursor().row = 1;
    try actions.addCursorBelow(&ed);
    try std.testing.expectEqual(@as(usize, 1), ed.currentTab().?.cursors.items.len);
}

test "clearSelections: reduces to single cursor, clears all selections" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{ "a", "b", "c" });
    defer ed.deinit();

    // Add extra cursors and selections.
    ed.currentTab().?.mainCursor().row = 2;
    try actions.addCursorAbove(&ed);
    try actions.addCursorAbove(&ed);
    ed.currentTab().?.mainCursor().selection_start = .{ .row = 0, .col = 0 };

    actions.clearSelections(&ed);

    const tab = ed.currentTab().?;
    try std.testing.expectEqual(@as(usize, 1), tab.cursors.items.len);
    try std.testing.expect(tab.cursors.items[0].selection_start == null);
}

// ── selectAll ─────────────────────────────────────────────────────────────────

test "selectAll: selection_start at (0,0) cursor at end of last line" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{ "hello", "world", "flamingo" });
    defer ed.deinit();

    actions.selectAll(&ed);

    const mc = ed.currentTab().?.mainCursor();
    try std.testing.expect(mc.selection_start != null);
    try std.testing.expectEqual(@as(usize, 0), mc.selection_start.?.row);
    try std.testing.expectEqual(@as(usize, 0), mc.selection_start.?.col);
    try std.testing.expectEqual(@as(usize, 2), mc.row); // last row index
    try std.testing.expectEqual(@as(usize, 8), mc.col); // len("flamingo")
}
