const std = @import("std");
const repository = @import("repository.zig");
const diff_model = @import("diff_model.zig");
const parser = @import("unified_diff_parser.zig");

const Repository = repository.Repository;
const FileDiff = diff_model.FileDiff;
const RefreshStatus = diff_model.RefreshStatus;

pub const RefreshResult = struct {
    /// Owned absolute path. Consumers must call deinit or transfer ownership.
    absolute_path: []u8,
    diff: ?FileDiff = null,
    status: RefreshStatus = .disabled,
    explicit: bool = false,

    pub fn deinit(self: *RefreshResult, allocator: std.mem.Allocator) void {
        allocator.free(self.absolute_path);
        if (self.diff) |*diff| diff.deinit(allocator);
        self.* = undefined;
    }
};

pub const DiffService = struct {
    allocator: std.mem.Allocator,
    files: std.StringHashMap(FileDiff),

    pub fn init(allocator: std.mem.Allocator) DiffService {
        return .{
            .allocator = allocator,
            .files = std.StringHashMap(FileDiff).init(allocator),
        };
    }

    pub fn deinit(self: *DiffService) void {
        var it = self.files.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.files.deinit();
        self.* = undefined;
    }

    pub fn applyRefreshResult(self: *DiffService, result: *RefreshResult) !void {
        if (result.diff) |diff| {
            try self.putDiff(diff);
            result.diff = null;
        } else {
            _ = self.remove(result.absolute_path);
        }
    }

    pub fn putDiff(self: *DiffService, diff: FileDiff) !void {
        const key = try self.allocator.dupe(u8, diff.path);
        errdefer self.allocator.free(key);
        const entry = try self.files.getOrPut(key);
        if (entry.found_existing) {
            self.allocator.free(key);
            entry.value_ptr.deinit(self.allocator);
        }
        entry.value_ptr.* = diff;
    }

    pub fn remove(self: *DiffService, absolute_path: []const u8) bool {
        if (self.files.fetchRemove(absolute_path)) |kv| {
            self.allocator.free(kv.key);
            var diff = kv.value;
            diff.deinit(self.allocator);
            return true;
        }
        return false;
    }

    pub fn getFileDiff(self: *const DiffService, absolute_path: []const u8) ?*const FileDiff {
        return self.files.getPtr(absolute_path);
    }

    pub fn getLineChange(self: *const DiffService, absolute_path: []const u8, line: usize) ?diff_model.LineChange {
        const diff = self.getFileDiff(absolute_path) orelse return null;
        return diff.lineChange(line);
    }

    /// The returned pointers are borrowed until the next cache mutation.
    pub fn listChangedFiles(self: *const DiffService, allocator: std.mem.Allocator) ![]const *const FileDiff {
        var out = std.ArrayListUnmanaged(*const FileDiff).empty;
        errdefer out.deinit(allocator);
        var it = self.files.iterator();
        while (it.next()) |entry| {
            try out.append(allocator, entry.value_ptr);
        }
        return out.toOwnedSlice(allocator);
    }

    pub fn refreshRepository(self: *DiffService) !void {
        _ = self;
        return error.NotImplemented;
    }

    pub fn refreshFile(self: *DiffService, io: std.Io, absolute_path: []const u8, line_count: usize) !RefreshStatus {
        var result = try computeFileDiff(self.allocator, io, absolute_path, line_count, false);
        defer result.deinit(self.allocator);
        const status = result.status;
        try self.applyRefreshResult(&result);
        return status;
    }
};

fn processStatus(status_output: []const u8) enum { clean, untracked, changed } {
    var it = std.mem.splitScalar(u8, status_output, 0);
    while (it.next()) |entry| {
        if (entry.len < 2) continue;
        if (entry[0] == '?' and entry[1] == '?') return .untracked;
        if (entry[0] != ' ' or entry[1] != ' ') return .changed;
    }
    return .clean;
}

fn runGitStatus(allocator: std.mem.Allocator, io: std.Io, repo: Repository, rel_path: []const u8) ![]u8 {
    const result = try std.process.run(allocator, io, .{
        .argv = &.{ "git", "-C", repo.root, "status", "--porcelain=v1", "-z", "--", rel_path },
        .stdout_limit = std.Io.Limit.limited(64 * 1024),
        .stderr_limit = std.Io.Limit.limited(16 * 1024),
    });
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) {
            allocator.free(result.stdout);
            return error.GitCommandFailed;
        },
        else => {
            allocator.free(result.stdout);
            return error.GitCommandFailed;
        },
    }
    return result.stdout;
}

fn runGitDiff(allocator: std.mem.Allocator, io: std.Io, repo: Repository, rel_path: []const u8) ![]u8 {
    const result = try std.process.run(allocator, io, .{
        .argv = &.{ "git", "-C", repo.root, "diff", "--no-ext-diff", "--unified=0", "--", rel_path },
        .stdout_limit = std.Io.Limit.limited(1024 * 1024),
        .stderr_limit = std.Io.Limit.limited(64 * 1024),
    });
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) {
            allocator.free(result.stdout);
            return error.GitCommandFailed;
        },
        else => {
            allocator.free(result.stdout);
            return error.GitCommandFailed;
        },
    }
    return result.stdout;
}

pub fn computeFileDiff(
    allocator: std.mem.Allocator,
    io: std.Io,
    absolute_path: []const u8,
    line_count: usize,
    explicit: bool,
) !RefreshResult {
    const owned_path = try allocator.dupe(u8, absolute_path);
    errdefer allocator.free(owned_path);

    var repo = (try repository.discover(allocator, io, absolute_path)) orelse return .{
        .absolute_path = owned_path,
        .status = .disabled,
        .explicit = explicit,
    };
    defer repo.deinit(allocator);

    const rel_path = (try repository.relativePath(allocator, repo, absolute_path)) orelse return .{
        .absolute_path = owned_path,
        .status = .outside_repository,
        .explicit = explicit,
    };
    defer allocator.free(rel_path);

    const status_output = runGitStatus(allocator, io, repo, rel_path) catch |err| switch (err) {
        error.FileNotFound => return .{ .absolute_path = owned_path, .status = .git_unavailable, .explicit = explicit },
        error.StreamTooLong => return .{ .absolute_path = owned_path, .status = .output_too_large, .explicit = explicit },
        else => return .{ .absolute_path = owned_path, .status = .command_failed, .explicit = explicit },
    };
    defer allocator.free(status_output);

    switch (processStatus(status_output)) {
        .untracked => {
            const diff = try diff_model.allAdded(allocator, absolute_path, line_count);
            return .{ .absolute_path = owned_path, .diff = diff, .status = .untracked, .explicit = explicit };
        },
        .clean => return .{ .absolute_path = owned_path, .status = .clean, .explicit = explicit },
        .changed => {},
    }

    const patch = runGitDiff(allocator, io, repo, rel_path) catch |err| switch (err) {
        error.FileNotFound => return .{ .absolute_path = owned_path, .status = .git_unavailable, .explicit = explicit },
        error.StreamTooLong => return .{ .absolute_path = owned_path, .status = .output_too_large, .explicit = explicit },
        else => return .{ .absolute_path = owned_path, .status = .command_failed, .explicit = explicit },
    };
    defer allocator.free(patch);

    const changes = try parser.parse(allocator, patch);
    errdefer allocator.free(changes);
    if (changes.len == 0) {
        allocator.free(changes);
        return .{ .absolute_path = owned_path, .status = .clean, .explicit = explicit };
    }

    const diff = FileDiff{
        .path = try allocator.dupe(u8, absolute_path),
        .changes = changes,
        .status = .changed,
    };
    return .{ .absolute_path = owned_path, .diff = diff, .status = .changed, .explicit = explicit };
}

test "service caches and removes diffs by path" {
    const allocator = std.testing.allocator;
    var service = DiffService.init(allocator);
    defer service.deinit();

    var diff = try diff_model.allAdded(allocator, "/repo/new.zig", 2);
    diff.status = .changed;
    try service.putDiff(diff);

    try std.testing.expectEqual(diff_model.LineChangeKind.added, service.getLineChange("/repo/new.zig", 1).?.kind);
    try std.testing.expect(service.remove("/repo/new.zig"));
    try std.testing.expect(service.getFileDiff("/repo/new.zig") == null);
}

test "status parser detects untracked and changed files" {
    try std.testing.expectEqual(.clean, processStatus(""));
    try std.testing.expectEqual(.untracked, processStatus("?? new.zig\x00"));
    try std.testing.expectEqual(.changed, processStatus(" M src/main.zig\x00"));
}
