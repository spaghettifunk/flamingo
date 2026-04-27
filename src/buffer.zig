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

        @memcpy(prev.buf[prev.gap_start..], current_data);
        prev.gap_start += current_data.len;

        var removed = self.lines.orderedRemove(row);
        removed.deinit();

        self.is_dirty = true;
        return true;
    }

    pub fn saveToFile(self: *Buffer, filename: []const u8) !void {
        const file = try std.fs.cwd().createFile(filename, .{});
        defer file.close();

        for (self.lines.items) |*line| {
            const data = try line.slice(self.allocator);
            defer self.allocator.free(data);

            try file.writeAll(data);
            try file.writeAll("\n");
        }

        self.is_dirty = false;
    }

    pub fn loadFromFile(allocator: std.mem.Allocator, filename: []const u8) !Buffer {
        logz.debug().fmt("msg", "loading file: {s}", .{filename}).log();
        const file = try std.fs.cwd().openFile(filename, .{});
        defer file.close();

        const contents = try file.readToEndAlloc(allocator, 100 * 1024 * 1024); // 100MB limit
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
};
