const std = @import("std");

pub const Repository = struct {
    /// Owned absolute or cwd-relative repository worktree root.
    root: []u8,
    /// Owned .git directory path when it can be resolved from the marker.
    git_dir: ?[]u8 = null,

    pub fn deinit(self: *Repository, allocator: std.mem.Allocator) void {
        allocator.free(self.root);
        if (self.git_dir) |git_dir| allocator.free(git_dir);
        self.* = undefined;
    }
};

fn realPathOwned(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    const real_path_z = try std.Io.Dir.cwd().realPathFileAlloc(io, path, allocator);
    defer allocator.free(real_path_z);
    return allocator.dupe(u8, real_path_z);
}

fn startDirectory(allocator: std.mem.Allocator, io: std.Io, start_path: []const u8) ![]u8 {
    const stat = std.Io.Dir.cwd().statFile(io, start_path, .{}) catch null;
    const dir = if (stat) |s|
        if (s.kind == .file) (std.fs.path.dirname(start_path) orelse ".") else start_path
    else
        (std.fs.path.dirname(start_path) orelse start_path);

    return realPathOwned(allocator, io, dir) catch allocator.dupe(u8, dir);
}

fn resolveGitDir(allocator: std.mem.Allocator, root: []const u8, marker_path: []const u8, contents: []const u8) !?[]u8 {
    const trimmed = std.mem.trim(u8, contents, " \t\r\n");
    if (!std.mem.startsWith(u8, trimmed, "gitdir:")) return null;

    const raw = std.mem.trim(u8, trimmed["gitdir:".len..], " \t\r\n");
    if (raw.len == 0) return null;
    if (std.fs.path.isAbsolute(raw)) return try allocator.dupe(u8, raw);

    const marker_dir = std.fs.path.dirname(marker_path) orelse root;
    return try std.fs.path.join(allocator, &.{ marker_dir, raw });
}

fn gitMarker(allocator: std.mem.Allocator, io: std.Io, root: []const u8) !?[]u8 {
    const marker = try std.fs.path.join(allocator, &.{ root, ".git" });
    errdefer allocator.free(marker);

    const stat = std.Io.Dir.cwd().statFile(io, marker, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            allocator.free(marker);
            return null;
        },
        else => {
            allocator.free(marker);
            return null;
        },
    };

    if (stat.kind == .directory) return marker;
    if (stat.kind != .file) {
        allocator.free(marker);
        return null;
    }

    const contents = std.Io.Dir.cwd().readFileAlloc(io, marker, allocator, std.Io.Limit.limited(4096)) catch {
        allocator.free(marker);
        return null;
    };
    defer allocator.free(contents);

    if (!std.mem.startsWith(u8, std.mem.trim(u8, contents, " \t\r\n"), "gitdir:")) {
        allocator.free(marker);
        return null;
    }
    return marker;
}

/// Walks upward from a file or directory and returns owned repository metadata.
/// A .git directory and a .git file with `gitdir: ...` worktree metadata both
/// identify the repository root.
pub fn discover(allocator: std.mem.Allocator, io: std.Io, start_path: []const u8) !?Repository {
    var current = try startDirectory(allocator, io, start_path);
    defer allocator.free(current);

    while (true) {
        if (try gitMarker(allocator, io, current)) |marker| {
            defer allocator.free(marker);
            const stat = std.Io.Dir.cwd().statFile(io, marker, .{}) catch null;
            const git_dir = if (stat != null and stat.?.kind == .directory)
                try allocator.dupe(u8, marker)
            else blk: {
                const contents = std.Io.Dir.cwd().readFileAlloc(io, marker, allocator, std.Io.Limit.limited(4096)) catch break :blk null;
                defer allocator.free(contents);
                break :blk try resolveGitDir(allocator, current, marker, contents);
            };
            errdefer if (git_dir) |owned| allocator.free(owned);
            return .{
                .root = try allocator.dupe(u8, current),
                .git_dir = git_dir,
            };
        }

        const parent = std.fs.path.dirname(current) orelse break;
        if (std.mem.eql(u8, parent, current)) break;
        const owned_parent = try allocator.dupe(u8, parent);
        allocator.free(current);
        current = owned_parent;
    }

    return null;
}

pub fn containsPath(repo: Repository, path: []const u8) bool {
    if (std.mem.eql(u8, path, repo.root)) return true;
    if (!std.mem.startsWith(u8, path, repo.root)) return false;
    return path.len > repo.root.len and (path[repo.root.len] == '/' or path[repo.root.len] == std.fs.path.sep);
}

pub fn relativePath(allocator: std.mem.Allocator, repo: Repository, absolute_path: []const u8) !?[]u8 {
    if (!containsPath(repo, absolute_path)) return null;
    var rel = absolute_path[repo.root.len..];
    while (rel.len > 0 and (rel[0] == '/' or rel[0] == std.fs.path.sep)) rel = rel[1..];
    return try allocator.dupe(u8, rel);
}

test "repository discovery finds .git directory and nested child" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, ".git");
    try tmp.dir.createDirPath(io, "src/editor");

    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);
    const nested = try std.fs.path.join(allocator, &.{ root, "src", "editor" });
    defer allocator.free(nested);

    var repo = (try discover(allocator, io, nested)).?;
    defer repo.deinit(allocator);

    try std.testing.expect(std.mem.endsWith(u8, repo.root, &tmp.sub_path));
    try std.testing.expect(repo.git_dir != null);
}

test "repository discovery supports .git file worktree metadata" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = ".git", .data = "gitdir: ../actual/.git/worktrees/demo\n" });
    try tmp.dir.createDirPath(io, "child");

    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);
    const child = try std.fs.path.join(allocator, &.{ root, "child" });
    defer allocator.free(child);

    var repo = (try discover(allocator, io, child)).?;
    defer repo.deinit(allocator);

    try std.testing.expect(std.mem.endsWith(u8, repo.root, &tmp.sub_path));
    try std.testing.expect(repo.git_dir != null);
}

test "repository discovery reports no repo" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    try std.testing.expect((try discover(allocator, io, "/private/tmp/flamingo-git-diff-no-repo/subdir")) == null);
}
