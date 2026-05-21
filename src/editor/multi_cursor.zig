const std = @import("std");
const buffer_mod = @import("model/buffer.zig");

pub const SelectionRange = struct {
    start_line: usize,
    start_col: usize,
    end_line: usize,
    end_col: usize,

    pub fn eql(self: SelectionRange, other: SelectionRange) bool {
        return self.start_line == other.start_line and
            self.start_col == other.start_col and
            self.end_line == other.end_line and
            self.end_col == other.end_col;
    }

    pub fn isEmpty(self: SelectionRange) bool {
        return self.start_line == self.end_line and self.start_col == self.end_col;
    }
};

pub const CursorPosition = struct {
    row: usize,
    col: usize,
};

pub const SelectionEdge = enum {
    start,
    end,
};

pub const MultiCursorState = struct {
    active: bool = false,
    query: []u8 = &.{},
    selections: std.ArrayListUnmanaged(SelectionRange) = .empty,
    cursors: std.ArrayListUnmanaged(CursorPosition) = .empty,
    anchor_buffer_id: ?u64 = null,

    pub fn deinit(self: *MultiCursorState, allocator: std.mem.Allocator) void {
        self.clear(allocator);
        self.selections.deinit(allocator);
        self.cursors.deinit(allocator);
    }

    pub fn clear(self: *MultiCursorState, allocator: std.mem.Allocator) void {
        if (self.query.len > 0) {
            allocator.free(self.query);
        }
        self.query = &.{};
        self.selections.clearRetainingCapacity();
        self.cursors.clearRetainingCapacity();
        self.active = false;
        self.anchor_buffer_id = null;
    }

    pub fn hasSelections(self: *const MultiCursorState) bool {
        return self.active and self.selections.items.len > 0;
    }

    pub fn hasCursors(self: *const MultiCursorState) bool {
        return self.active and self.cursors.items.len > 0;
    }
};

pub fn normalizedSelection(anchor_row: usize, anchor_col: usize, cursor_row: usize, cursor_col: usize) SelectionRange {
    if (anchor_row < cursor_row or (anchor_row == cursor_row and anchor_col <= cursor_col)) {
        return .{
            .start_line = anchor_row,
            .start_col = anchor_col,
            .end_line = cursor_row,
            .end_col = cursor_col,
        };
    }
    return .{
        .start_line = cursor_row,
        .start_col = cursor_col,
        .end_line = anchor_row,
        .end_col = anchor_col,
    };
}

pub fn isValidWordSelection(buf: *buffer_mod.Buffer, range: SelectionRange) bool {
    if (range.isEmpty()) return false;
    if (range.start_line != range.end_line) return false;
    if (range.start_line >= buf.lines.items.len) return false;
    const line = &buf.lines.items[range.start_line];
    if (range.end_col > line.len()) return false;
    var col = range.start_col;
    while (col < range.end_col) : (col += 1) {
        const ch = line.byteAt(col) orelse return false;
        if (buffer_mod.getCharClass(ch) != .Alphanum) return false;
    }
    return true;
}

pub fn wordSelectionAtCursor(buf: *buffer_mod.Buffer, row: usize, col: usize) ?SelectionRange {
    if (row >= buf.lines.items.len) return null;
    const line = &buf.lines.items[row];
    const line_len = line.len();
    if (line_len == 0) return null;

    var seed = @min(col, line_len - 1);
    if (buffer_mod.getCharClass(line.byteAt(seed) orelse return null) != .Alphanum) {
        if (seed == 0) return null;
        seed -= 1;
        if (buffer_mod.getCharClass(line.byteAt(seed) orelse return null) != .Alphanum) return null;
    }

    var start = seed;
    while (start > 0) {
        const prev = line.byteAt(start - 1) orelse break;
        if (buffer_mod.getCharClass(prev) != .Alphanum) break;
        start -= 1;
    }

    var end = seed + 1;
    while (end < line_len) : (end += 1) {
        const next = line.byteAt(end) orelse break;
        if (buffer_mod.getCharClass(next) != .Alphanum) break;
    }

    return .{
        .start_line = row,
        .start_col = start,
        .end_line = row,
        .end_col = end,
    };
}

pub fn rangeLessThan(_: void, lhs: SelectionRange, rhs: SelectionRange) bool {
    if (lhs.start_line != rhs.start_line) return lhs.start_line < rhs.start_line;
    if (lhs.start_col != rhs.start_col) return lhs.start_col < rhs.start_col;
    if (lhs.end_line != rhs.end_line) return lhs.end_line < rhs.end_line;
    return lhs.end_col < rhs.end_col;
}

pub fn cursorLessThan(_: void, lhs: CursorPosition, rhs: CursorPosition) bool {
    if (lhs.row != rhs.row) return lhs.row < rhs.row;
    return lhs.col < rhs.col;
}

pub fn containsRange(ranges: []const SelectionRange, candidate: SelectionRange) bool {
    for (ranges) |range| {
        if (range.eql(candidate)) return true;
    }
    return false;
}

pub fn overlapsAnyRange(ranges: []const SelectionRange, candidate: SelectionRange) bool {
    for (ranges) |range| {
        if (rangesOverlap(range, candidate)) return true;
    }
    return false;
}

pub fn appendSelectionSorted(
    allocator: std.mem.Allocator,
    selections: *std.ArrayListUnmanaged(SelectionRange),
    candidate: SelectionRange,
) !bool {
    if (candidate.isEmpty()) return false;
    if (overlapsAnyRange(selections.items, candidate)) return false;
    try selections.append(allocator, candidate);
    std.mem.sort(SelectionRange, selections.items, {}, rangeLessThan);
    return true;
}

pub fn syncCursorsToSelections(
    allocator: std.mem.Allocator,
    state: *MultiCursorState,
    edge: SelectionEdge,
    clear_selections: bool,
) !?CursorPosition {
    if (!state.hasSelections()) return null;

    std.mem.sort(SelectionRange, state.selections.items, {}, rangeLessThan);
    state.cursors.clearRetainingCapacity();
    for (state.selections.items) |range| {
        const cursor = switch (edge) {
            .start => CursorPosition{ .row = range.start_line, .col = range.start_col },
            .end => CursorPosition{ .row = range.end_line, .col = range.end_col },
        };
        try state.cursors.append(allocator, cursor);
    }
    dedupeSortedCursors(state);
    if (clear_selections) state.selections.clearRetainingCapacity();
    return if (state.cursors.items.len > 0) state.cursors.items[state.cursors.items.len - 1] else null;
}

pub fn findNextWordOccurrence(
    buf: *buffer_mod.Buffer,
    query: []const u8,
    after: CursorPosition,
    already_selected: []const SelectionRange,
) ?SelectionRange {
    if (query.len == 0 or buf.lines.items.len == 0) return null;
    const start_row = @min(after.row, buf.lines.items.len - 1);
    const start_col = @min(after.col, buf.lines.items[start_row].len());

    if (findFrom(buf, query, start_row, start_col, already_selected)) |range| return range;
    if (start_row == 0 and start_col == 0) return null;
    return findFrom(buf, query, 0, 0, already_selected) orelse null;
}

pub fn beginSelectNextOccurrence(
    allocator: std.mem.Allocator,
    state: *MultiCursorState,
    buf: *buffer_mod.Buffer,
    buffer_id: u64,
    current_selection: SelectionRange,
) !bool {
    if (!isValidWordSelection(buf, current_selection)) return false;

    if (!state.active or state.anchor_buffer_id != buffer_id) {
        state.clear(allocator);
        state.query = try buf.getRange(
            current_selection.start_line,
            current_selection.start_col,
            current_selection.end_line,
            current_selection.end_col,
        );
        state.active = true;
        state.anchor_buffer_id = buffer_id;
        _ = try appendSelectionSorted(allocator, &state.selections, current_selection);
    } else if (state.selections.items.len == 0 and state.cursors.items.len == 0) {
        _ = try appendSelectionSorted(allocator, &state.selections, current_selection);
    }

    const after = if (state.selections.items.len > 0) blk: {
        const last = state.selections.items[state.selections.items.len - 1];
        break :blk CursorPosition{ .row = last.end_line, .col = last.end_col };
    } else CursorPosition{ .row = current_selection.end_line, .col = current_selection.end_col };

    const next = findNextWordOccurrence(buf, state.query, after, state.selections.items) orelse return false;
    return appendSelectionSorted(allocator, &state.selections, next);
}

pub fn replaceSelectionsWithText(
    allocator: std.mem.Allocator,
    state: *MultiCursorState,
    buf: *buffer_mod.Buffer,
    text: []const u8,
) !?CursorPosition {
    if (!state.hasSelections()) return null;

    std.mem.sort(SelectionRange, state.selections.items, {}, rangeLessThan);
    state.cursors.clearRetainingCapacity();

    var current_line: ?usize = null;
    var line_delta: isize = 0;
    for (state.selections.items) |range| {
        if (current_line == null or current_line.? != range.start_line) {
            current_line = range.start_line;
            line_delta = 0;
        }
        const adjusted_start: usize = @intCast(@as(isize, @intCast(range.start_col)) + line_delta);
        try state.cursors.append(allocator, .{ .row = range.start_line, .col = adjusted_start + text.len });
        line_delta += @as(isize, @intCast(text.len)) - @as(isize, @intCast(range.end_col - range.start_col));
    }

    buf.beginUndoGroup();
    defer buf.endUndoGroup();

    var i = state.selections.items.len;
    while (i > 0) {
        i -= 1;
        const range = state.selections.items[i];
        try buf.deleteRange(range.start_line, range.start_col, range.end_line, range.end_col);
        var col = range.start_col;
        for (text) |ch| {
            if (ch == '\n') continue;
            try buf.insertChar(range.start_line, col, ch);
            col += 1;
        }
    }

    state.selections.clearRetainingCapacity();
    std.mem.sort(CursorPosition, state.cursors.items, {}, cursorLessThan);
    return if (state.cursors.items.len > 0) state.cursors.items[state.cursors.items.len - 1] else null;
}

pub fn insertTextAtCursors(
    state: *MultiCursorState,
    buf: *buffer_mod.Buffer,
    text: []const u8,
) !?CursorPosition {
    if (!state.hasCursors()) return null;

    std.mem.sort(CursorPosition, state.cursors.items, {}, cursorLessThan);
    const original_cursors = try buf.allocator.dupe(CursorPosition, state.cursors.items);
    defer buf.allocator.free(original_cursors);

    buf.beginUndoGroup();
    defer buf.endUndoGroup();

    var i = original_cursors.len;
    while (i > 0) {
        i -= 1;
        var cursor = original_cursors[i];
        if (cursor.row >= buf.lines.items.len) continue;
        cursor.col = @min(cursor.col, buf.lines.items[cursor.row].len());
        for (text) |ch| {
            if (ch == '\n') continue;
            try buf.insertChar(cursor.row, cursor.col, ch);
            cursor.col += 1;
        }
    }

    var current_line: ?usize = null;
    var inserted_on_line: usize = 0;
    for (original_cursors, 0..) |cursor, index| {
        if (cursor.row >= buf.lines.items.len) continue;
        if (current_line == null or current_line.? != cursor.row) {
            current_line = cursor.row;
            inserted_on_line = 0;
        }
        state.cursors.items[index] = .{
            .row = cursor.row,
            .col = @min(cursor.col, buf.lines.items[cursor.row].len()) + inserted_on_line + text.len,
        };
        inserted_on_line += text.len;
    }

    std.mem.sort(CursorPosition, state.cursors.items, {}, cursorLessThan);
    return state.cursors.items[state.cursors.items.len - 1];
}

pub fn dedupeSortedCursors(state: *MultiCursorState) void {
    std.mem.sort(CursorPosition, state.cursors.items, {}, cursorLessThan);
    if (state.cursors.items.len <= 1) return;
    var write: usize = 1;
    var read: usize = 1;
    while (read < state.cursors.items.len) : (read += 1) {
        const prev = state.cursors.items[write - 1];
        const current = state.cursors.items[read];
        if (prev.row == current.row and prev.col == current.col) continue;
        state.cursors.items[write] = current;
        write += 1;
    }
    state.cursors.shrinkRetainingCapacity(write);
}

pub fn backspaceAtCursors(state: *MultiCursorState, buf: *buffer_mod.Buffer) !?CursorPosition {
    if (state.hasSelections()) {
        return replaceSelectionsWithText(buf.allocator, state, buf, "");
    }
    if (!state.hasCursors()) return null;

    std.mem.sort(CursorPosition, state.cursors.items, {}, cursorLessThan);
    var precheck_line: ?usize = null;
    var precheck_removed: usize = 0;
    for (state.cursors.items) |cursor| {
        if (cursor.col == 0) return null;
        if (precheck_line == null or precheck_line.? != cursor.row) {
            precheck_line = cursor.row;
            precheck_removed = 0;
        }
        if (cursor.col <= precheck_removed) return null;
        precheck_removed += 1;
    }
    const original_cursors = try buf.allocator.dupe(CursorPosition, state.cursors.items);
    defer buf.allocator.free(original_cursors);

    buf.beginUndoGroup();
    defer buf.endUndoGroup();

    var i = original_cursors.len;
    while (i > 0) {
        i -= 1;
        var cursor = original_cursors[i];
        if (cursor.row >= buf.lines.items.len) continue;
        cursor.col = @min(cursor.col, buf.lines.items[cursor.row].len());
        _ = try buf.deleteCharBack(cursor.row, cursor.col);
    }

    var current_line: ?usize = null;
    var removed_on_line: usize = 0;
    for (original_cursors, 0..) |cursor, index| {
        if (cursor.row >= buf.lines.items.len) continue;
        if (current_line == null or current_line.? != cursor.row) {
            current_line = cursor.row;
            removed_on_line = 0;
        }
        state.cursors.items[index] = .{
            .row = cursor.row,
            .col = @min(cursor.col - 1 - removed_on_line, buf.lines.items[cursor.row].len()),
        };
        removed_on_line += 1;
    }

    std.mem.sort(CursorPosition, state.cursors.items, {}, cursorLessThan);
    return if (state.cursors.items.len > 0) state.cursors.items[state.cursors.items.len - 1] else null;
}

fn findFrom(
    buf: *buffer_mod.Buffer,
    query: []const u8,
    start_row: usize,
    start_col: usize,
    already_selected: []const SelectionRange,
) ?SelectionRange {
    var row = start_row;
    while (row < buf.lines.items.len) : (row += 1) {
        const line = &buf.lines.items[row];
        const line_len = line.len();
        if (query.len > line_len) continue;
        var col: usize = if (row == start_row) start_col else 0;
        while (col + query.len <= line_len) : (col += 1) {
            if (!lineMatches(line, col, query)) continue;
            if (!hasWordBoundaries(line, col, query.len)) continue;
            const range = SelectionRange{
                .start_line = row,
                .start_col = col,
                .end_line = row,
                .end_col = col + query.len,
            };
            if (containsRange(already_selected, range)) continue;
            return range;
        }
    }
    return null;
}

fn lineMatches(line: *const buffer_mod.Line, start_col: usize, query: []const u8) bool {
    for (query, 0..) |expected, offset| {
        if (line.byteAt(start_col + offset) != expected) return false;
    }
    return true;
}

fn hasWordBoundaries(line: *const buffer_mod.Line, start_col: usize, query_len: usize) bool {
    if (start_col > 0) {
        if (line.byteAt(start_col - 1)) |ch| {
            if (buffer_mod.getCharClass(ch) == .Alphanum) return false;
        }
    }
    const end_col = start_col + query_len;
    if (end_col < line.len()) {
        if (line.byteAt(end_col)) |ch| {
            if (buffer_mod.getCharClass(ch) == .Alphanum) return false;
        }
    }
    return true;
}

fn rangesOverlap(lhs: SelectionRange, rhs: SelectionRange) bool {
    if (lhs.end_line < rhs.start_line or rhs.end_line < lhs.start_line) return false;
    if (lhs.start_line == rhs.end_line and lhs.start_col >= rhs.end_col) return false;
    if (rhs.start_line == lhs.end_line and rhs.start_col >= lhs.end_col) return false;
    return true;
}

fn makeBuffer(allocator: std.mem.Allocator, text: []const u8) !buffer_mod.Buffer {
    var buf = try buffer_mod.Buffer.init(allocator);
    errdefer buf.deinit();

    while (buf.lines.items.len > 0) {
        var line = buf.lines.orderedRemove(0);
        line.deinit();
    }

    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line_text| {
        var line = try buffer_mod.Line.fromSlice(allocator, line_text);
        var appended = false;
        errdefer if (!appended) line.deinit();
        try buf.lines.append(allocator, line);
        appended = true;
    }

    if (buf.lines.items.len == 0) {
        var line = try buffer_mod.Line.init(allocator);
        var appended = false;
        errdefer if (!appended) line.deinit();
        try buf.lines.append(allocator, line);
        appended = true;
    }

    return buf;
}

test "findNextWordOccurrence selects exact next occurrence" {
    const allocator = std.testing.allocator;
    var buf = try makeBuffer(allocator, "foo = foo + foo");
    defer buf.deinit();

    const selected = [_]SelectionRange{.{ .start_line = 0, .start_col = 0, .end_line = 0, .end_col = 3 }};
    const next = findNextWordOccurrence(&buf, "foo", .{ .row = 0, .col = 3 }, &selected).?;
    try std.testing.expect(next.eql(.{ .start_line = 0, .start_col = 6, .end_line = 0, .end_col = 9 }));
}

test "repeated selection and wraparound skip duplicates" {
    const allocator = std.testing.allocator;
    var buf = try makeBuffer(allocator, "foo one foo\nfoo");
    defer buf.deinit();
    var state = MultiCursorState{};
    defer state.deinit(allocator);

    try std.testing.expect(try beginSelectNextOccurrence(allocator, &state, &buf, 1, .{ .start_line = 0, .start_col = 0, .end_line = 0, .end_col = 3 }));
    try std.testing.expectEqual(@as(usize, 2), state.selections.items.len);
    try std.testing.expect(try beginSelectNextOccurrence(allocator, &state, &buf, 1, .{ .start_line = 0, .start_col = 0, .end_line = 0, .end_col = 3 }));
    try std.testing.expectEqual(@as(usize, 3), state.selections.items.len);
    try std.testing.expect(!try beginSelectNextOccurrence(allocator, &state, &buf, 1, .{ .start_line = 0, .start_col = 0, .end_line = 0, .end_col = 3 }));
    try std.testing.expectEqual(@as(usize, 3), state.selections.items.len);
}

test "whole-word matching rejects substrings and treats underscore as word" {
    const allocator = std.testing.allocator;
    var buf = try makeBuffer(allocator, "myfoo foo foobar foo_bar foo");
    defer buf.deinit();

    const selected = [_]SelectionRange{.{ .start_line = 0, .start_col = 6, .end_line = 0, .end_col = 9 }};
    const next = findNextWordOccurrence(&buf, "foo", .{ .row = 0, .col = 9 }, &selected).?;
    try std.testing.expect(next.eql(.{ .start_line = 0, .start_col = 25, .end_line = 0, .end_col = 28 }));
}

test "wordSelectionAtCursor selects identifier under or before cursor" {
    const allocator = std.testing.allocator;
    var buf = try makeBuffer(allocator, "foo_bar + baz");
    defer buf.deinit();

    try std.testing.expect((wordSelectionAtCursor(&buf, 0, 1) orelse return error.ExpectedRange).eql(.{
        .start_line = 0,
        .start_col = 0,
        .end_line = 0,
        .end_col = 7,
    }));
    try std.testing.expect((wordSelectionAtCursor(&buf, 0, 7) orelse return error.ExpectedRange).eql(.{
        .start_line = 0,
        .start_col = 0,
        .end_line = 0,
        .end_col = 7,
    }));
    try std.testing.expect(wordSelectionAtCursor(&buf, 0, 9) == null);
}

test "replace selections applies reverse-order same-line edits" {
    const allocator = std.testing.allocator;
    var buf = try makeBuffer(allocator, "foo = foo + foo");
    defer buf.deinit();
    var state = MultiCursorState{ .active = true, .anchor_buffer_id = 1 };
    defer state.deinit(allocator);
    try state.selections.appendSlice(allocator, &.{
        .{ .start_line = 0, .start_col = 0, .end_line = 0, .end_col = 3 },
        .{ .start_line = 0, .start_col = 6, .end_line = 0, .end_col = 9 },
        .{ .start_line = 0, .start_col = 12, .end_line = 0, .end_col = 15 },
    });

    _ = try replaceSelectionsWithText(allocator, &state, &buf, "bar");
    const text = try buf.toOwnedTextSnapshot(allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("bar = bar + bar\n", text);
    try std.testing.expectEqual(@as(usize, 3), state.cursors.items.len);
    try std.testing.expectEqual(@as(usize, 0), state.selections.items.len);
}

test "backspace at cursors applies reverse-order same-line edits" {
    const allocator = std.testing.allocator;
    var buf = try makeBuffer(allocator, "bar = bar + bar");
    defer buf.deinit();
    var state = MultiCursorState{ .active = true, .anchor_buffer_id = 1 };
    defer state.deinit(allocator);
    try state.cursors.appendSlice(allocator, &.{
        .{ .row = 0, .col = 3 },
        .{ .row = 0, .col = 9 },
        .{ .row = 0, .col = 15 },
    });

    _ = try backspaceAtCursors(&state, &buf);
    const text = try buf.toOwnedTextSnapshot(allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("ba = ba + ba\n", text);
    try std.testing.expectEqual(@as(usize, 2), state.cursors.items[0].col);
    try std.testing.expectEqual(@as(usize, 7), state.cursors.items[1].col);
    try std.testing.expectEqual(@as(usize, 12), state.cursors.items[2].col);
}

test "empty and invalid selections are no-ops" {
    const allocator = std.testing.allocator;
    var buf = try makeBuffer(allocator, "foo bar");
    defer buf.deinit();
    var state = MultiCursorState{};
    defer state.deinit(allocator);

    try std.testing.expect(!try beginSelectNextOccurrence(allocator, &state, &buf, 1, .{ .start_line = 0, .start_col = 0, .end_line = 0, .end_col = 0 }));
    try std.testing.expect(!try beginSelectNextOccurrence(allocator, &state, &buf, 1, .{ .start_line = 0, .start_col = 0, .end_line = 0, .end_col = 7 }));
    try std.testing.expectEqual(@as(usize, 0), state.selections.items.len);
}
