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
};

pub const Buffer = struct {
    lines: std.ArrayList(Line),
    allocator: std.mem.Allocator,
    filename: ?[]const u8 = null,
    is_dirty: bool = false,

    pub fn init(allocator: std.mem.Allocator) !Buffer {
        var lines = std.ArrayList(Line).empty;
        try lines.append(allocator, try Line.init(allocator));

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
    }

    pub fn setFilename(self: *Buffer, filename: []const u8) !void {
        if (self.filename) |old_f| {
            self.allocator.free(old_f);
        }
        self.filename = try self.allocator.dupe(u8, filename);
    }

    pub fn insertChar(self: *Buffer, row: usize, col: usize, c: u8) !void {
        if (row >= self.lines.items.len) return;

        var line = &self.lines.items[row];
        try line.insert(col, c);

        self.is_dirty = true;
    }

    pub fn insertNewline(self: *Buffer, row: usize, col: usize) !void {
        if (row >= self.lines.items.len) return;

        var line = &self.lines.items[row];

        // extract right side
        var right = try line.slice(self.allocator);
        defer self.allocator.free(right);

        const split = right[col..];

        const new_line = try Line.fromSlice(self.allocator, split);

        // truncate current line
        line.moveGap(col);
        line.gap_end = line.buf.len; // drop right side

        try self.lines.insert(self.allocator, row + 1, new_line);
        self.is_dirty = true;
    }

    pub fn deleteCharBack(self: *Buffer, row: usize, col: usize) !bool {
        if (row >= self.lines.items.len) return false;

        var line = &self.lines.items[row];

        if (line.deleteBack(col)) {
            self.is_dirty = true;
            return false;
        }

        if (row == 0) return false;

        // merge with previous
        var prev = &self.lines.items[row - 1];

        const current_data = try line.slice(self.allocator);
        defer self.allocator.free(current_data);

        try prev.ensureGap(current_data.len);
        prev.moveGap(prev.len());

        @memcpy(prev.buf[prev.gap_start .. prev.gap_start + current_data.len], current_data);
        prev.gap_start += current_data.len;

        var removed = self.lines.orderedRemove(row);
        removed.deinit();

        self.is_dirty = true;
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

        self.is_dirty = false;
    }

    pub fn toString(self: *const Buffer, allocator: std.mem.Allocator) ![]u8 {
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(allocator);
        for (self.lines.items) |*line| {
            const data = try line.slice(allocator);
            defer allocator.free(data);
            try out.appendSlice(allocator, data);
            try out.append(allocator, '\n');
        }
        return out.toOwnedSlice(allocator);
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
        };
        errdefer buf.deinit();

        var it = std.mem.splitScalar(u8, contents, '\n');
        while (it.next()) |line| {
            var actual_line = line;
            if (actual_line.len > 0 and actual_line[actual_line.len - 1] == '\r') {
                actual_line = actual_line[0 .. actual_line.len - 1];
            }
            const new_line = try Line.fromSlice(allocator, actual_line);
            try buf.lines.append(allocator, new_line);
        }

        if (buf.lines.items.len == 0) {
            try buf.lines.append(allocator, try Line.init(allocator));
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
            var line = &self.lines.items[s_row];
            line.moveGap(e_col);
            const to_del = e_col - s_col;
            line.gap_start -= to_del;
            self.is_dirty = true;
            return;
        }

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

        self.is_dirty = true;
    }

    pub fn swapLines(self: *Buffer, row1: usize, row2: usize) void {
        if (row1 >= self.lines.items.len or row2 >= self.lines.items.len) return;
        const tmp = self.lines.items[row1];
        self.lines.items[row1] = self.lines.items[row2];
        self.lines.items[row2] = tmp;
        self.is_dirty = true;
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
    defer {
        for (buf.lines.items) |*l| l.deinit();
        buf.lines.deinit(allocator);
    }

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
    defer {
        for (buf.lines.items) |*l| l.deinit();
        buf.lines.deinit(allocator);
    }

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
