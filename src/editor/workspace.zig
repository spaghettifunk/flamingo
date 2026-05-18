const std = @import("std");

pub const directory_name = ".flamingo";

pub const WorkspaceStatus = enum {
    none,
    valid,
    invalid_path_exists,
};

pub const CreateWorkspaceResult = enum {
    created,
    already_exists,
    invalid_path_exists,
};

pub const WorkspaceState = struct {
    active: bool = false,
    root_path: ?[]u8 = null,

    pub fn deinit(self: *WorkspaceState, allocator: std.mem.Allocator) void {
        self.clear(allocator);
    }

    pub fn clear(self: *WorkspaceState, allocator: std.mem.Allocator) void {
        if (self.root_path) |path| allocator.free(path);
        self.* = .{};
    }

    pub fn setActive(self: *WorkspaceState, allocator: std.mem.Allocator, root_path: []const u8) !void {
        const owned = try allocator.dupe(u8, root_path);
        if (self.root_path) |old| allocator.free(old);
        self.active = true;
        self.root_path = owned;
    }
};

fn markerPath(allocator: std.mem.Allocator, folder_path: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ folder_path, directory_name });
}

pub fn detectWorkspace(allocator: std.mem.Allocator, io: std.Io, folder_path: []const u8) !WorkspaceStatus {
    const path = try markerPath(allocator, folder_path);
    defer allocator.free(path);

    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return .none,
        else => return err,
    };
    return if (stat.kind == .directory) .valid else .invalid_path_exists;
}

pub fn createWorkspace(allocator: std.mem.Allocator, io: std.Io, folder_path: []const u8) !CreateWorkspaceResult {
    const path = try markerPath(allocator, folder_path);
    defer allocator.free(path);

    if (std.Io.Dir.cwd().statFile(io, path, .{})) |stat| {
        return if (stat.kind == .directory) .already_exists else .invalid_path_exists;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    std.Io.Dir.cwd().createDir(io, path, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {
            const stat = try std.Io.Dir.cwd().statFile(io, path, .{});
            return if (stat.kind == .directory) .already_exists else .invalid_path_exists;
        },
        else => return err,
    };
    return .created;
}

pub fn createResultMessage(result: CreateWorkspaceResult) []const u8 {
    return switch (result) {
        .created => "Workspace created",
        .already_exists => "Workspace already exists in this folder",
        .invalid_path_exists => "Cannot create workspace: .flamingo exists and is not a directory",
    };
}

test "detectWorkspace reports missing marker" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = path_buf[0..try tmp.dir.realPath(io, &path_buf)];

    try std.testing.expectEqual(WorkspaceStatus.none, try detectWorkspace(allocator, io, root));
}

test "detectWorkspace reports valid marker directory" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, directory_name);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = path_buf[0..try tmp.dir.realPath(io, &path_buf)];

    try std.testing.expectEqual(WorkspaceStatus.valid, try detectWorkspace(allocator, io, root));
}

test "detectWorkspace reports invalid marker file" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = directory_name, .data = "" });

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = path_buf[0..try tmp.dir.realPath(io, &path_buf)];

    try std.testing.expectEqual(WorkspaceStatus.invalid_path_exists, try detectWorkspace(allocator, io, root));
}

test "createWorkspace creates marker directory" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = path_buf[0..try tmp.dir.realPath(io, &path_buf)];

    try std.testing.expectEqual(CreateWorkspaceResult.created, try createWorkspace(allocator, io, root));
    try std.testing.expectEqual(WorkspaceStatus.valid, try detectWorkspace(allocator, io, root));
}

test "createWorkspace does not overwrite existing marker directory" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, directory_name);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = path_buf[0..try tmp.dir.realPath(io, &path_buf)];

    try std.testing.expectEqual(CreateWorkspaceResult.already_exists, try createWorkspace(allocator, io, root));
    try std.testing.expectEqual(WorkspaceStatus.valid, try detectWorkspace(allocator, io, root));
}

test "createWorkspace does not overwrite existing marker file" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = directory_name, .data = "not a workspace directory" });

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = path_buf[0..try tmp.dir.realPath(io, &path_buf)];

    try std.testing.expectEqual(CreateWorkspaceResult.invalid_path_exists, try createWorkspace(allocator, io, root));
    try std.testing.expectEqual(WorkspaceStatus.invalid_path_exists, try detectWorkspace(allocator, io, root));
}
