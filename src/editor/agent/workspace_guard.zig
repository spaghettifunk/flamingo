const std = @import("std");

pub const Error = error{
    EmptyWorkspaceRoot,
    EmptyPath,
    OutsideWorkspace,
    GitInternalsForbidden,
};

fn realPathOwned(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    const real_path_z = try std.Io.Dir.cwd().realPathFileAlloc(io, path, allocator);
    defer allocator.free(real_path_z);
    return allocator.dupe(u8, real_path_z);
}

pub fn normalizeWorkspaceRoot(allocator: std.mem.Allocator, io: std.Io, root: []const u8) ![]u8 {
    if (root.len == 0) return error.EmptyWorkspaceRoot;
    return realPathOwned(allocator, io, root) catch allocator.dupe(u8, root);
}

pub fn isPathInsideRoot(path: []const u8, root: []const u8) bool {
    if (std.mem.eql(u8, path, root)) return true;
    if (!std.mem.startsWith(u8, path, root)) return false;
    return path.len > root.len and (path[root.len] == '/' or path[root.len] == std.fs.path.sep);
}

pub fn hasGitSegment(path: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, path, "/\\");
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, ".git")) return true;
    }
    return false;
}

pub fn resolveWorkspacePath(
    allocator: std.mem.Allocator,
    io: std.Io,
    workspace_root: []const u8,
    input_path: []const u8,
) ![]u8 {
    if (workspace_root.len == 0) return error.EmptyWorkspaceRoot;
    if (input_path.len == 0) return error.EmptyPath;
    if (hasGitSegment(input_path)) return error.GitInternalsForbidden;

    const root = try normalizeWorkspaceRoot(allocator, io, workspace_root);
    defer allocator.free(root);

    var joined: []u8 = undefined;
    if (std.fs.path.isAbsolute(input_path)) {
        joined = try allocator.dupe(u8, input_path);
    } else {
        joined = try std.fs.path.join(allocator, &.{ root, input_path });
    }
    errdefer allocator.free(joined);

    const normalized = try std.fs.path.resolve(allocator, &.{joined});
    allocator.free(joined);
    joined = normalized;

    if (realPathOwned(allocator, io, joined)) |real| {
        allocator.free(joined);
        joined = real;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    if (!isPathInsideRoot(joined, root)) return error.OutsideWorkspace;
    const rel = relativePath(root, joined);
    if (hasGitSegment(rel)) return error.GitInternalsForbidden;
    return joined;
}

pub fn relativePath(root: []const u8, absolute_path: []const u8) []const u8 {
    if (std.mem.eql(u8, root, absolute_path)) return ".";
    if (!std.mem.startsWith(u8, absolute_path, root)) return absolute_path;
    var rel = absolute_path[root.len..];
    while (rel.len > 0 and (rel[0] == '/' or rel[0] == std.fs.path.sep)) rel = rel[1..];
    return if (rel.len == 0) "." else rel;
}

test "agent workspace guard rejects traversal outside root" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);

    try std.testing.expectError(
        error.OutsideWorkspace,
        resolveWorkspacePath(allocator, io, root, "../outside.txt"),
    );
}

test "agent workspace guard rejects git internals" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, ".git");
    try tmp.dir.writeFile(io, .{ .sub_path = ".git/config", .data = "" });

    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);

    try std.testing.expectError(
        error.GitInternalsForbidden,
        resolveWorkspacePath(allocator, io, root, ".git/config"),
    );
}

test "agent workspace guard resolves a file inside root" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/main.zig", .data = "" });

    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);

    const path = try resolveWorkspacePath(allocator, io, root, "src/main.zig");
    defer allocator.free(path);
    try std.testing.expect(std.mem.endsWith(u8, path, "src/main.zig"));
}
