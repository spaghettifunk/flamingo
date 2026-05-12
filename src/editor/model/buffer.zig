const std = @import("std");
const logz = @import("logz");

pub const Line = struct {
    buf: []u8,
    gap_start: usize,
    gap_end: usize,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !Line {
        const capacity = 32;
        const buf = try allocator.alloc(u8, capacity);
        return .{
            .buf = buf,
            .gap_start = 0,
            .gap_end = capacity,
            .allocator = allocator,
        };
    }

    pub fn fromSlice(allocator: std.mem.Allocator, data: []const u8) !Line {
        const capacity = data.len + 32;
        var buf = try allocator.alloc(u8, capacity);

        @memcpy(buf[0..data.len], data);

        return .{
            .buf = buf,
            .gap_start = data.len,
            .gap_end = capacity,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Line) void {
        if (self.buf.len > 0) {
            self.allocator.free(self.buf);
            self.buf = &[_]u8{};
        }
    }

    fn gapSize(self: *const Line) usize {
        return self.gap_end - self.gap_start;
    }

    pub fn len(self: *const Line) usize {
        return self.buf.len - self.gapSize();
    }

    pub fn byteAt(self: *const Line, pos: usize) ?u8 {
        if (pos >= self.len()) return null;
        if (pos < self.gap_start) return self.buf[pos];
        return self.buf[self.gap_end + (pos - self.gap_start)];
    }

    fn ensureGap(self: *Line, needed: usize) !void {
        if (self.gapSize() >= needed) return;

        const new_cap = self.buf.len * 2 + needed;
        var new_buf = try self.allocator.alloc(u8, new_cap);

        const left_len = self.gap_start;
        const right_len = self.buf.len - self.gap_end;

        // copy left
        @memcpy(new_buf[0..left_len], self.buf[0..left_len]);

        // copy right
        const new_gap_end = new_cap - right_len;
        @memcpy(
            new_buf[new_gap_end..],
            self.buf[self.gap_end..],
        );

        self.allocator.free(self.buf);
        self.buf = new_buf;
        self.gap_end = new_gap_end;
    }

    pub fn moveGap(self: *Line, pos: usize) void {
        if (pos < self.gap_start) {
            const delta = self.gap_start - pos;
            std.mem.copyBackwards(
                u8,
                self.buf[self.gap_end - delta .. self.gap_end],
                self.buf[pos..self.gap_start],
            );
            self.gap_start -= delta;
            self.gap_end -= delta;
        } else if (pos > self.gap_start) {
            const delta = pos - self.gap_start;
            @memcpy(
                self.buf[self.gap_start .. self.gap_start + delta],
                self.buf[self.gap_end .. self.gap_end + delta],
            );
            self.gap_start += delta;
            self.gap_end += delta;
        }
    }

    pub fn insert(self: *Line, pos: usize, c: u8) !void {
        self.moveGap(pos);
        try self.ensureGap(1);

        self.buf[self.gap_start] = c;
        self.gap_start += 1;
    }

    pub fn deleteBack(self: *Line, pos: usize) bool {
        if (pos == 0) return false;

        self.moveGap(pos);
        self.gap_start -= 1;
        return true;
    }

    pub fn slice(self: *const Line, allocator: std.mem.Allocator) ![]u8 {
        const left_len = self.gap_start;
        const right_len = self.buf.len - self.gap_end;

        var out = try allocator.alloc(u8, left_len + right_len);

        @memcpy(out[0..left_len], self.buf[0..left_len]);
        @memcpy(
            out[left_len .. left_len + right_len],
            self.buf[self.gap_end .. self.gap_end + right_len],
        );

        return out;
    }

    pub fn writeTo(self: *const Line, writer: anytype, max_len: usize) !void {
        const left_len = @min(self.gap_start, max_len);
        try writer.writeAll(self.buf[0..left_len]);

        if (left_len == max_len) return;

        const remaining = max_len - left_len;
        const right_len = @min(self.buf.len - self.gap_end, remaining);

        try writer.writeAll(self.buf[self.gap_end .. self.gap_end + right_len]);
    }

    pub fn appendToList(self: *const Line, allocator: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        try out.appendSlice(allocator, self.buf[0..self.gap_start]);
        try out.appendSlice(allocator, self.buf[self.gap_end..]);
    }

    pub fn writeRange(self: *const Line, writer: anytype, start: usize, max_len: usize) !void {
        const line_len = self.len();
        if (start >= line_len or max_len == 0) return;

        var remaining = @min(max_len, line_len - start);
        var pos = start;
        while (remaining > 0) {
            if (pos < self.gap_start) {
                const end = @min(self.gap_start, pos + remaining);
                try writer.writeAll(self.buf[pos..end]);
                remaining -= end - pos;
                pos = end;
            } else {
                const physical = self.gap_end + (pos - self.gap_start);
                const available = self.buf.len - physical;
                const chunk_len = @min(available, remaining);
                try writer.writeAll(self.buf[physical .. physical + chunk_len]);
                remaining -= chunk_len;
                pos += chunk_len;
            }
        }
    }
};

pub const TextPoint = struct {
    row: usize,
    col: usize,
};

pub const TextEditDelta = struct {
    revision: u64 = 0,
    start_point: TextPoint,
    old_end_point: TextPoint,
    new_end_point: TextPoint,
    start_byte: usize,
    old_end_byte: usize,
    new_end_byte: usize,
};

const max_edit_delta_history = 64;

pub const Buffer = struct {
    lines: std.ArrayList(Line),
    allocator: std.mem.Allocator,
    filename: ?[]const u8 = null,
    is_dirty: bool = false,
    revision: u64 = 0,
    saved_revision: u64 = 0,
    undo_stack: std.ArrayList([]u8) = .empty,
    redo_stack: std.ArrayList([]u8) = .empty,
    undo_group_depth: usize = 0,
    undo_group_recorded: bool = false,
    last_edit_delta: ?TextEditDelta = null,
    edit_delta_history: [max_edit_delta_history]TextEditDelta = undefined,
    edit_delta_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator) !Buffer {
        var lines = std.ArrayList(Line).empty;
        errdefer lines.deinit(allocator);

        var line = try Line.init(allocator);
        errdefer line.deinit();
        try lines.append(allocator, line);

        return .{
            .lines = lines,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Buffer) void {
        for (self.lines.items) |*line| {
            line.deinit();
        }
        self.lines.deinit(self.allocator);
        self.lines = std.ArrayList(Line).empty;

        if (self.filename) |f| {
            self.allocator.free(f);
            self.filename = null;
        }

        self.clearHistoryList(&self.undo_stack);
        self.undo_stack.deinit(self.allocator);
        self.clearHistoryList(&self.redo_stack);
        self.redo_stack.deinit(self.allocator);
    }

    pub fn setFilename(self: *Buffer, filename: []const u8) !void {
        if (self.filename) |old_f| {
            self.allocator.free(old_f);
        }
        self.filename = try self.allocator.dupe(u8, filename);
    }

    pub fn markChanged(self: *Buffer) void {
        self.revision +%= 1;
        self.is_dirty = self.revision != self.saved_revision;
        self.last_edit_delta = null;
        self.edit_delta_count = 0;
    }

    fn markChangedWithDelta(self: *Buffer, delta: TextEditDelta) void {
        self.revision +%= 1;
        self.is_dirty = self.revision != self.saved_revision;
        var stored = delta;
        stored.revision = self.revision;
        self.last_edit_delta = stored;
        self.appendEditDelta(stored);
    }

    pub fn lastEditDelta(self: *const Buffer) ?TextEditDelta {
        return self.last_edit_delta;
    }

    pub fn editDeltasSince(self: *const Buffer, revision: u64) ?[]const TextEditDelta {
        if (revision == self.revision) return self.edit_delta_history[0..0];
        if (self.edit_delta_count == 0) return null;

        const first_revision = revision +% 1;
        var start_index: ?usize = null;
        for (self.edit_delta_history[0..self.edit_delta_count], 0..) |delta, i| {
            if (delta.revision == first_revision) {
                start_index = i;
                break;
            }
        }

        const start = start_index orelse return null;
        var expected = first_revision;
        for (self.edit_delta_history[start..self.edit_delta_count]) |delta| {
            if (delta.revision != expected) return null;
            expected +%= 1;
        }

        if (expected -% 1 != self.revision) return null;
        return self.edit_delta_history[start..self.edit_delta_count];
    }

    fn appendEditDelta(self: *Buffer, delta: TextEditDelta) void {
        if (self.edit_delta_count == max_edit_delta_history) {
            std.mem.copyForwards(
                TextEditDelta,
                self.edit_delta_history[0 .. max_edit_delta_history - 1],
                self.edit_delta_history[1..max_edit_delta_history],
            );
            self.edit_delta_count -= 1;
        }

        self.edit_delta_history[self.edit_delta_count] = delta;
        self.edit_delta_count += 1;
    }

    pub fn byteOffset(self: *const Buffer, row: usize, col: usize) usize {
        var offset: usize = 0;
        var r: usize = 0;
        while (r < row and r < self.lines.items.len) : (r += 1) {
            offset += self.lines.items[r].len() + 1;
        }

        if (row < self.lines.items.len) {
            offset += @min(col, self.lines.items[row].len());
        }
        return offset;
    }

    pub fn beginUndoGroup(self: *Buffer) void {
        if (self.undo_group_depth == 0) {
            self.undo_group_recorded = false;
        }
        self.undo_group_depth += 1;
    }

    pub fn endUndoGroup(self: *Buffer) void {
        if (self.undo_group_depth == 0) return;
        self.undo_group_depth -= 1;
        if (self.undo_group_depth == 0) {
            self.undo_group_recorded = false;
        }
    }

    fn clearHistoryList(self: *Buffer, list: *std.ArrayList([]u8)) void {
        for (list.items) |entry| {
            self.allocator.free(entry);
        }
        list.clearRetainingCapacity();
    }

    fn snapshot(self: *Buffer) ![]u8 {
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(self.allocator);

        for (self.lines.items, 0..) |*line, i| {
            if (i > 0) try out.append(self.allocator, '\n');
            try line.appendToList(self.allocator, &out);
        }

        return out.toOwnedSlice(self.allocator);
    }

    fn restoreSnapshot(self: *Buffer, data: []const u8) !void {
        for (self.lines.items) |*line| {
            line.deinit();
        }
        self.lines.clearRetainingCapacity();

        var it = std.mem.splitScalar(u8, data, '\n');
        while (it.next()) |line_data| {
            var line = try Line.fromSlice(self.allocator, line_data);
            var appended = false;
            errdefer if (!appended) line.deinit();
            try self.lines.append(self.allocator, line);
            appended = true;
        }

        if (self.lines.items.len == 0) {
            var line = try Line.init(self.allocator);
            var appended = false;
            errdefer if (!appended) line.deinit();
            try self.lines.append(self.allocator, line);
            appended = true;
        }
    }

    pub fn recordUndo(self: *Buffer) !void {
        if (self.undo_group_depth > 0 and self.undo_group_recorded) {
            return;
        }

        const before = try self.snapshot();
        errdefer self.allocator.free(before);
        try self.undo_stack.append(self.allocator, before);
        self.clearHistoryList(&self.redo_stack);

        if (self.undo_group_depth > 0) {
            self.undo_group_recorded = true;
        }
    }

    pub fn undo(self: *Buffer) !bool {
        const previous = self.undo_stack.pop() orelse return false;
        defer self.allocator.free(previous);

        const current = try self.snapshot();
        errdefer self.allocator.free(current);
        try self.redo_stack.append(self.allocator, current);

        try self.restoreSnapshot(previous);
        self.markChanged();
        return true;
    }

    pub fn redo(self: *Buffer) !bool {
        const next = self.redo_stack.pop() orelse return false;
        defer self.allocator.free(next);

        const current = try self.snapshot();
        errdefer self.allocator.free(current);
        try self.undo_stack.append(self.allocator, current);

        try self.restoreSnapshot(next);
        self.markChanged();
        return true;
    }

    pub fn markSaved(self: *Buffer) void {
        self.saved_revision = self.revision;
        self.is_dirty = false;
    }

    pub fn insertChar(self: *Buffer, row: usize, col: usize, c: u8) !void {
        if (row >= self.lines.items.len) return;

        try self.recordUndo();
        const bounded_col = @min(col, self.lines.items[row].len());
        const start_byte = self.byteOffset(row, bounded_col);
        const delta = TextEditDelta{
            .start_point = .{ .row = row, .col = bounded_col },
            .old_end_point = .{ .row = row, .col = bounded_col },
            .new_end_point = .{ .row = row, .col = bounded_col + 1 },
            .start_byte = start_byte,
            .old_end_byte = start_byte,
            .new_end_byte = start_byte + 1,
        };
        var line = &self.lines.items[row];
        try line.insert(bounded_col, c);

        self.markChangedWithDelta(delta);
    }

    pub fn insertNewline(self: *Buffer, row: usize, col: usize) !void {
        if (row >= self.lines.items.len) return;

        try self.recordUndo();
        var line = &self.lines.items[row];
        const bounded_col = @min(col, line.len());
        const start_byte = self.byteOffset(row, bounded_col);
        const delta = TextEditDelta{
            .start_point = .{ .row = row, .col = bounded_col },
            .old_end_point = .{ .row = row, .col = bounded_col },
            .new_end_point = .{ .row = row + 1, .col = 0 },
            .start_byte = start_byte,
            .old_end_byte = start_byte,
            .new_end_byte = start_byte + 1,
        };

        // extract right side
        var right = try line.slice(self.allocator);
        defer self.allocator.free(right);

        const split = right[bounded_col..];

        var new_line = try Line.fromSlice(self.allocator, split);
        errdefer new_line.deinit();

        // truncate current line
        line.moveGap(bounded_col);
        line.gap_end = line.buf.len; // drop right side

        try self.lines.insert(self.allocator, row + 1, new_line);
        self.markChangedWithDelta(delta);
    }

    pub fn deleteCharBack(self: *Buffer, row: usize, col: usize) !bool {
        if (row >= self.lines.items.len) return false;

        var line = &self.lines.items[row];

        if (col == 0 and row == 0) return false;
        try self.recordUndo();

        if (line.deleteBack(col)) {
            const start_col = col - 1;
            const start_byte = self.byteOffset(row, start_col);
            self.markChangedWithDelta(.{
                .start_point = .{ .row = row, .col = start_col },
                .old_end_point = .{ .row = row, .col = col },
                .new_end_point = .{ .row = row, .col = start_col },
                .start_byte = start_byte,
                .old_end_byte = start_byte + 1,
                .new_end_byte = start_byte,
            });
            return false;
        }

        // merge with previous
        var prev = &self.lines.items[row - 1];
        const prev_len = prev.len();
        const start_byte = self.byteOffset(row - 1, prev_len);

        const current_data = try line.slice(self.allocator);
        defer self.allocator.free(current_data);

        try prev.ensureGap(current_data.len);
        prev.moveGap(prev.len());

        @memcpy(prev.buf[prev.gap_start .. prev.gap_start + current_data.len], current_data);
        prev.gap_start += current_data.len;

        var removed = self.lines.orderedRemove(row);
        removed.deinit();

        self.markChangedWithDelta(.{
            .start_point = .{ .row = row - 1, .col = prev_len },
            .old_end_point = .{ .row = row, .col = 0 },
            .new_end_point = .{ .row = row - 1, .col = prev_len },
            .start_byte = start_byte,
            .old_end_byte = start_byte + 1,
            .new_end_byte = start_byte,
        });
        return true;
    }

    pub fn saveToFile(self: *Buffer, io: std.Io, filename: []const u8) !void {
        const file = try std.Io.Dir.cwd().createFile(io, filename, .{});
        defer file.close(io);

        for (self.lines.items) |*line| {
            const data = try line.slice(self.allocator);
            defer self.allocator.free(data);

            try file.writeStreamingAll(io, data);
            try file.writeStreamingAll(io, "\n");
        }

        self.markSaved();
    }

    pub fn toOwnedTextSnapshot(self: *const Buffer, allocator: std.mem.Allocator) ![]u8 {
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(allocator);
        for (self.lines.items) |*line| {
            try line.appendToList(allocator, &out);
            try out.append(allocator, '\n');
        }
        return out.toOwnedSlice(allocator);
    }

    pub fn toString(self: *const Buffer, allocator: std.mem.Allocator) ![]u8 {
        return self.toOwnedTextSnapshot(allocator);
    }

    pub fn loadFromFile(allocator: std.mem.Allocator, io: std.Io, filename: []const u8) !Buffer {
        logz.debug().fmt("msg", "loading file: {s}", .{filename}).log();

        const contents = try std.Io.Dir.cwd().readFileAlloc(io, filename, allocator, std.Io.Limit.limited(100 * 1024 * 1024)); // 100MB limit
        defer allocator.free(contents);

        var buf = Buffer{
            .lines = std.ArrayList(Line).empty,
            .allocator = allocator,
            .filename = try allocator.dupe(u8, filename),
            .is_dirty = false,
            .revision = 0,
            .saved_revision = 0,
        };
        errdefer buf.deinit();

        var it = std.mem.splitScalar(u8, contents, '\n');
        while (it.next()) |line| {
            var actual_line = line;
            if (actual_line.len > 0 and actual_line[actual_line.len - 1] == '\r') {
                actual_line = actual_line[0 .. actual_line.len - 1];
            }
            var new_line = try Line.fromSlice(allocator, actual_line);
            var appended = false;
            errdefer if (!appended) new_line.deinit();
            try buf.lines.append(allocator, new_line);
            appended = true;
        }

        if (buf.lines.items.len == 0) {
            var line = try Line.init(allocator);
            var appended = false;
            errdefer if (!appended) line.deinit();
            try buf.lines.append(allocator, line);
            appended = true;
        }

        return buf;
    }

    pub fn jumpWordLeft(self: *Buffer, row: *usize, col: *usize) !void {
        if (col.* == 0) {
            if (row.* > 0) {
                row.* -= 1;
                col.* = self.lines.items[row.*].len();
            }
            return;
        }
        const l = self.lines.items[row.*];
        const line = try l.slice(self.allocator);
        defer self.allocator.free(line);

        // Skip spaces first (moving left)
        while (col.* > 0 and getCharClass(line[col.* - 1]) == .Space) {
            col.* -= 1;
        }

        if (col.* == 0) return;

        const start_class = getCharClass(line[col.* - 1]);
        while (col.* > 0 and getCharClass(line[col.* - 1]) == start_class) {
            col.* -= 1;
        }
    }

    pub fn jumpWordRight(self: *Buffer, row: *usize, col: *usize) !void {
        const l = self.lines.items[row.*];
        const line = try l.slice(self.allocator);
        defer self.allocator.free(line);
        if (col.* >= line.len) {
            if (row.* < self.lines.items.len - 1) {
                row.* += 1;
                col.* = 0;
            }
            return;
        }

        // Skip spaces first
        while (col.* < line.len and getCharClass(line[col.*]) == .Space) {
            col.* += 1;
        }

        if (col.* >= line.len) return;

        const start_class = getCharClass(line[col.*]);
        while (col.* < line.len and getCharClass(line[col.*]) == start_class) {
            col.* += 1;
        }
    }

    pub fn getRange(self: *Buffer, s_row: usize, s_col: usize, e_row: usize, e_col: usize) ![]u8 {
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(self.allocator);

        var r = s_row;
        while (r <= e_row) : (r += 1) {
            const line_slice = try self.lines.items[r].slice(self.allocator);
            defer self.allocator.free(line_slice);

            const start = if (r == s_row) s_col else 0;
            const end = if (r == e_row) e_col else line_slice.len;

            if (start < line_slice.len) {
                try out.appendSlice(self.allocator, line_slice[start..@min(end, line_slice.len)]);
            }
            if (r < e_row) {
                try out.append(self.allocator, '\n');
            }
        }
        return out.toOwnedSlice(self.allocator);
    }

    pub fn deleteRange(self: *Buffer, s_row: usize, s_col: usize, e_row: usize, e_col: usize) !void {
        if (s_row == e_row) {
            if (s_col == e_col) return;
            try self.recordUndo();
            const start_byte = self.byteOffset(s_row, s_col);
            const old_end_byte = self.byteOffset(e_row, e_col);
            var line = &self.lines.items[s_row];
            line.moveGap(e_col);
            const to_del = e_col - s_col;
            line.gap_start -= to_del;
            self.markChangedWithDelta(.{
                .start_point = .{ .row = s_row, .col = s_col },
                .old_end_point = .{ .row = e_row, .col = e_col },
                .new_end_point = .{ .row = s_row, .col = s_col },
                .start_byte = start_byte,
                .old_end_byte = old_end_byte,
                .new_end_byte = start_byte,
            });
            return;
        }

        try self.recordUndo();
        const start_byte = self.byteOffset(s_row, s_col);
        const old_end_byte = self.byteOffset(e_row, e_col);

        // Multiple lines
        const first_line = &self.lines.items[s_row];
        const last_line = &self.lines.items[e_row];

        const last_data = try last_line.slice(self.allocator);
        defer self.allocator.free(last_data);
        const suffix = last_data[e_col..];

        // Truncate first line
        first_line.moveGap(s_col);
        first_line.gap_end = first_line.buf.len;

        // Append suffix of last line to first line
        try first_line.ensureGap(suffix.len);
        @memcpy(first_line.buf[first_line.gap_start .. first_line.gap_start + suffix.len], suffix);
        first_line.gap_start += suffix.len;

        // Remove lines in between
        var i: usize = 0;
        const count = e_row - s_row;
        while (i < count) : (i += 1) {
            var removed = self.lines.orderedRemove(s_row + 1);
            removed.deinit();
        }

        self.markChangedWithDelta(.{
            .start_point = .{ .row = s_row, .col = s_col },
            .old_end_point = .{ .row = e_row, .col = e_col },
            .new_end_point = .{ .row = s_row, .col = s_col },
            .start_byte = start_byte,
            .old_end_byte = old_end_byte,
            .new_end_byte = start_byte,
        });
    }

    pub fn swapLines(self: *Buffer, row1: usize, row2: usize) void {
        if (row1 >= self.lines.items.len or row2 >= self.lines.items.len) return;
        if (row1 == row2) return;
        self.recordUndo() catch return;
        const tmp = self.lines.items[row1];
        self.lines.items[row1] = self.lines.items[row2];
        self.lines.items[row2] = tmp;
        self.markChanged();
    }
};

pub const CharClass = enum { Space, Alphanum, Punctuation };

pub fn getCharClass(c: u8) CharClass {
    if (c == ' ' or c == '\t' or c == '\n' or c == '\r') return .Space;
    if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_') return .Alphanum;
    return .Punctuation;
}

pub fn countDigits(n: usize) usize {
    if (n == 0) return 1;
    var v = n;
    var d: usize = 0;
    while (v > 0) : (v /= 10) d += 1;
    return d;
}

test "Line basic operations" {
    const allocator = std.testing.allocator;
    var line = try Line.init(allocator);
    defer line.deinit();

    try line.insert(0, 'a');
    try line.insert(1, 'b');
    try line.insert(2, 'c');

    const s1 = try line.slice(allocator);
    defer allocator.free(s1);
    try std.testing.expectEqualStrings("abc", s1);

    _ = line.deleteBack(2);
    const s2 = try line.slice(allocator);
    defer allocator.free(s2);
    try std.testing.expectEqualStrings("ac", s2);
}

test "Buffer line merging" {
    const allocator = std.testing.allocator;
    var buf = Buffer{
        .lines = std.ArrayList(Line).empty,
        .allocator = allocator,
    };
    defer buf.deinit();

    try buf.lines.append(allocator, try Line.fromSlice(allocator, "abc"));
    try buf.lines.append(allocator, try Line.fromSlice(allocator, "def"));

    // Delete at (1, 0) should merge "abc" and "def"
    const merged = try buf.deleteCharBack(1, 0);
    try std.testing.expect(merged);
    try std.testing.expectEqual(@as(usize, 1), buf.lines.items.len);

    const s = try buf.lines.items[0].slice(allocator);
    defer allocator.free(s);
    try std.testing.expectEqualStrings("abcdef", s);
}

test "Buffer range deletion" {
    const allocator = std.testing.allocator;
    var buf = Buffer{
        .lines = std.ArrayList(Line).empty,
        .allocator = allocator,
    };
    defer buf.deinit();

    try buf.lines.append(allocator, try Line.fromSlice(allocator, "line 1"));
    try buf.lines.append(allocator, try Line.fromSlice(allocator, "line 2"));
    try buf.lines.append(allocator, try Line.fromSlice(allocator, "line 3"));

    // Delete from (0, 5) to (2, 5):
    // row 0 prefix [0..5] = "line " (5 chars)
    // row 2 suffix [5..]  = "3"
    // merged result        = "line 3"
    try buf.deleteRange(0, 5, 2, 5);
    try std.testing.expectEqual(@as(usize, 1), buf.lines.items.len);

    const s = try buf.lines.items[0].slice(allocator);
    defer allocator.free(s);
    try std.testing.expectEqualStrings("line 3", s);
}

test "Buffer edit deltas track single-line insert and delete" {
    const allocator = std.testing.allocator;
    var buf = try Buffer.init(allocator);
    defer buf.deinit();

    try buf.insertChar(0, 0, 'a');
    const insert_delta = buf.lastEditDelta().?;
    try std.testing.expectEqual(@as(usize, 0), insert_delta.start_byte);
    try std.testing.expectEqual(@as(usize, 0), insert_delta.old_end_byte);
    try std.testing.expectEqual(@as(usize, 1), insert_delta.new_end_byte);
    try std.testing.expectEqual(@as(usize, 0), insert_delta.start_point.row);
    try std.testing.expectEqual(@as(usize, 1), insert_delta.new_end_point.col);

    _ = try buf.deleteCharBack(0, 1);
    const delete_delta = buf.lastEditDelta().?;
    try std.testing.expectEqual(@as(usize, 0), delete_delta.start_byte);
    try std.testing.expectEqual(@as(usize, 1), delete_delta.old_end_byte);
    try std.testing.expectEqual(@as(usize, 0), delete_delta.new_end_byte);
}

test "Buffer edit deltas track newline and multi-line delete" {
    const allocator = std.testing.allocator;
    var buf = try Buffer.init(allocator);
    defer buf.deinit();

    try buf.insertChar(0, 0, 'a');
    try buf.insertNewline(0, 1);
    const newline_delta = buf.lastEditDelta().?;
    try std.testing.expectEqual(@as(usize, 1), newline_delta.start_byte);
    try std.testing.expectEqual(@as(usize, 1), newline_delta.old_end_byte);
    try std.testing.expectEqual(@as(usize, 2), newline_delta.new_end_byte);
    try std.testing.expectEqual(@as(usize, 1), newline_delta.new_end_point.row);
    try std.testing.expectEqual(@as(usize, 0), newline_delta.new_end_point.col);

    try buf.insertChar(1, 0, 'b');
    try buf.deleteRange(0, 1, 1, 0);
    const range_delta = buf.lastEditDelta().?;
    try std.testing.expectEqual(@as(usize, 1), range_delta.start_byte);
    try std.testing.expectEqual(@as(usize, 2), range_delta.old_end_byte);
    try std.testing.expectEqual(@as(usize, 1), range_delta.new_end_byte);
}

test "Buffer edit delta history tracks contiguous edits" {
    const allocator = std.testing.allocator;
    var buf = try Buffer.init(allocator);
    defer buf.deinit();

    const base_revision = buf.revision;
    try buf.insertChar(0, 0, 'a');
    try buf.insertChar(0, 1, 'b');
    try buf.insertChar(0, 2, 'c');

    const deltas = buf.editDeltasSince(base_revision).?;
    try std.testing.expectEqual(@as(usize, 3), deltas.len);
    try std.testing.expectEqual(@as(usize, 1), deltas[0].revision);
    try std.testing.expectEqual(@as(usize, 3), deltas[2].revision);
    try std.testing.expectEqual(@as(usize, 2), deltas[2].start_byte);
    try std.testing.expectEqual(@as(usize, 3), deltas[2].new_end_byte);
}

test "Buffer edit deltas use UTF-8 byte columns" {
    const allocator = std.testing.allocator;
    var buf = try Buffer.init(allocator);
    defer buf.deinit();

    try buf.insertChar(0, 0, 0xc3);
    try buf.insertChar(0, 1, 0xa9);
    try buf.insertChar(0, 2, 'x');

    const delta = buf.lastEditDelta().?;
    try std.testing.expectEqual(@as(usize, 2), delta.start_byte);
    try std.testing.expectEqual(@as(usize, 2), delta.start_point.col);
    try std.testing.expectEqual(@as(usize, 3), delta.new_end_byte);
    try std.testing.expectEqual(@as(usize, 3), delta.new_end_point.col);
}

test "Buffer undo group records one snapshot" {
    const allocator = std.testing.allocator;
    var buf = try Buffer.init(allocator);
    defer buf.deinit();

    buf.beginUndoGroup();
    try buf.insertChar(0, 0, 'a');
    try buf.insertChar(0, 1, 'b');
    try buf.insertChar(0, 2, 'c');
    buf.endUndoGroup();

    try std.testing.expectEqual(@as(usize, 1), buf.undo_stack.items.len);
    try std.testing.expect(try buf.undo());
    const s = try buf.lines.items[0].slice(allocator);
    defer allocator.free(s);
    try std.testing.expectEqualStrings("", s);
}

test "Buffer word jumps" {
    const allocator = std.testing.allocator;
    var buf = Buffer{
        .lines = std.ArrayList(Line).empty,
        .allocator = allocator,
    };
    defer {
        for (buf.lines.items) |*l| l.deinit();
        buf.lines.deinit(allocator);
    }

    try buf.lines.append(allocator, try Line.fromSlice(allocator, "hello world flamingo"));

    var row: usize = 0;
    var col: usize = 0;

    try buf.jumpWordRight(&row, &col);
    try std.testing.expectEqual(@as(usize, 5), col); // after "hello"

    try buf.jumpWordRight(&row, &col);
    try std.testing.expectEqual(@as(usize, 11), col); // after " world"

    try buf.jumpWordLeft(&row, &col);
    try std.testing.expectEqual(@as(usize, 6), col); // start of "world"
}

test "Buffer text snapshot preserves trailing newline contract" {
    const allocator = std.testing.allocator;
    var buf = try Buffer.init(allocator);
    defer buf.deinit();

    const empty = try buf.toOwnedTextSnapshot(allocator);
    defer allocator.free(empty);
    try std.testing.expectEqualStrings("\n", empty);

    try buf.insertChar(0, 0, 'a');
    try buf.insertNewline(0, 1);
    try buf.insertChar(1, 0, 'b');

    const snapshot = try buf.toOwnedTextSnapshot(allocator);
    defer allocator.free(snapshot);
    try std.testing.expectEqualStrings("a\nb\n", snapshot);
}

test "Buffer snapshots append line gap segments without temporary line copies" {
    const allocator = std.testing.allocator;
    var buf = try Buffer.init(allocator);
    defer buf.deinit();

    try buf.insertChar(0, 0, 'a');
    try buf.insertChar(0, 1, 'c');
    try buf.insertChar(0, 1, 'b');

    const undo_snapshot = try buf.snapshot();
    defer allocator.free(undo_snapshot);
    try std.testing.expectEqualStrings("abc", undo_snapshot);

    const text_snapshot = try buf.toOwnedTextSnapshot(allocator);
    defer allocator.free(text_snapshot);
    try std.testing.expectEqualStrings("abc\n", text_snapshot);
}
