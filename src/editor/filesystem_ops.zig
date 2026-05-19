const std = @import("std");
const editor = @import("editor.zig");
const buffer = @import("model/buffer.zig");
const explorer = @import("explorer.zig");
const workspace = @import("workspace.zig");

pub const PathKind = enum { file, directory, other };

pub const FsError = error{
    EmptyPath,
    InvalidPath,
    OutsideProjectRoot,
    PathAlreadyExists,
    FileNotFound,
    ParentMissing,
    ExpectedFile,
    ExpectedDirectory,
    FileIsOpen,
    DirectoryNotEmpty,
};

pub const WorkspaceCreateResult = workspace.CreateWorkspaceResult;

fn containsWhitespace(path: []const u8) bool {
    for (path) |ch| {
        if (std.ascii.isWhitespace(ch)) return true;
    }
    return false;
}

pub fn rejectCommandPath(path: []const u8) FsError!void {
    if (path.len == 0) return error.EmptyPath;
    if (containsWhitespace(path)) return error.InvalidPath;
    if (std.mem.indexOfAny(u8, path, "\"'") != null) return error.InvalidPath;
}

fn realPathOwned(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    const z = try std.Io.Dir.cwd().realPathFileAlloc(io, path, allocator);
    defer allocator.free(z);
    return allocator.dupe(u8, z);
}

fn cwdRealPathAlloc(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    return realPathOwned(allocator, io, ".");
}

fn realPathOrNull(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ?[]u8 {
    return realPathOwned(allocator, io, path) catch null;
}

fn normalizeExistingRoot(allocator: std.mem.Allocator, io: std.Io, root: []const u8) ![]u8 {
    return realPathOrNull(allocator, io, root) orelse try allocator.dupe(u8, root);
}

fn isPathInsideRoot(path: []const u8, root: []const u8) bool {
    if (std.mem.eql(u8, path, root)) return true;
    if (!std.mem.startsWith(u8, path, root)) return false;
    if (path.len <= root.len) return false;
    return path[root.len] == std.fs.path.sep or path[root.len] == '/';
}

pub fn resolveProjectPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: ?[]const u8,
    input_path: []const u8,
) ![]u8 {
    try rejectCommandPath(input_path);
    return resolvePathInsideProjectRoot(allocator, io, project_root, input_path);
}

pub fn resolvePathInsideProjectRoot(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: ?[]const u8,
    input_path: []const u8,
) ![]u8 {
    const root = if (project_root) |r|
        try normalizeExistingRoot(allocator, io, r)
    else
        try cwdRealPathAlloc(allocator, io);
    defer allocator.free(root);

    var joined: []u8 = undefined;
    if (std.fs.path.isAbsolute(input_path)) {
        joined = try allocator.dupe(u8, input_path);
    } else {
        joined = try std.fs.path.join(allocator, &.{ root, input_path });
    }
    errdefer allocator.free(joined);

    if (realPathOrNull(allocator, io, joined)) |real| {
        allocator.free(joined);
        joined = real;
    } else if (std.fs.path.dirname(joined)) |parent| {
        if (realPathOrNull(allocator, io, parent)) |real_parent| {
            defer allocator.free(real_parent);
            const base = std.fs.path.basename(joined);
            const normalized = try std.fs.path.join(allocator, &.{ real_parent, base });
            allocator.free(joined);
            joined = normalized;
        }
    }

    if (project_root != null and !isPathInsideRoot(joined, root)) return error.OutsideProjectRoot;
    return joined;
}

pub fn kindOf(io: std.Io, path: []const u8) !PathKind {
    const stat = try std.Io.Dir.cwd().statFile(io, path, .{});
    return switch (stat.kind) {
        .file => .file,
        .directory => .directory,
        else => .other,
    };
}

pub fn createFileNoOverwrite(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    create_parents: bool,
) !void {
    if (path.len == 0) return error.EmptyPath;
    if (std.Io.Dir.cwd().statFile(io, path, .{})) |_| return error.PathAlreadyExists else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    if (std.fs.path.dirname(path)) |parent| {
        if (create_parents) {
            try std.Io.Dir.cwd().createDirPath(io, parent);
        } else {
            const parent_stat = std.Io.Dir.cwd().statFile(io, parent, .{}) catch return error.ParentMissing;
            if (parent_stat.kind != .directory) return error.ParentMissing;
        }
    }

    const file = try std.Io.Dir.cwd().createFile(io, path, .{ .exclusive = true });
    defer file.close(io);
    _ = allocator;
}

pub fn renameNoOverwrite(io: std.Io, old_path: []const u8, new_path: []const u8) !void {
    if (old_path.len == 0 or new_path.len == 0) return error.EmptyPath;
    _ = std.Io.Dir.cwd().statFile(io, old_path, .{}) catch return error.FileNotFound;
    if (std.Io.Dir.cwd().statFile(io, new_path, .{})) |_| return error.PathAlreadyExists else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    if (std.fs.path.dirname(new_path)) |parent| {
        const parent_stat = std.Io.Dir.cwd().statFile(io, parent, .{}) catch return error.ParentMissing;
        if (parent_stat.kind != .directory) return error.ParentMissing;
    }
    try std.Io.Dir.cwd().renamePreserve(old_path, std.Io.Dir.cwd(), new_path, io);
}

pub fn deleteRegularFile(io: std.Io, path: []const u8) !void {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return error.FileNotFound;
    if (stat.kind != .file) return error.ExpectedFile;
    try std.Io.Dir.cwd().deleteFile(io, path);
}

pub fn deleteEmptyDirectory(io: std.Io, path: []const u8) !void {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return error.FileNotFound;
    if (stat.kind != .directory) return error.ExpectedDirectory;
    std.Io.Dir.cwd().deleteDir(io, path) catch |err| switch (err) {
        error.DirNotEmpty => return error.DirectoryNotEmpty,
        else => return err,
    };
}

pub fn isOpenInEditor(ed: *const editor.Editor, path: []const u8) bool {
    for (ed.state.tabs.items) |*tab| {
        if (tab.buf.filename) |filename| {
            if (std.mem.eql(u8, filename, path)) return true;
            const real_filename = realPathOrNull(ed.allocator, ed.io, filename) orelse continue;
            defer ed.allocator.free(real_filename);
            const real_path = realPathOrNull(ed.allocator, ed.io, path) orelse continue;
            defer ed.allocator.free(real_path);
            if (std.mem.eql(u8, real_filename, real_path)) return true;
        }
    }
    return false;
}

pub fn updateOpenBuffersAfterRename(ed: *editor.Editor, old_path: []const u8, new_path: []const u8) !void {
    for (ed.state.tabs.items) |*tab| {
        if (tab.buf.filename) |filename| {
            const matches = blk: {
                if (std.mem.eql(u8, filename, old_path)) break :blk true;
                const real_filename = realPathOrNull(ed.allocator, ed.io, filename) orelse break :blk false;
                defer ed.allocator.free(real_filename);
                const real_old = realPathOrNull(ed.allocator, ed.io, old_path) orelse break :blk false;
                defer ed.allocator.free(real_old);
                break :blk std.mem.eql(u8, real_filename, real_old);
            };
            if (matches) {
                try tab.buf.setFilename(new_path);
                tab.lsp_notified_revision = if (tab.buf.filename != null) tab.buf.revision else null;
            }
        }
    }
}

pub fn openFileInEditor(ed: *editor.Editor, path: []const u8) !void {
    var b = try buffer.Buffer.loadFromFile(ed.allocator, ed.io, path);
    errdefer b.deinit();
    try ed.addTab(b);
    ed.state.mode = .Normal;
    ed.state.explorer_focused = false;
}

pub fn createFileAndOpen(ed: *editor.Editor, path: []const u8, create_parents: bool) !void {
    try createFileNoOverwrite(ed.allocator, ed.io, path, create_parents);
    try openFileInEditor(ed, path);
    try refreshExplorerBestEffort(ed, path);
}

pub fn openFolderInEditor(ed: *editor.Editor, path: []const u8) !void {
    const stat = std.Io.Dir.cwd().statFile(ed.io, path, .{}) catch return error.FileNotFound;
    if (stat.kind != .directory) return error.ExpectedDirectory;

    const root = realPathOrNull(ed.allocator, ed.io, path) orelse try ed.allocator.dupe(u8, path);
    defer ed.allocator.free(root);

    ed.closeAllTabs();
    ed.state.todo_panel.visible = false;
    ed.state.todo_panel.focused = false;
    ed.state.todo_panel.clearCode(ed.allocator);
    ed.state.todo_panel.clearManual(ed.allocator);
    try ed.state.setProjectRoot(ed.allocator, root);
    if (ed.state.tree) |*tree| {
        tree.deinit();
        ed.state.tree = null;
    }
    ed.state.tree = try explorer.Explorer.init(ed.allocator, ed.io, root);
    ed.state.explorer_visible = true;
    ed.state.explorer_focused = true;
    ed.state.mode = .Normal;
    try refreshWorkspaceState(ed, root);
}

pub fn createWorkspaceAndOpenFolder(ed: *editor.Editor, path: []const u8) !WorkspaceCreateResult {
    const stat = std.Io.Dir.cwd().statFile(ed.io, path, .{}) catch return error.FileNotFound;
    if (stat.kind != .directory) return error.ExpectedDirectory;

    const root = realPathOrNull(ed.allocator, ed.io, path) orelse try ed.allocator.dupe(u8, path);
    defer ed.allocator.free(root);

    const result = try workspace.createWorkspace(ed.allocator, ed.io, root);
    if (result == .created) {
        try openFolderInEditor(ed, root);
    }
    return result;
}

pub fn workspaceCreateMessage(result: WorkspaceCreateResult) []const u8 {
    return workspace.createResultMessage(result);
}

pub fn workspaceCreateErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "Cannot create workspace: folder does not exist",
        error.ExpectedDirectory, error.NotDir => "Cannot create workspace: selected path is not a directory",
        error.AccessDenied, error.PermissionDenied => "Cannot create workspace: permission denied",
        else => "Cannot create workspace: filesystem operation failed",
    };
}

fn refreshWorkspaceState(ed: *editor.Editor, root: []const u8) !void {
    const status = workspace.detectWorkspace(ed.allocator, ed.io, root) catch {
        ed.state.clearWorkspace(ed.allocator);
        ed.state.status_message = "Could not inspect workspace marker";
        return;
    };

    switch (status) {
        .valid => {
            try ed.state.setWorkspaceRoot(ed.allocator, root);
            ed.state.status_message = null;
        },
        .none => {
            ed.state.clearWorkspace(ed.allocator);
            ed.state.status_message = null;
        },
        .invalid_path_exists => {
            ed.state.clearWorkspace(ed.allocator);
            ed.state.status_message = ".flamingo exists and is not a directory";
        },
    }
}

pub fn refreshExplorerBestEffort(ed: *editor.Editor, reveal_path: ?[]const u8) !void {
    if (ed.state.tree) |*tree| {
        try tree.refresh(reveal_path);
    }
}

pub fn userMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.EmptyPath, error.InvalidPath => "Invalid path",
        error.OutsideProjectRoot => "Path is outside project root",
        error.PathAlreadyExists => "File already exists",
        error.FileNotFound => "File does not exist",
        error.ParentMissing => "Parent directory does not exist",
        error.ExpectedFile => "Expected a file",
        error.ExpectedDirectory => "Expected a directory",
        error.FileIsOpen => "File is open; close it before deleting",
        error.DirectoryNotEmpty => "Directory is not empty",
        error.NotDir => "Expected a directory",
        error.AccessDenied, error.PermissionDenied => "Permission denied",
        else => "Filesystem operation failed",
    };
}

test "resolveProjectPath rejects outside project root" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = path_buf[0..try tmp.dir.realPath(io, &path_buf)];

    const inside = try resolveProjectPath(allocator, io, root, "new.txt");
    defer allocator.free(inside);
    try std.testing.expect(std.mem.startsWith(u8, inside, root));

    try std.testing.expectError(error.OutsideProjectRoot, resolveProjectPath(allocator, io, root, "/tmp/outside-flamingo.txt"));
}

test "create and rename refuse existing destinations" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = path_buf[0..try tmp.dir.realPath(io, &path_buf)];
    const a = try std.fs.path.join(allocator, &.{ root, "a.txt" });
    defer allocator.free(a);
    const b = try std.fs.path.join(allocator, &.{ root, "b.txt" });
    defer allocator.free(b);

    try createFileNoOverwrite(allocator, io, a, false);
    try std.testing.expectError(error.PathAlreadyExists, createFileNoOverwrite(allocator, io, a, false));
    try createFileNoOverwrite(allocator, io, b, false);
    try std.testing.expectError(error.PathAlreadyExists, renameNoOverwrite(io, a, b));
}

test "deleteRegularFile refuses directories" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = path_buf[0..try tmp.dir.realPath(io, &path_buf)];
    const dir_path = try std.fs.path.join(allocator, &.{ root, "dir" });
    defer allocator.free(dir_path);
    try std.Io.Dir.cwd().createDirPath(io, dir_path);

    try std.testing.expectError(error.ExpectedFile, deleteRegularFile(io, dir_path));
}

test "isOpenInEditor detects open buffer filenames" {
    const allocator = std.testing.allocator;
    var ed = try editor.Editor.init(allocator, std.testing.io, .{});
    defer ed.deinit();

    var b = try buffer.Buffer.init(allocator);
    errdefer b.deinit();
    try b.setFilename("/tmp/flamingo-open.txt");
    try ed.addTab(b);

    try std.testing.expect(isOpenInEditor(&ed, "/tmp/flamingo-open.txt"));
    try std.testing.expect(!isOpenInEditor(&ed, "/tmp/flamingo-other.txt"));
}

test "open buffer checks handle relative and absolute paths" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "open.txt", .data = "" });
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = path_buf[0..try tmp.dir.realPath(io, &path_buf)];
    const absolute_path = try std.fs.path.join(allocator, &.{ root, "open.txt" });
    defer allocator.free(absolute_path);
    const relative_path = try std.fs.path.join(allocator, &.{ ".zig-cache/tmp", &tmp.sub_path, "open.txt" });
    defer allocator.free(relative_path);

    var ed = try editor.Editor.init(allocator, io, .{});
    defer ed.deinit();

    var b = try buffer.Buffer.init(allocator);
    errdefer b.deinit();
    try b.setFilename(relative_path);
    try ed.addTab(b);

    try std.testing.expect(isOpenInEditor(&ed, absolute_path));
}

test "rename update handles relative open buffer filenames" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "old.txt", .data = "" });
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = path_buf[0..try tmp.dir.realPath(io, &path_buf)];
    const old_absolute = try std.fs.path.join(allocator, &.{ root, "old.txt" });
    defer allocator.free(old_absolute);
    const new_absolute = try std.fs.path.join(allocator, &.{ root, "new.txt" });
    defer allocator.free(new_absolute);
    const old_relative = try std.fs.path.join(allocator, &.{ ".zig-cache/tmp", &tmp.sub_path, "old.txt" });
    defer allocator.free(old_relative);

    var ed = try editor.Editor.init(allocator, io, .{});
    defer ed.deinit();

    var b = try buffer.Buffer.init(allocator);
    errdefer b.deinit();
    try b.setFilename(old_relative);
    try ed.addTab(b);

    try updateOpenBuffersAfterRename(&ed, old_absolute, new_absolute);
    try std.testing.expectEqualStrings(new_absolute, ed.currentTab().?.buf.filename.?);
}
