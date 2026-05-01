const std = @import("std");
const editor = @import("editor.zig");
const buffer = @import("buffer.zig");

pub const Match = struct {
    row: usize,
    col: usize,
    indices: []const usize,

    pub fn deinit(self: *Match, allocator: std.mem.Allocator) void {
        if (self.indices.len > 0) {
            allocator.free(self.indices);
            self.indices = &[_]usize{};
        }
    }
};

pub const SearchSystem = struct {
    allocator: std.mem.Allocator,
    matches: std.ArrayListUnmanaged(Match) = .empty,
    active_match_idx: ?usize = null,

    pub fn init(allocator: std.mem.Allocator) SearchSystem {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SearchSystem) void {
        for (self.matches.items) |*m| {
            m.deinit(self.allocator);
        }
        self.matches.deinit(self.allocator);
        self.matches = .empty;
        self.active_match_idx = null;
    }

    pub fn clear(self: *SearchSystem) void {
        for (self.matches.items) |*m| {
            m.deinit(self.allocator);
        }
        self.matches.clearRetainingCapacity();
        self.active_match_idx = null;
    }

    pub fn update(self: *SearchSystem, buf: *const buffer.Buffer, query: []const u8) !void {
        self.clear();
        if (query.len == 0) return;

        for (buf.lines.items, 0..) |*line, row_idx| {
            // Need a flat slice of the line to search
            const line_content = try line.slice(self.allocator);
            defer self.allocator.free(line_content);

            if (try strictMatch(line_content, query, self.allocator)) |indices| {
                errdefer self.allocator.free(indices);
                try self.matches.append(self.allocator, .{
                    .row = row_idx,
                    .col = indices[0],
                    .indices = indices,
                });
            }
        }

        if (self.matches.items.len > 0) {
            self.active_match_idx = 0;
        }
    }

    pub fn nextMatch(self: *SearchSystem) void {
        if (self.matches.items.len == 0) return;
        if (self.active_match_idx) |idx| {
            self.active_match_idx = (idx + 1) % self.matches.items.len;
        } else {
            self.active_match_idx = 0;
        }
    }

    pub fn prevMatch(self: *SearchSystem) void {
        if (self.matches.items.len == 0) return;
        if (self.active_match_idx) |idx| {
            if (idx == 0) {
                self.active_match_idx = self.matches.items.len - 1;
            } else {
                self.active_match_idx = idx - 1;
            }
        } else {
            self.active_match_idx = self.matches.items.len - 1;
        }
    }

    pub fn getActiveMatch(self: *const SearchSystem) ?Match {
        const idx = self.active_match_idx orelse return null;
        return self.matches.items[idx];
    }

    pub fn matchForRow(self: *const SearchSystem, row: usize) ?Match {
        for (self.matches.items) |m| {
            if (m.row == row) return m;
            if (m.row > row) break;
        }
        return null;
    }

    pub fn activeMatchRow(self: *const SearchSystem) ?usize {
        const active = self.getActiveMatch() orelse return null;
        return active.row;
    }
};

pub fn strictMatch(line: []const u8, query: []const u8, allocator: std.mem.Allocator) !?[]const usize {
    if (query.len == 0 or line.len < query.len) return null;

    var i: usize = 0;
    while (i <= line.len - query.len) : (i += 1) {
        var match = true;
        for (query, 0..) |q_char, j| {
            if (std.ascii.toLower(line[i + j]) != std.ascii.toLower(q_char)) {
                match = false;
                break;
            }
        }

        if (match) {
            var indices = try std.ArrayList(usize).initCapacity(allocator, query.len);
            errdefer indices.deinit(allocator);
            for (0..query.len) |j| {
                try indices.append(allocator, i + j);
            }
            return try indices.toOwnedSlice(allocator);
        }
    }
    return null;
}

test "strictMatch" {
    const allocator = std.testing.allocator;

    const m1 = try strictMatch("flamingo", "fla", allocator);
    try std.testing.expect(m1 != null);
    try std.testing.expectEqualSlices(usize, &[_]usize{ 0, 1, 2 }, m1.?);
    allocator.free(m1.?);

    const m2 = try strictMatch("flamingo", "flz", allocator);
    try std.testing.expect(m2 == null);

    const m3 = try strictMatch("Flamingo", "FLA", allocator);
    try std.testing.expect(m3 != null);
    try std.testing.expectEqualSlices(usize, &[_]usize{ 0, 1, 2 }, m3.?);
    allocator.free(m3.?);
}
