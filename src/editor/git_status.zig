const std = @import("std");

pub const FileState = enum {
    modified,
    untracked,
    ignored,
};

pub const Snapshot = struct {
    allocator: std.mem.Allocator,
    root_path: ?[]u8 = null,
    branch: ?[]u8 = null,
    entries: std.StringHashMap(FileState),

    pub fn init(allocator: std.mem.Allocator) Snapshot {
        return .{
            .allocator = allocator,
            .entries = std.StringHashMap(FileState).init(allocator),
        };
    }

    pub fn deinit(self: *Snapshot) void {
        if (self.root_path) |root| {
            self.allocator.free(root);
            self.root_path = null;
        }
        if (self.branch) |branch| {
            self.allocator.free(branch);
            self.branch = null;
        }
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.entries.deinit();
        self.entries = std.StringHashMap(FileState).init(self.allocator);
    }

    pub fn put(self: *Snapshot, path: []const u8, state: FileState) !void {
        var normalized = path;
        while (std.mem.startsWith(u8, normalized, "./")) normalized = normalized[2..];
        while (normalized.len > 0 and normalized[normalized.len - 1] == '/') normalized = normalized[0 .. normalized.len - 1];
        if (normalized.len == 0) return;

        const owned = try self.allocator.dupe(u8, normalized);
        var key_owned = true;
        errdefer if (key_owned) self.allocator.free(owned);

        const entry = try self.entries.getOrPut(owned);
        if (entry.found_existing) {
            self.allocator.free(owned);
            key_owned = false;
        } else {
            key_owned = false;
        }
        entry.value_ptr.* = if (entry.found_existing) mergeState(entry.value_ptr.*, state) else state;
    }

    pub fn eql(self: *const Snapshot, other: *const Snapshot) bool {
        if (!optionalBytesEql(self.root_path, other.root_path)) return false;
        if (!optionalBytesEql(self.branch, other.branch)) return false;
        if (self.entries.count() != other.entries.count()) return false;

        var it = self.entries.iterator();
        while (it.next()) |entry| {
            const other_state = other.entries.get(entry.key_ptr.*) orelse return false;
            if (other_state != entry.value_ptr.*) return false;
        }
        return true;
    }

    pub fn stateForPath(self: *const Snapshot, path: []const u8) ?FileState {
        if (self.entries.count() == 0) return null;
        var rel = path;

        if (self.root_path) |root| {
            if (std.mem.startsWith(u8, rel, root)) {
                rel = rel[root.len..];
                if (rel.len > 0 and (rel[0] == '/' or rel[0] == std.fs.path.sep)) rel = rel[1..];
            }
        }

        while (std.mem.startsWith(u8, rel, "./")) rel = rel[2..];
        while (rel.len > 0 and rel[0] == '/') rel = rel[1..];
        while (rel.len > 0 and rel[rel.len - 1] == '/') rel = rel[0 .. rel.len - 1];

        if (self.entries.get(rel)) |state| return state;

        // Directories sometimes need to inherit from a tracked descendant.
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            if (std.mem.startsWith(u8, entry.key_ptr.*, rel) and
                entry.key_ptr.*.len > rel.len and
                entry.key_ptr.*[rel.len] == '/')
            {
                return entry.value_ptr.*;
            }
        }
        return null;
    }

    pub fn load(allocator: std.mem.Allocator, io: std.Io) !Snapshot {
        var snapshot = Snapshot.init(allocator);
        errdefer snapshot.deinit();

        const root_result = std.process.run(allocator, io, .{
            .argv = &.{ "git", "rev-parse", "--show-toplevel" },
            .stdout_limit = std.Io.Limit.limited(16 * 1024),
            .stderr_limit = std.Io.Limit.limited(16 * 1024),
        }) catch return snapshot;
        defer allocator.free(root_result.stdout);
        defer allocator.free(root_result.stderr);
        switch (root_result.term) {
            .exited => |code| if (code != 0) return snapshot,
            else => return snapshot,
        }

        const root = std.mem.trim(u8, root_result.stdout, " \t\r\n");
        if (root.len == 0) return snapshot;
        snapshot.root_path = try allocator.dupe(u8, root);

        const status_result = std.process.run(allocator, io, .{
            .argv = &.{ "git", "-C", root, "status", "--porcelain=v1", "--ignored=matching", "--branch", "-z" },
            .stdout_limit = std.Io.Limit.limited(256 * 1024),
            .stderr_limit = std.Io.Limit.limited(16 * 1024),
        }) catch return snapshot;
        defer allocator.free(status_result.stdout);
        defer allocator.free(status_result.stderr);
        switch (status_result.term) {
            .exited => |code| if (code != 0) return snapshot,
            else => return snapshot,
        }

        try parsePorcelain(&snapshot, status_result.stdout);
        return snapshot;
    }
};

fn optionalBytesEql(lhs: ?[]const u8, rhs: ?[]const u8) bool {
    if (lhs == null or rhs == null) return lhs == null and rhs == null;
    return std.mem.eql(u8, lhs.?, rhs.?);
}

fn mergeState(old: FileState, new: FileState) FileState {
    if (old == .modified or new == .modified) return .modified;
    if (old == .untracked or new == .untracked) return .untracked;
    return .ignored;
}

fn stateFromStatus(status: []const u8) ?FileState {
    if (status.len < 2) return null;
    if (status[0] == '!' and status[1] == '!') return .ignored;
    if (status[0] == '?' and status[1] == '?') return .untracked;
    if (status[0] != ' ' or status[1] != ' ') return .modified;
    return null;
}

pub fn parsePorcelain(snapshot: *Snapshot, output: []const u8) !void {
    var it = std.mem.splitScalar(u8, output, 0);
    while (it.next()) |entry| {
        if (entry.len == 0) continue;
        if (std.mem.startsWith(u8, entry, "## ")) {
            const branch_part = entry[3..];
            var end = branch_part.len;
            if (std.mem.indexOf(u8, branch_part, "...")) |idx| end = idx;
            if (std.mem.indexOfScalar(u8, branch_part[0..end], ' ')) |idx| end = idx;
            if (end > 0 and snapshot.branch == null) {
                snapshot.branch = try snapshot.allocator.dupe(u8, branch_part[0..end]);
            }
            continue;
        }
        if (entry.len < 4) continue;
        const state = stateFromStatus(entry[0..2]) orelse continue;
        var path = entry[3..];
        if (std.mem.indexOf(u8, path, " -> ")) |idx| {
            path = path[idx + " -> ".len ..];
        }
        try snapshot.put(path, state);
    }
}

test "git porcelain snapshot parses branch and states" {
    const allocator = std.testing.allocator;
    var snapshot = Snapshot.init(allocator);
    defer snapshot.deinit();

    try parsePorcelain(&snapshot, "## main...origin/main\x00 M src/main.zig\x00?? notes.md\x00!! zig-out/\x00");

    try std.testing.expectEqualStrings("main", snapshot.branch.?);
    try std.testing.expectEqual(FileState.modified, snapshot.stateForPath("src/main.zig").?);
    try std.testing.expectEqual(FileState.untracked, snapshot.stateForPath("./notes.md").?);
    try std.testing.expectEqual(FileState.ignored, snapshot.stateForPath("zig-out").?);
}

test "git snapshot equality compares branch root and entries" {
    const allocator = std.testing.allocator;
    var lhs = Snapshot.init(allocator);
    defer lhs.deinit();
    var rhs = Snapshot.init(allocator);
    defer rhs.deinit();

    lhs.root_path = try allocator.dupe(u8, "/repo");
    rhs.root_path = try allocator.dupe(u8, "/repo");
    lhs.branch = try allocator.dupe(u8, "main");
    rhs.branch = try allocator.dupe(u8, "main");
    try lhs.put("src/main.zig", .modified);
    try rhs.put("src/main.zig", .modified);

    try std.testing.expect(lhs.eql(&rhs));
    try rhs.put("README.md", .untracked);
    try std.testing.expect(!lhs.eql(&rhs));
}
