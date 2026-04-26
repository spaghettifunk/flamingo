const std = @import("std");

pub const Buffer = struct {
    lines: std.ArrayList(std.ArrayList(u8)),
    allocator: std.mem.Allocator,
    filename: ?[]const u8 = null,
    is_dirty: bool = false,

    pub fn init(allocator: std.mem.Allocator) !Buffer {
        var lines = std.ArrayList(std.ArrayList(u8)).empty;
        try lines.append(allocator, std.ArrayList(u8).empty); // At least one empty line
        return Buffer{
            .lines = lines,
            .allocator = allocator,
            .filename = null,
            .is_dirty = false,
        };
    }

    pub fn deinit(self: *Buffer) void {
        for (self.lines.items) |*line| {
            line.deinit(self.allocator);
        }
        self.lines.deinit(self.allocator);
    }

    pub fn insertChar(self: *Buffer, row: usize, col: usize, c: u8) !void {
        if (row >= self.lines.items.len) return;
        var line = &self.lines.items[row];
        if (col > line.items.len) {
            try line.append(self.allocator, c);
        } else {
            try line.insert(self.allocator, col, c);
        }
        self.is_dirty = true;
    }

    pub fn insertNewline(self: *Buffer, row: usize, col: usize) !void {
        if (row >= self.lines.items.len) return;
        var line = &self.lines.items[row];
        
        var new_line = std.ArrayList(u8).empty;
        if (col < line.items.len) {
            try new_line.appendSlice(self.allocator, line.items[col..]);
            line.shrinkAndFree(self.allocator, col);
        }
        
        try self.lines.insert(self.allocator, row + 1, new_line);
        self.is_dirty = true;
    }

    pub fn deleteCharBack(self: *Buffer, row: usize, col: usize) !bool {
        if (row >= self.lines.items.len) return false;
        var line = &self.lines.items[row];

        if (col > 0) {
            _ = line.orderedRemove(col - 1);
            self.is_dirty = true;
            return false; // Did not merge lines
        } else if (row > 0) {
            // Merge with previous line
            var prev_line = &self.lines.items[row - 1];
            try prev_line.appendSlice(self.allocator, line.items);
            
            var removed_line = self.lines.orderedRemove(row);
            removed_line.deinit(self.allocator);
            self.is_dirty = true;
            return true; // Merged lines
        }
        return false;
    }

    pub fn saveToFile(self: *Buffer, filename: []const u8) !void {
        const file = try std.fs.cwd().createFile(filename, .{});
        defer file.close();
        for (self.lines.items) |line| {
            try file.writeAll(line.items);
            try file.writeAll("\n");
        }
        self.is_dirty = false;
    }

    pub fn loadFromFile(allocator: std.mem.Allocator, filename: []const u8) !Buffer {
        const file = try std.fs.cwd().openFile(filename, .{});
        defer file.close();
        
        const contents = try file.readToEndAlloc(allocator, 100 * 1024 * 1024); // 100MB limit
        defer allocator.free(contents);
        
        var buf = try Buffer.init(allocator);
        // Clear initial line
        buf.lines.items[0].deinit(allocator);
        buf.lines.clearRetainingCapacity();
        
        var it = std.mem.splitScalar(u8, contents, '\n');
        while (it.next()) |line| {
            var actual_line = line;
            if (actual_line.len > 0 and actual_line[actual_line.len - 1] == '\r') {
                actual_line = actual_line[0 .. actual_line.len - 1];
            }
            var new_line = std.ArrayList(u8).empty;
            try new_line.appendSlice(allocator, actual_line);
            try buf.lines.append(allocator, new_line);
        }
        
        // If file is completely empty, ensure we have at least one empty line
        if (buf.lines.items.len == 0) {
            try buf.lines.append(allocator, std.ArrayList(u8).empty);
        }
        
        buf.filename = try allocator.dupe(u8, filename);
        buf.is_dirty = false;
        
        return buf;
    }
};
