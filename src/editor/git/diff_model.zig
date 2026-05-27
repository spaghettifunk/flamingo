const std = @import("std");

pub const LineChangeKind = enum {
    added,
    modified,
    deleted,
};

pub const LineChange = struct {
    /// 0-based line index in the current working tree buffer.
    line: usize,
    kind: LineChangeKind,
    /// For deleted lines, the number of removed old-file lines represented at
    /// this current-file boundary marker.
    deleted_count: usize = 0,
};

pub const RefreshStatus = enum {
    disabled,
    clean,
    changed,
    untracked,
    outside_repository,
    git_unavailable,
    command_failed,
    output_too_large,
};

pub const FileDiff = struct {
    /// Owned absolute path.
    path: []u8,
    /// Owned sorted line changes.
    changes: []LineChange,
    status: RefreshStatus = .changed,

    pub fn deinit(self: *FileDiff, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.changes);
        self.* = undefined;
    }

    pub fn lineChange(self: *const FileDiff, line: usize) ?LineChange {
        var lo: usize = 0;
        var hi: usize = self.changes.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const mid_line = self.changes[mid].line;
            if (mid_line == line) return self.changes[mid];
            if (mid_line < line) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        return null;
    }
};

pub fn sortChanges(changes: []LineChange) void {
    std.mem.sort(LineChange, changes, {}, struct {
        fn lessThan(_: void, lhs: LineChange, rhs: LineChange) bool {
            if (lhs.line != rhs.line) return lhs.line < rhs.line;
            return priority(lhs.kind) < priority(rhs.kind);
        }

        fn priority(kind: LineChangeKind) u8 {
            return switch (kind) {
                .deleted => 0,
                .modified => 1,
                .added => 2,
            };
        }
    }.lessThan);
}

pub fn allAdded(allocator: std.mem.Allocator, path: []const u8, line_count: usize) !FileDiff {
    const changes = try allocator.alloc(LineChange, line_count);
    errdefer allocator.free(changes);
    for (changes, 0..) |*change, line| {
        change.* = .{ .line = line, .kind = .added };
    }
    return .{
        .path = try allocator.dupe(u8, path),
        .changes = changes,
        .status = .untracked,
    };
}

test "file diff lookup finds sorted changes" {
    const allocator = std.testing.allocator;
    const changes = try allocator.dupe(LineChange, &.{
        .{ .line = 4, .kind = .added },
        .{ .line = 1, .kind = .modified },
        .{ .line = 7, .kind = .deleted, .deleted_count = 2 },
    });
    sortChanges(changes);
    var diff = FileDiff{
        .path = try allocator.dupe(u8, "/repo/file.zig"),
        .changes = changes,
    };
    defer diff.deinit(allocator);

    try std.testing.expectEqual(LineChangeKind.modified, diff.lineChange(1).?.kind);
    try std.testing.expect(diff.lineChange(2) == null);
    try std.testing.expectEqual(@as(usize, 2), diff.lineChange(7).?.deleted_count);
}

test "allAdded creates one marker per buffer line" {
    const allocator = std.testing.allocator;
    var diff = try allAdded(allocator, "/repo/new.zig", 3);
    defer diff.deinit(allocator);

    try std.testing.expectEqual(RefreshStatus.untracked, diff.status);
    try std.testing.expectEqual(@as(usize, 3), diff.changes.len);
    try std.testing.expectEqual(LineChangeKind.added, diff.lineChange(2).?.kind);
}
