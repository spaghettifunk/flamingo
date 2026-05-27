const std = @import("std");
const diff_model = @import("diff_model.zig");

const LineChange = diff_model.LineChange;
const LineChangeKind = diff_model.LineChangeKind;

const HunkHeader = struct {
    old_start: usize,
    old_count: usize,
    new_start: usize,
    new_count: usize,
};

fn parseRange(range: []const u8) !struct { start: usize, count: usize } {
    if (range.len < 2) return error.InvalidHunkHeader;
    const body = range[1..];
    if (std.mem.indexOfScalar(u8, body, ',')) |comma| {
        return .{
            .start = try std.fmt.parseInt(usize, body[0..comma], 10),
            .count = try std.fmt.parseInt(usize, body[comma + 1 ..], 10),
        };
    }
    return .{
        .start = try std.fmt.parseInt(usize, body, 10),
        .count = 1,
    };
}

fn parseHunkHeader(line: []const u8) !HunkHeader {
    if (!std.mem.startsWith(u8, line, "@@ ")) return error.InvalidHunkHeader;
    const close = std.mem.indexOfPos(u8, line, 3, " @@") orelse return error.InvalidHunkHeader;
    var parts = std.mem.splitScalar(u8, line[3..close], ' ');
    const old_range = parts.next() orelse return error.InvalidHunkHeader;
    const new_range = parts.next() orelse return error.InvalidHunkHeader;
    const old = try parseRange(old_range);
    const new = try parseRange(new_range);
    return .{
        .old_start = old.start,
        .old_count = old.count,
        .new_start = new.start,
        .new_count = new.count,
    };
}

fn appendDeletionBoundary(changes: *std.ArrayListUnmanaged(LineChange), allocator: std.mem.Allocator, header: HunkHeader, deleted_count: usize, line_override: ?usize) !void {
    if (deleted_count == 0) return;
    const line = line_override orelse if (header.new_count > 0)
        header.new_start -| 1
    else if (header.new_start == 0)
        0
    else
        header.new_start - 1;
    try changes.append(allocator, .{
        .line = line,
        .kind = .deleted,
        .deleted_count = deleted_count,
    });
}

fn flushHunk(
    changes: *std.ArrayListUnmanaged(LineChange),
    allocator: std.mem.Allocator,
    header: HunkHeader,
    removed_count: usize,
    added_count: usize,
) !void {
    const paired = @min(removed_count, added_count);
    const new_base = header.new_start -| 1;

    for (0..paired) |i| {
        try changes.append(allocator, .{ .line = new_base + i, .kind = .modified });
    }
    for (paired..added_count) |i| {
        try changes.append(allocator, .{ .line = new_base + i, .kind = .added });
    }
    const deletion_boundary = if (paired > 0) new_base + paired else null;
    try appendDeletionBoundary(changes, allocator, header, removed_count - paired, deletion_boundary);
}

/// Parses `git diff --unified=0` output into current-buffer line changes.
/// Deletions attach to the nearest current-file boundary: the next current
/// line when one exists, otherwise the previous existing line.
pub fn parse(allocator: std.mem.Allocator, patch: []const u8) ![]LineChange {
    var changes = std.ArrayListUnmanaged(LineChange).empty;
    errdefer changes.deinit(allocator);

    var current_header: ?HunkHeader = null;
    var removed_count: usize = 0;
    var added_count: usize = 0;

    var it = std.mem.splitScalar(u8, patch, '\n');
    while (it.next()) |raw_line| {
        var line = raw_line;
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];

        if (std.mem.startsWith(u8, line, "@@ ")) {
            if (current_header) |header| {
                try flushHunk(&changes, allocator, header, removed_count, added_count);
            }
            current_header = try parseHunkHeader(line);
            removed_count = 0;
            added_count = 0;
            continue;
        }

        if (current_header == null) continue;
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "--- ") or std.mem.startsWith(u8, line, "+++ ")) continue;

        switch (line[0]) {
            '-' => removed_count += 1,
            '+' => added_count += 1,
            else => {},
        }
    }

    if (current_header) |header| {
        try flushHunk(&changes, allocator, header, removed_count, added_count);
    }

    const owned = try changes.toOwnedSlice(allocator);
    diff_model.sortChanges(owned);
    return owned;
}

test "parser handles pure addition" {
    const allocator = std.testing.allocator;
    const changes = try parse(allocator, "@@ -0,0 +1,2 @@\n+one\n+two\n");
    defer allocator.free(changes);

    try std.testing.expectEqual(@as(usize, 2), changes.len);
    try std.testing.expectEqual(LineChangeKind.added, changes[0].kind);
    try std.testing.expectEqual(@as(usize, 0), changes[0].line);
    try std.testing.expectEqual(@as(usize, 1), changes[1].line);
}

test "parser handles pure deletion" {
    const allocator = std.testing.allocator;
    const changes = try parse(allocator, "@@ -3,2 +3,0 @@\n-old\n-lines\n");
    defer allocator.free(changes);

    try std.testing.expectEqual(@as(usize, 1), changes.len);
    try std.testing.expectEqual(LineChangeKind.deleted, changes[0].kind);
    try std.testing.expectEqual(@as(usize, 2), changes[0].line);
    try std.testing.expectEqual(@as(usize, 2), changes[0].deleted_count);
}

test "parser handles one-line modification" {
    const allocator = std.testing.allocator;
    const changes = try parse(allocator, "@@ -10 +10 @@\n-old\n+new\n");
    defer allocator.free(changes);

    try std.testing.expectEqual(@as(usize, 1), changes.len);
    try std.testing.expectEqual(LineChangeKind.modified, changes[0].kind);
    try std.testing.expectEqual(@as(usize, 9), changes[0].line);
}

test "parser handles unequal multi-line replacement" {
    const allocator = std.testing.allocator;
    const changes = try parse(allocator, "@@ -4,3 +4,2 @@\n-a\n-b\n-c\n+x\n+y\n");
    defer allocator.free(changes);

    try std.testing.expectEqual(@as(usize, 3), changes.len);
    try std.testing.expectEqual(LineChangeKind.modified, changes[0].kind);
    try std.testing.expectEqual(LineChangeKind.modified, changes[1].kind);
    try std.testing.expectEqual(LineChangeKind.deleted, changes[2].kind);
    try std.testing.expectEqual(@as(usize, 5), changes[2].line);
    try std.testing.expectEqual(@as(usize, 1), changes[2].deleted_count);
}

test "parser handles multiple hunks" {
    const allocator = std.testing.allocator;
    const changes = try parse(allocator, "@@ -1 +1 @@\n-a\n+b\n@@ -5,0 +6 @@\n+new\n");
    defer allocator.free(changes);

    try std.testing.expectEqual(@as(usize, 2), changes.len);
    try std.testing.expectEqual(LineChangeKind.modified, changes[0].kind);
    try std.testing.expectEqual(LineChangeKind.added, changes[1].kind);
    try std.testing.expectEqual(@as(usize, 5), changes[1].line);
}

test "parser handles empty patch" {
    const allocator = std.testing.allocator;
    const changes = try parse(allocator, "");
    defer allocator.free(changes);
    try std.testing.expectEqual(@as(usize, 0), changes.len);
}

test "parser ignores file headers with spaces in paths" {
    const allocator = std.testing.allocator;
    const changes = try parse(allocator, "diff --git a/file with spaces.zig b/file with spaces.zig\n--- a/file with spaces.zig\n+++ b/file with spaces.zig\n@@ -2 +2 @@\n-old\n+new\n");
    defer allocator.free(changes);

    try std.testing.expectEqual(@as(usize, 1), changes.len);
    try std.testing.expectEqual(LineChangeKind.modified, changes[0].kind);
    try std.testing.expectEqual(@as(usize, 1), changes[0].line);
}
