const std = @import("std");
const keybindings = @import("../keybindings.zig");
const repository = @import("repository.zig");

pub const max_diff_lines: usize = 20_000;

pub const Error = error{
    NotGitRepository,
};

pub const OpenContext = struct {
    project_root: ?[]const u8 = null,
    explorer_root: ?[]const u8 = null,
    current_file: ?[]const u8 = null,
};

pub const GitChangeKind = enum {
    modified,
    added,
    deleted,
    renamed,
    untracked,

    pub fn label(self: GitChangeKind) []const u8 {
        return switch (self) {
            .modified => "M",
            .added => "A",
            .deleted => "D",
            .renamed => "R",
            .untracked => "?",
        };
    }
};

pub const GitChangedFile = struct {
    path: []const u8,
    old_path: ?[]const u8 = null,
    kind: GitChangeKind,
};

pub const DiffLineKind = enum {
    context,
    added,
    removed,
    header,
    metadata,
};

pub const DiffLine = struct {
    kind: DiffLineKind,
    text: []const u8,
    old_line: ?usize = null,
    new_line: ?usize = null,
};

pub const DiffHunk = struct {
    old_start: usize,
    old_count: usize,
    new_start: usize,
    new_count: usize,
    lines: std.ArrayListUnmanaged(DiffLine) = .empty,
};

pub const FileDiff = struct {
    path: []const u8,
    old_path: ?[]const u8 = null,
    kind: GitChangeKind = .modified,
    metadata: std.ArrayListUnmanaged([]const u8) = .empty,
    hunks: std.ArrayListUnmanaged(DiffHunk) = .empty,
    binary: bool = false,
};

pub const WorkspaceDiff = struct {
    repo_root: []const u8,
    files: std.ArrayListUnmanaged(FileDiff) = .empty,
    truncated: bool = false,
};

pub const RenderRowKind = enum {
    summary,
    separator,
    file_header,
    hunk_header,
    diff_line,
    metadata,
    message,
    truncation,
};

pub const RenderRow = struct {
    kind: RenderRowKind,
    text: []const u8,
    file_path: ?[]const u8 = null,
    change_kind: ?GitChangeKind = null,
    line_kind: ?DiffLineKind = null,
    new_line: ?usize = null,
};

const StatusEntry = struct {
    path: []const u8,
    old_path: ?[]const u8 = null,
    kind: GitChangeKind,
};

const HunkHeader = struct {
    old_start: usize,
    old_count: usize,
    new_start: usize,
    new_count: usize,
};

pub const GitDiffPanel = struct {
    visible: bool = false,
    repo_root: ?[]const u8 = null,
    files: std.ArrayListUnmanaged(FileDiff) = .empty,
    rows: std.ArrayListUnmanaged(RenderRow) = .empty,
    selected_index: usize = 0,
    scroll_offset: usize = 0,
    loading: bool = false,
    error_message: ?[]const u8 = null,
    truncated: bool = false,
    pending_sequence: keybindings.KeySequence = .{},
    arena: std.heap.ArenaAllocator,

    pub fn init(allocator: std.mem.Allocator) GitDiffPanel {
        return .{ .arena = std.heap.ArenaAllocator.init(allocator) };
    }

    pub fn deinit(self: *GitDiffPanel) void {
        const child_allocator = self.arena.child_allocator;
        self.arena.deinit();
        self.* = init(child_allocator);
    }

    pub fn close(self: *GitDiffPanel) void {
        _ = self.arena.reset(.retain_capacity);
        self.visible = false;
        self.repo_root = null;
        self.files = .empty;
        self.rows = .empty;
        self.selected_index = 0;
        self.scroll_offset = 0;
        self.loading = false;
        self.error_message = null;
        self.truncated = false;
        self.pending_sequence.clear();
    }

    pub fn open(self: *GitDiffPanel, allocator: std.mem.Allocator, io: std.Io, context: OpenContext) !void {
        self.close();
        const root = findRepositoryRoot(allocator, io, context) catch |err| switch (err) {
            error.NotGitRepository => {
                self.visible = true;
                self.error_message = "This workspace is not a Git repository.";
                try self.rebuildRows();
                return;
            },
            else => return err,
        };
        defer allocator.free(root);

        self.visible = true;
        try self.refreshFromRoot(allocator, io, root);
    }

    pub fn refresh(self: *GitDiffPanel, allocator: std.mem.Allocator, io: std.Io) !void {
        const root = self.repo_root orelse return Error.NotGitRepository;
        const owned_root = try allocator.dupe(u8, root);
        defer allocator.free(owned_root);
        try self.refreshFromRoot(allocator, io, owned_root);
    }

    pub fn refreshFromRoot(self: *GitDiffPanel, allocator: std.mem.Allocator, io: std.Io, root: []const u8) !void {
        _ = self.arena.reset(.retain_capacity);
        self.repo_root = null;
        self.files = .empty;
        self.rows = .empty;
        self.selected_index = 0;
        self.scroll_offset = 0;
        self.error_message = null;
        self.truncated = false;
        self.pending_sequence.clear();
        self.loading = true;
        defer self.loading = false;

        const arena_allocator = self.arena.allocator();
        self.repo_root = try arena_allocator.dupe(u8, root);

        const diff = loadWorkspaceDiff(arena_allocator, allocator, io, root) catch |err| switch (err) {
            error.OutOfMemory => return err,
            error.NotGitRepository => {
                self.error_message = "This workspace is not a Git repository.";
                try self.rebuildRows();
                return;
            },
            error.FileNotFound => {
                self.error_message = "Unable to load git diff: git not found";
                try self.rebuildRows();
                return;
            },
            error.StreamTooLong => {
                self.error_message = "Unable to load git diff: output too large";
                try self.rebuildRows();
                return;
            },
            else => {
                self.error_message = "Unable to load git diff";
                try self.rebuildRows();
                return;
            },
        };

        self.repo_root = diff.repo_root;
        self.files = diff.files;
        self.truncated = diff.truncated;
        try self.rebuildRows();
    }

    pub fn moveUp(self: *GitDiffPanel) void {
        if (self.selected_index == 0) return;
        self.selected_index -= 1;
    }

    pub fn moveDown(self: *GitDiffPanel) void {
        if (self.rows.items.len == 0) return;
        self.selected_index = @min(self.selected_index + 1, self.rows.items.len - 1);
    }

    pub fn pageUp(self: *GitDiffPanel, amount: usize) void {
        self.selected_index -|= @max(amount, 1);
    }

    pub fn pageDown(self: *GitDiffPanel, amount: usize) void {
        if (self.rows.items.len == 0) return;
        self.selected_index = @min(self.selected_index + @max(amount, 1), self.rows.items.len - 1);
    }

    pub fn adjustScroll(self: *GitDiffPanel, body_rows: usize) void {
        if (body_rows == 0 or self.rows.items.len == 0) {
            self.scroll_offset = 0;
            return;
        }
        if (self.scroll_offset >= self.rows.items.len) self.scroll_offset = self.rows.items.len - 1;
        if (self.selected_index < self.scroll_offset) {
            self.scroll_offset = self.selected_index;
        } else if (self.selected_index >= self.scroll_offset + body_rows) {
            self.scroll_offset = self.selected_index - body_rows + 1;
        }
    }

    pub fn selectedRow(self: *const GitDiffPanel) ?RenderRow {
        if (self.selected_index >= self.rows.items.len) return null;
        return self.rows.items[self.selected_index];
    }

    pub fn fileCount(self: *const GitDiffPanel) usize {
        return self.files.items.len;
    }

    fn rebuildRows(self: *GitDiffPanel) !void {
        const allocator = self.arena.allocator();
        self.rows = .empty;

        if (self.error_message) |message| {
            try self.rows.append(allocator, .{ .kind = .message, .text = message });
            return;
        }

        if (self.files.items.len == 0) {
            try self.rows.append(allocator, .{ .kind = .message, .text = "No git changes in this workspace." });
            return;
        }

        for (self.files.items) |file| {
            const text = if (file.old_path) |old_path|
                try std.fmt.allocPrint(allocator, "{s} {s} -> {s}", .{ file.kind.label(), old_path, file.path })
            else
                try std.fmt.allocPrint(allocator, "{s} {s}", .{ file.kind.label(), file.path });
            try self.rows.append(allocator, .{
                .kind = .summary,
                .text = text,
                .file_path = file.path,
                .change_kind = file.kind,
            });
        }

        try self.rows.append(allocator, .{ .kind = .separator, .text = "" });

        for (self.files.items) |file| {
            const header = if (file.old_path) |old_path|
                try std.fmt.allocPrint(allocator, "{s} -> {s}", .{ old_path, file.path })
            else
                file.path;
            try self.rows.append(allocator, .{
                .kind = .file_header,
                .text = header,
                .file_path = file.path,
                .change_kind = file.kind,
            });

            if (file.metadata.items.len > 0) {
                for (file.metadata.items) |line| {
                    try self.rows.append(allocator, .{
                        .kind = .metadata,
                        .text = line,
                        .file_path = file.path,
                        .change_kind = file.kind,
                        .line_kind = .metadata,
                    });
                }
            }

            if (file.hunks.items.len == 0 and !file.binary) {
                const message = switch (file.kind) {
                    .untracked => "Untracked file. Open file to inspect contents.",
                    .deleted => "Deleted file. No working-tree content to open.",
                    else => "No unstaged text diff for this file.",
                };
                try self.rows.append(allocator, .{
                    .kind = .metadata,
                    .text = message,
                    .file_path = file.path,
                    .change_kind = file.kind,
                    .line_kind = .metadata,
                });
            }

            for (file.hunks.items) |hunk| {
                const hunk_text = try std.fmt.allocPrint(allocator, "@@ -{d},{d} +{d},{d} @@", .{
                    hunk.old_start,
                    hunk.old_count,
                    hunk.new_start,
                    hunk.new_count,
                });
                try self.rows.append(allocator, .{
                    .kind = .hunk_header,
                    .text = hunk_text,
                    .file_path = file.path,
                    .change_kind = file.kind,
                    .line_kind = .header,
                    .new_line = hunk.new_start,
                });
                for (hunk.lines.items) |line| {
                    try self.rows.append(allocator, .{
                        .kind = .diff_line,
                        .text = line.text,
                        .file_path = file.path,
                        .change_kind = file.kind,
                        .line_kind = line.kind,
                        .new_line = line.new_line,
                    });
                }
            }
        }

        if (self.truncated) {
            try self.rows.append(allocator, .{
                .kind = .truncation,
                .text = "Diff truncated at 20000 lines.",
            });
        }
    }
};

pub fn findRepositoryRoot(allocator: std.mem.Allocator, io: std.Io, context: OpenContext) ![]u8 {
    if (context.project_root) |root| {
        if (findRepositoryRootFromStart(allocator, io, root)) |found| return found else |err| switch (err) {
            error.NotGitRepository => {},
            else => return err,
        }
    }
    if (context.explorer_root) |root| {
        if (findRepositoryRootFromStart(allocator, io, root)) |found| return found else |err| switch (err) {
            error.NotGitRepository => {},
            else => return err,
        }
    }
    if (context.current_file) |filename| {
        const dir = std.fs.path.dirname(filename) orelse ".";
        if (findRepositoryRootFromStart(allocator, io, dir)) |found| return found else |err| switch (err) {
            error.NotGitRepository => {},
            else => return err,
        }
    }
    return findRepositoryRootFromStart(allocator, io, ".");
}

pub fn findRepositoryRootFromStart(allocator: std.mem.Allocator, io: std.Io, start_path: []const u8) ![]u8 {
    var repo = (try repository.discover(allocator, io, start_path)) orelse return Error.NotGitRepository;
    defer repo.deinit(allocator);
    return allocator.dupe(u8, repo.root);
}

fn loadWorkspaceDiff(arena_allocator: std.mem.Allocator, scratch_allocator: std.mem.Allocator, io: std.Io, root: []const u8) !WorkspaceDiff {
    var repo = (try repository.discover(scratch_allocator, io, root)) orelse return Error.NotGitRepository;
    defer repo.deinit(scratch_allocator);

    const status_output = try runGit(scratch_allocator, io, repo.root, &.{ "status", "--porcelain=v1", "-z", "--", "." }, 1024 * 1024, 64 * 1024);
    defer scratch_allocator.free(status_output);

    var status_entries = std.ArrayListUnmanaged(StatusEntry).empty;
    defer status_entries.deinit(scratch_allocator);
    try parseStatus(arena_allocator, scratch_allocator, status_output, &status_entries);

    const patch = try runGit(scratch_allocator, io, repo.root, &.{ "diff", "--no-ext-diff", "--unified=3", "--", "." }, 8 * 1024 * 1024, 256 * 1024);
    defer scratch_allocator.free(patch);

    var diff = WorkspaceDiff{
        .repo_root = try arena_allocator.dupe(u8, repo.root),
    };
    try parseUnifiedDiff(arena_allocator, patch, &diff);

    for (diff.files.items) |*file| {
        if (findStatus(status_entries.items, file.path)) |status| {
            file.kind = status.kind;
            if (file.old_path == null) file.old_path = status.old_path;
        }
    }

    for (status_entries.items) |entry| {
        if (findFile(diff.files.items, entry.path) != null) continue;
        var file = FileDiff{
            .path = entry.path,
            .old_path = entry.old_path,
            .kind = entry.kind,
        };
        if (entry.kind == .untracked) {
            try file.metadata.append(arena_allocator, "Untracked file. Open file to inspect contents.");
        }
        try diff.files.append(arena_allocator, file);
    }

    return diff;
}

fn runGit(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    args: []const []const u8,
    stdout_limit: usize,
    stderr_limit: usize,
) ![]u8 {
    var argv = std.ArrayListUnmanaged([]const u8).empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{ "git", "-C", root });
    try argv.appendSlice(allocator, args);

    const result = try std.process.run(allocator, io, .{
        .argv = argv.items,
        .stdout_limit = std.Io.Limit.limited(stdout_limit),
        .stderr_limit = std.Io.Limit.limited(stderr_limit),
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

fn parseStatus(
    arena_allocator: std.mem.Allocator,
    scratch_allocator: std.mem.Allocator,
    output: []const u8,
    entries: *std.ArrayListUnmanaged(StatusEntry),
) !void {
    var it = std.mem.splitScalar(u8, output, 0);
    while (it.next()) |entry| {
        if (entry.len == 0) continue;
        if (entry.len < 4) continue;
        if (std.mem.startsWith(u8, entry, "## ")) continue;

        const kind = changeKindFromStatus(entry[0..2]) orelse continue;
        const path = entry[3..];
        if (kind == .renamed) {
            const old_path = it.next() orelse "";
            try entries.append(scratch_allocator, .{
                .path = try arena_allocator.dupe(u8, path),
                .old_path = if (old_path.len > 0) try arena_allocator.dupe(u8, old_path) else null,
                .kind = kind,
            });
        } else {
            try entries.append(scratch_allocator, .{
                .path = try arena_allocator.dupe(u8, path),
                .kind = kind,
            });
        }
    }
}

fn changeKindFromStatus(status: []const u8) ?GitChangeKind {
    if (status.len < 2) return null;
    if (status[0] == '?' and status[1] == '?') return .untracked;
    if (status[0] == 'R' or status[1] == 'R') return .renamed;
    if (status[0] == 'A' or status[1] == 'A') return .added;
    if (status[0] == 'D' or status[1] == 'D') return .deleted;
    if (status[0] != ' ' or status[1] != ' ') return .modified;
    return null;
}

fn findStatus(entries: []const StatusEntry, path: []const u8) ?StatusEntry {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.path, path)) return entry;
    }
    return null;
}

fn findFile(files: []const FileDiff, path: []const u8) ?usize {
    for (files, 0..) |file, index| {
        if (std.mem.eql(u8, file.path, path)) return index;
    }
    return null;
}

pub fn parseUnifiedDiff(allocator: std.mem.Allocator, patch: []const u8, diff: *WorkspaceDiff) !void {
    var current_file: ?*FileDiff = null;
    var current_hunk: ?*DiffHunk = null;
    var old_line: usize = 0;
    var new_line: usize = 0;
    var diff_line_count: usize = 0;

    var it = std.mem.splitScalar(u8, patch, '\n');
    while (it.next()) |raw| {
        var line = raw;
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];

        if (std.mem.startsWith(u8, line, "diff --git ")) {
            const parsed = parseDiffGitLine(line);
            try diff.files.append(allocator, .{
                .path = try allocator.dupe(u8, parsed.path),
                .old_path = if (parsed.old_path) |old| try allocator.dupe(u8, old) else null,
                .kind = .modified,
            });
            current_file = &diff.files.items[diff.files.items.len - 1];
            current_hunk = null;
            continue;
        }

        const file = current_file orelse continue;

        if (std.mem.startsWith(u8, line, "new file mode")) {
            file.kind = .added;
            try file.metadata.append(allocator, try allocator.dupe(u8, line));
            continue;
        }
        if (std.mem.startsWith(u8, line, "deleted file mode")) {
            file.kind = .deleted;
            try file.metadata.append(allocator, try allocator.dupe(u8, line));
            continue;
        }
        if (std.mem.startsWith(u8, line, "rename from ")) {
            file.kind = .renamed;
            file.old_path = try allocator.dupe(u8, line["rename from ".len..]);
            try file.metadata.append(allocator, try allocator.dupe(u8, line));
            continue;
        }
        if (std.mem.startsWith(u8, line, "rename to ")) {
            file.kind = .renamed;
            file.path = try allocator.dupe(u8, line["rename to ".len..]);
            try file.metadata.append(allocator, try allocator.dupe(u8, line));
            continue;
        }
        if (std.mem.startsWith(u8, line, "Binary files ")) {
            file.binary = true;
            try file.metadata.append(allocator, try allocator.dupe(u8, line));
            continue;
        }

        if (std.mem.startsWith(u8, line, "--- ") or std.mem.startsWith(u8, line, "+++ ") or
            std.mem.startsWith(u8, line, "index ") or std.mem.startsWith(u8, line, "similarity index "))
        {
            if (std.mem.startsWith(u8, line, "+++ b/")) {
                file.path = try allocator.dupe(u8, line["+++ b/".len..]);
            } else if (std.mem.startsWith(u8, line, "--- a/")) {
                if (file.old_path == null) file.old_path = try allocator.dupe(u8, line["--- a/".len..]);
            }
            try file.metadata.append(allocator, try allocator.dupe(u8, line));
            continue;
        }

        if (std.mem.startsWith(u8, line, "@@ ")) {
            const header = parseHunkHeader(line) catch continue;
            try file.hunks.append(allocator, .{
                .old_start = header.old_start,
                .old_count = header.old_count,
                .new_start = header.new_start,
                .new_count = header.new_count,
            });
            current_hunk = &file.hunks.items[file.hunks.items.len - 1];
            old_line = header.old_start;
            new_line = header.new_start;
            continue;
        }

        const hunk = current_hunk orelse continue;
        if (diff_line_count >= max_diff_lines) {
            diff.truncated = true;
            continue;
        }

        const parsed_line = parseDiffLine(allocator, line, &old_line, &new_line) orelse continue;
        try hunk.lines.append(allocator, parsed_line);
        diff_line_count += 1;
    }
}

fn parseDiffLine(allocator: std.mem.Allocator, line: []const u8, old_line: *usize, new_line: *usize) ?DiffLine {
    if (line.len == 0) return .{
        .kind = .context,
        .text = allocator.dupe(u8, " ") catch return null,
        .old_line = old_line.*,
        .new_line = new_line.*,
    };

    return switch (line[0]) {
        ' ' => blk: {
            const result = DiffLine{
                .kind = .context,
                .text = allocator.dupe(u8, line) catch return null,
                .old_line = old_line.*,
                .new_line = new_line.*,
            };
            old_line.* += 1;
            new_line.* += 1;
            break :blk result;
        },
        '+' => blk: {
            const result = DiffLine{
                .kind = .added,
                .text = allocator.dupe(u8, line) catch return null,
                .new_line = new_line.*,
            };
            new_line.* += 1;
            break :blk result;
        },
        '-' => blk: {
            const result = DiffLine{
                .kind = .removed,
                .text = allocator.dupe(u8, line) catch return null,
                .old_line = old_line.*,
            };
            old_line.* += 1;
            break :blk result;
        },
        '\\' => .{
            .kind = .metadata,
            .text = allocator.dupe(u8, line) catch return null,
        },
        else => null,
    };
}

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

fn parseDiffGitLine(line: []const u8) struct { old_path: ?[]const u8, path: []const u8 } {
    const rest = line["diff --git ".len..];
    const marker = std.mem.indexOf(u8, rest, " b/") orelse return .{ .old_path = null, .path = rest };
    const old = rest[0..marker];
    const new = rest[marker + 3 ..];
    return .{
        .old_path = if (std.mem.startsWith(u8, old, "a/")) old[2..] else old,
        .path = new,
    };
}

test "workspace diff parser handles a simple modified file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var diff = WorkspaceDiff{ .repo_root = "/repo" };

    try parseUnifiedDiff(allocator,
        \\diff --git a/src/main.zig b/src/main.zig
        \\index 1111111..2222222 100644
        \\--- a/src/main.zig
        \\+++ b/src/main.zig
        \\@@ -1,3 +1,3 @@
        \\ const a = 1;
        \\-const b = 2;
        \\+const b = 3;
        \\ const c = 4;
        \\
    , &diff);

    try std.testing.expectEqual(@as(usize, 1), diff.files.items.len);
    try std.testing.expectEqualStrings("src/main.zig", diff.files.items[0].path);
    try std.testing.expectEqual(@as(usize, 1), diff.files.items[0].hunks.items.len);
    try std.testing.expectEqual(DiffLineKind.removed, diff.files.items[0].hunks.items[0].lines.items[1].kind);
    try std.testing.expectEqual(DiffLineKind.added, diff.files.items[0].hunks.items[0].lines.items[2].kind);
    try std.testing.expectEqual(@as(usize, 2), diff.files.items[0].hunks.items[0].lines.items[2].new_line.?);
}

test "workspace diff parser handles added and removed lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var diff = WorkspaceDiff{ .repo_root = "/repo" };

    try parseUnifiedDiff(allocator,
        \\diff --git a/file.txt b/file.txt
        \\--- a/file.txt
        \\+++ b/file.txt
        \\@@ -1,2 +1,3 @@
        \\-old
        \\+new
        \\+extra
        \\
    , &diff);

    const lines = diff.files.items[0].hunks.items[0].lines.items;
    try std.testing.expectEqual(DiffLineKind.removed, lines[0].kind);
    try std.testing.expectEqual(DiffLineKind.added, lines[1].kind);
    try std.testing.expectEqual(DiffLineKind.added, lines[2].kind);
}

test "workspace diff parser handles multiple hunks in one file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var diff = WorkspaceDiff{ .repo_root = "/repo" };

    try parseUnifiedDiff(allocator,
        \\diff --git a/file.txt b/file.txt
        \\--- a/file.txt
        \\+++ b/file.txt
        \\@@ -1 +1 @@
        \\-one
        \\+two
        \\@@ -10 +10 @@
        \\-ten
        \\+eleven
        \\
    , &diff);

    try std.testing.expectEqual(@as(usize, 2), diff.files.items[0].hunks.items.len);
    try std.testing.expectEqual(@as(usize, 10), diff.files.items[0].hunks.items[1].new_start);
}

test "workspace diff parser handles multiple files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var diff = WorkspaceDiff{ .repo_root = "/repo" };

    try parseUnifiedDiff(allocator,
        \\diff --git a/a.txt b/a.txt
        \\--- a/a.txt
        \\+++ b/a.txt
        \\@@ -1 +1 @@
        \\-a
        \\+b
        \\diff --git a/b.txt b/b.txt
        \\--- a/b.txt
        \\+++ b/b.txt
        \\@@ -1 +1 @@
        \\-c
        \\+d
        \\
    , &diff);

    try std.testing.expectEqual(@as(usize, 2), diff.files.items.len);
    try std.testing.expectEqualStrings("a.txt", diff.files.items[0].path);
    try std.testing.expectEqualStrings("b.txt", diff.files.items[1].path);
}

test "workspace diff parser handles empty diff output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var diff = WorkspaceDiff{ .repo_root = "/repo" };

    try parseUnifiedDiff(allocator, "", &diff);
    try std.testing.expectEqual(@as(usize, 0), diff.files.items.len);
}

test "workspace diff parser records binary placeholder metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var diff = WorkspaceDiff{ .repo_root = "/repo" };

    try parseUnifiedDiff(allocator,
        \\diff --git a/image.png b/image.png
        \\index 1111111..2222222 100644
        \\Binary files a/image.png and b/image.png differ
        \\
    , &diff);

    try std.testing.expect(diff.files.items[0].binary);
    try std.testing.expectEqual(@as(usize, 1), diff.files.items[0].metadata.items.len);
}
