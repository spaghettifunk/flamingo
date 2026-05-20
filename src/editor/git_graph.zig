const std = @import("std");
const keybindings = @import("keybindings.zig");

const unit_sep: u8 = 0x1f;
const record_sep: u8 = 0x1e;
pub const max_commits: usize = 500;

pub const Error = error{
    NotGitRepository,
};

pub const OpenContext = struct {
    project_root: ?[]const u8 = null,
    explorer_root: ?[]const u8 = null,
    current_file: ?[]const u8 = null,
};

pub const GitRefKind = enum {
    head,
    local_branch,
    remote_branch,
    tag,
    other,
};

pub const GitRefLabel = struct {
    kind: GitRefKind,
    name: []const u8,
};

pub const GitCommitRow = struct {
    graph_prefix: []const u8,
    short_hash: []const u8,
    full_hash: []const u8,
    refs_raw: []const u8,
    refs: []const GitRefLabel,
    author: []const u8,
    date: []const u8,
    subject: []const u8,

    pub fn primaryLabel(self: *const GitCommitRow) GitRefLabel {
        const preference = [_]GitRefKind{ .head, .local_branch, .tag, .remote_branch, .other };
        for (preference) |kind| {
            for (self.refs) |label| {
                if (label.kind == kind) return label;
            }
        }
        return .{ .kind = .other, .name = self.short_hash };
    }
};

pub const GitContinuationRow = struct {
    graph_prefix: []const u8,
};

pub const GitGraphLine = union(enum) {
    commit: GitCommitRow,
    continuation: GitContinuationRow,
};

pub const GitGraphPanel = struct {
    visible: bool = false,
    repo_root: ?[]const u8 = null,
    current_branch: ?[]const u8 = null,
    rows: std.ArrayListUnmanaged(GitGraphLine) = .empty,
    selected_index: usize = 0,
    scroll_offset: usize = 0,
    loading: bool = false,
    error_message: ?[]const u8 = null,
    show_details: bool = false,
    pending_sequence: keybindings.KeySequence = .{},
    arena: std.heap.ArenaAllocator,

    pub fn init(allocator: std.mem.Allocator) GitGraphPanel {
        return .{ .arena = std.heap.ArenaAllocator.init(allocator) };
    }

    pub fn deinit(self: *GitGraphPanel) void {
        const child_allocator = self.arena.child_allocator;
        self.arena.deinit();
        self.* = init(child_allocator);
    }

    pub fn close(self: *GitGraphPanel) void {
        _ = self.arena.reset(.retain_capacity);
        self.visible = false;
        self.repo_root = null;
        self.current_branch = null;
        self.rows = .empty;
        self.selected_index = 0;
        self.scroll_offset = 0;
        self.loading = false;
        self.error_message = null;
        self.show_details = false;
        self.pending_sequence.clear();
    }

    pub fn open(self: *GitGraphPanel, allocator: std.mem.Allocator, io: std.Io, context: OpenContext) !void {
        self.close();
        const root = findRepositoryRoot(allocator, io, context) catch |err| switch (err) {
            error.NotGitRepository => {
                self.error_message = "Not a Git repository";
                return err;
            },
            else => return err,
        };
        defer allocator.free(root);

        self.visible = true;
        try self.refreshFromRoot(allocator, io, root);
    }

    pub fn refresh(self: *GitGraphPanel, allocator: std.mem.Allocator, io: std.Io) !void {
        const root = self.repo_root orelse return Error.NotGitRepository;
        const owned_root = try allocator.dupe(u8, root);
        defer allocator.free(owned_root);
        try self.refreshFromRoot(allocator, io, owned_root);
    }

    pub fn refreshFromRoot(self: *GitGraphPanel, allocator: std.mem.Allocator, io: std.Io, root: []const u8) !void {
        _ = self.arena.reset(.retain_capacity);
        self.rows = .empty;
        self.repo_root = null;
        self.current_branch = null;
        self.error_message = null;
        self.show_details = false;
        self.pending_sequence.clear();
        self.loading = true;
        defer self.loading = false;

        const arena_allocator = self.arena.allocator();
        const canonical_root = canonicalizeRepositoryRoot(allocator, io, root) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                self.repo_root = try arena_allocator.dupe(u8, root);
                self.error_message = try arena_allocator.dupe(u8, friendlyProcessError(err));
                return;
            },
        };
        defer allocator.free(canonical_root);
        self.repo_root = try arena_allocator.dupe(u8, canonical_root);
        if (loadCurrentBranch(allocator, io, canonical_root)) |maybe_branch| {
            if (maybe_branch) |branch| {
                defer allocator.free(branch);
                self.current_branch = try arena_allocator.dupe(u8, branch);
            }
        } else |err| switch (err) {
            error.OutOfMemory => return err,
            else => {},
        }

        const result = std.process.run(allocator, io, .{
            .argv = &.{
                "git",
                "-C",
                canonical_root,
                "log",
                "--graph",
                "--decorate=short",
                "--date=short",
                "--pretty=format:%x1f%h%x1f%H%x1f%D%x1f%an%x1f%ad%x1f%s%x1e",
                "--all",
                "--max-count=500",
            },
            .stdout_limit = std.Io.Limit.limited(4 * 1024 * 1024),
            .stderr_limit = std.Io.Limit.limited(256 * 1024),
        }) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                self.error_message = try arena_allocator.dupe(u8, friendlyProcessError(err));
                return;
            },
        };
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        switch (result.term) {
            .exited => |code| {
                if (code != 0) {
                    if (isEmptyRepositoryMessage(result.stderr)) {
                        self.clampSelection();
                        return;
                    }
                    const message = std.mem.trim(u8, result.stderr, " \t\r\n");
                    self.error_message = try arena_allocator.dupe(u8, if (message.len > 0) message else "Could not load Git history");
                    return;
                }
            },
            else => {
                self.error_message = "Could not load Git history";
                return;
            },
        }

        try parseLogOutput(arena_allocator, result.stdout, &self.rows);
        self.clampSelection();
    }

    pub fn commitCount(self: *const GitGraphPanel) usize {
        var count: usize = 0;
        for (self.rows.items) |line| {
            switch (line) {
                .commit => count += 1,
                .continuation => {},
            }
        }
        return count;
    }

    pub fn selectedCommit(self: *const GitGraphPanel) ?*const GitCommitRow {
        if (self.selected_index >= self.rows.items.len) return null;
        return switch (self.rows.items[self.selected_index]) {
            .commit => |*commit| commit,
            .continuation => null,
        };
    }

    pub fn selectedIsCommit(self: *const GitGraphPanel) bool {
        return self.selectedCommit() != null;
    }

    pub fn moveUp(self: *GitGraphPanel) void {
        if (self.selected_index == 0) return;
        var index = self.selected_index;
        while (index > 0) {
            index -= 1;
            if (self.isCommitIndex(index)) {
                self.selected_index = index;
                self.show_details = false;
                return;
            }
        }
    }

    pub fn moveDown(self: *GitGraphPanel) void {
        if (self.rows.items.len == 0) return;
        var index = self.selected_index + 1;
        while (index < self.rows.items.len) : (index += 1) {
            if (self.isCommitIndex(index)) {
                self.selected_index = index;
                self.show_details = false;
                return;
            }
        }
    }

    pub fn pageUp(self: *GitGraphPanel, amount: usize) void {
        var remaining = @max(amount, 1);
        while (remaining > 0) : (remaining -= 1) self.moveUp();
    }

    pub fn pageDown(self: *GitGraphPanel, amount: usize) void {
        var remaining = @max(amount, 1);
        while (remaining > 0) : (remaining -= 1) self.moveDown();
    }

    pub fn firstCommit(self: *GitGraphPanel) void {
        if (self.firstCommitIndexFrom(0, .forward)) |index| {
            self.selected_index = index;
            self.show_details = false;
        }
    }

    pub fn lastCommit(self: *GitGraphPanel) void {
        if (self.rows.items.len == 0) return;
        if (self.firstCommitIndexFrom(self.rows.items.len - 1, .backward)) |index| {
            self.selected_index = index;
            self.show_details = false;
        }
    }

    pub fn toggleDetails(self: *GitGraphPanel) bool {
        if (!self.selectedIsCommit()) return false;
        self.show_details = !self.show_details;
        return true;
    }

    pub fn adjustScroll(self: *GitGraphPanel, body_rows: usize) void {
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

    pub fn clampSelection(self: *GitGraphPanel) void {
        if (self.rows.items.len == 0) {
            self.selected_index = 0;
            self.scroll_offset = 0;
            self.show_details = false;
            return;
        }
        self.selected_index = @min(self.selected_index, self.rows.items.len - 1);
        if (self.isCommitIndex(self.selected_index)) return;
        if (self.firstCommitIndexFrom(self.selected_index, .forward)) |index| {
            self.selected_index = index;
        } else if (self.firstCommitIndexFrom(self.selected_index, .backward)) |index| {
            self.selected_index = index;
        } else {
            self.selected_index = 0;
            self.show_details = false;
        }
    }

    fn isCommitIndex(self: *const GitGraphPanel, index: usize) bool {
        if (index >= self.rows.items.len) return false;
        return switch (self.rows.items[index]) {
            .commit => true,
            .continuation => false,
        };
    }

    const SearchDirection = enum { forward, backward };

    fn firstCommitIndexFrom(self: *const GitGraphPanel, start: usize, direction: SearchDirection) ?usize {
        if (self.rows.items.len == 0) return null;
        var index = @min(start, self.rows.items.len - 1);
        while (true) {
            if (self.isCommitIndex(index)) return index;
            switch (direction) {
                .forward => {
                    index += 1;
                    if (index >= self.rows.items.len) return null;
                },
                .backward => {
                    if (index == 0) return null;
                    index -= 1;
                },
            }
        }
    }
};

fn friendlyProcessError(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "Git executable not found",
        else => "Could not run git",
    };
}

fn isEmptyRepositoryMessage(stderr: []const u8) bool {
    return std.mem.indexOf(u8, stderr, "does not have any commits") != null or
        std.mem.indexOf(u8, stderr, "bad default revision") != null;
}

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

fn realPathOwned(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    const real_path_z = try std.Io.Dir.cwd().realPathFileAlloc(io, path, allocator);
    defer allocator.free(real_path_z);
    return allocator.dupe(u8, real_path_z);
}

pub fn findRepositoryRootFromStart(allocator: std.mem.Allocator, io: std.Io, start_path: []const u8) ![]u8 {
    var current = realPathOwned(allocator, io, start_path) catch try allocator.dupe(u8, start_path);
    defer allocator.free(current);

    while (true) {
        if (try hasGitMarker(allocator, io, current)) {
            return allocator.dupe(u8, current);
        }
        const parent = std.fs.path.dirname(current) orelse break;
        if (std.mem.eql(u8, parent, current)) break;
        const owned_parent = try allocator.dupe(u8, parent);
        allocator.free(current);
        current = owned_parent;
    }
    return Error.NotGitRepository;
}

fn hasGitMarker(allocator: std.mem.Allocator, io: std.Io, root: []const u8) !bool {
    const marker = try std.fs.path.join(allocator, &.{ root, ".git" });
    defer allocator.free(marker);

    const stat = std.Io.Dir.cwd().statFile(io, marker, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return false,
    };
    if (stat.kind == .directory) return true;
    if (stat.kind != .file) return false;

    const contents = std.Io.Dir.cwd().readFileAlloc(io, marker, allocator, std.Io.Limit.limited(4096)) catch return false;
    defer allocator.free(contents);
    const trimmed = std.mem.trim(u8, contents, " \t\r\n");
    return std.mem.startsWith(u8, trimmed, "gitdir:");
}

fn canonicalizeRepositoryRoot(allocator: std.mem.Allocator, io: std.Io, root: []const u8) ![]u8 {
    const result = try std.process.run(allocator, io, .{
        .argv = &.{ "git", "-C", root, "rev-parse", "--show-toplevel" },
        .stdout_limit = std.Io.Limit.limited(16 * 1024),
        .stderr_limit = std.Io.Limit.limited(16 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.GitCommandFailed,
        else => return error.GitCommandFailed,
    }
    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (trimmed.len == 0) return error.GitCommandFailed;
    return allocator.dupe(u8, trimmed);
}

fn loadCurrentBranch(allocator: std.mem.Allocator, io: std.Io, root: []const u8) !?[]u8 {
    const result = try std.process.run(allocator, io, .{
        .argv = &.{ "git", "-C", root, "branch", "--show-current" },
        .stdout_limit = std.Io.Limit.limited(16 * 1024),
        .stderr_limit = std.Io.Limit.limited(16 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return null,
        else => return null,
    }
    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (trimmed.len == 0) return null;
    return try allocator.dupe(u8, trimmed);
}

pub fn parseLogOutput(allocator: std.mem.Allocator, output: []const u8, rows: *std.ArrayListUnmanaged(GitGraphLine)) !void {
    var line_it = std.mem.splitScalar(u8, output, '\n');
    while (line_it.next()) |raw_line| {
        var line = raw_line;
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        if (line.len == 0) continue;

        const first_sep = std.mem.indexOfScalar(u8, line, unit_sep) orelse {
            if (lineHasGraphContent(line)) {
                try rows.append(allocator, .{ .continuation = .{
                    .graph_prefix = try allocator.dupe(u8, line),
                } });
            }
            continue;
        };

        const graph_prefix = try allocator.dupe(u8, line[0..first_sep]);
        var rest = line[first_sep + 1 ..];
        const short_hash = takeField(&rest) orelse continue;
        const full_hash = takeField(&rest) orelse continue;
        const refs_raw = takeField(&rest) orelse continue;
        const author = takeField(&rest) orelse continue;
        const date = takeField(&rest) orelse continue;
        const subject = trimRecordSeparator(rest);

        const owned_refs_raw = try allocator.dupe(u8, refs_raw);
        const refs = try parseRefs(allocator, owned_refs_raw);
        try rows.append(allocator, .{ .commit = .{
            .graph_prefix = graph_prefix,
            .short_hash = try allocator.dupe(u8, short_hash),
            .full_hash = try allocator.dupe(u8, full_hash),
            .refs_raw = owned_refs_raw,
            .refs = refs,
            .author = try allocator.dupe(u8, author),
            .date = try allocator.dupe(u8, date),
            .subject = try allocator.dupe(u8, subject),
        } });
    }
}

fn lineHasGraphContent(line: []const u8) bool {
    for (line) |ch| {
        if (!std.ascii.isWhitespace(ch)) return true;
    }
    return false;
}

fn takeField(rest: *[]const u8) ?[]const u8 {
    const sep = std.mem.indexOfScalar(u8, rest.*, unit_sep) orelse return null;
    const field = rest.*[0..sep];
    rest.* = rest.*[sep + 1 ..];
    return field;
}

fn trimRecordSeparator(subject: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, subject, record_sep) orelse subject.len;
    return subject[0..end];
}

pub fn parseRefs(allocator: std.mem.Allocator, refs_raw: []const u8) ![]const GitRefLabel {
    var labels = std.ArrayListUnmanaged(GitRefLabel).empty;
    var it = std.mem.splitScalar(u8, refs_raw, ',');
    while (it.next()) |raw| {
        const item = std.mem.trim(u8, raw, " \t\r\n");
        if (item.len == 0) continue;

        if (std.mem.startsWith(u8, item, "HEAD -> ")) {
            try labels.append(allocator, .{
                .kind = .head,
                .name = try allocator.dupe(u8, std.mem.trim(u8, item["HEAD -> ".len..], " \t\r\n")),
            });
        } else if (std.mem.eql(u8, item, "HEAD")) {
            try labels.append(allocator, .{ .kind = .head, .name = try allocator.dupe(u8, "HEAD") });
        } else if (std.mem.startsWith(u8, item, "tag: ")) {
            try labels.append(allocator, .{
                .kind = .tag,
                .name = try allocator.dupe(u8, std.mem.trim(u8, item["tag: ".len..], " \t\r\n")),
            });
        } else if (std.mem.indexOfScalar(u8, item, '/') != null) {
            try labels.append(allocator, .{ .kind = .remote_branch, .name = try allocator.dupe(u8, item) });
        } else {
            try labels.append(allocator, .{ .kind = .local_branch, .name = try allocator.dupe(u8, item) });
        }
    }
    return labels.toOwnedSlice(allocator);
}

test "git graph parser handles linear history" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var rows = std.ArrayListUnmanaged(GitGraphLine).empty;

    try parseLogOutput(
        allocator,
        "* \x1fabcd123\x1fabcd1234\x1fHEAD -> main\x1fAda\x1f2026-05-20\x1fAdd graph\x1e\n" ++
            "* \x1fbeef456\x1fbeef4567\x1f\x1fAda\x1f2026-05-19\x1fFix parser\x1e\n",
        &rows,
    );

    try std.testing.expectEqual(@as(usize, 2), rows.items.len);
    try std.testing.expectEqualStrings("abcd123", rows.items[0].commit.short_hash);
    try std.testing.expectEqualStrings("Add graph", rows.items[0].commit.subject);
    try std.testing.expectEqual(GitRefKind.head, rows.items[0].commit.refs[0].kind);
    try std.testing.expectEqualStrings("main", rows.items[0].commit.primaryLabel().name);
}

test "git graph parser handles branch merge prefixes and continuations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var rows = std.ArrayListUnmanaged(GitGraphLine).empty;

    try parseLogOutput(
        allocator,
        "*   \x1faaaaaaa\x1faaaaaaaa\x1f\x1fAda\x1f2026-05-20\x1fMerge branch 'feature'\x1e\n" ++
            "|\\  \n" ++
            "| * \x1fbbbbbbb\x1fbbbbbbbb\x1ffeature\x1fGrace\x1f2026-05-19\x1fFeature subject: with punctuation!\x1e\n" ++
            "|/  \n",
        &rows,
    );

    try std.testing.expectEqual(@as(usize, 4), rows.items.len);
    try std.testing.expect(switch (rows.items[1]) {
        .continuation => true,
        .commit => false,
    });
    try std.testing.expectEqualStrings("|\\  ", rows.items[1].continuation.graph_prefix);
    try std.testing.expectEqualStrings("Feature subject: with punctuation!", rows.items[2].commit.subject);
}

test "git graph parser handles multiple refs and subject separators" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var rows = std.ArrayListUnmanaged(GitGraphLine).empty;

    try parseLogOutput(
        allocator,
        "* \x1fcafe001\x1fcafe0011\x1fHEAD -> main, tag: v1.0.0, origin/main\x1fZoë\x1f2026-05-20\x1fSubject with \x1f separator\x1e\n",
        &rows,
    );

    const commit = rows.items[0].commit;
    try std.testing.expectEqual(@as(usize, 3), commit.refs.len);
    try std.testing.expectEqual(GitRefKind.head, commit.refs[0].kind);
    try std.testing.expectEqual(GitRefKind.tag, commit.refs[1].kind);
    try std.testing.expectEqual(GitRefKind.remote_branch, commit.refs[2].kind);
    try std.testing.expectEqualStrings("Subject with \x1f separator", commit.subject);
}

test "git graph parser ignores empty output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var rows = std.ArrayListUnmanaged(GitGraphLine).empty;

    try parseLogOutput(allocator, "", &rows);
    try std.testing.expectEqual(@as(usize, 0), rows.items.len);
}

test "git graph repo detection finds .git directory and nested child" {
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

    const found_root = try findRepositoryRootFromStart(allocator, io, root);
    defer allocator.free(found_root);
    const found_nested = try findRepositoryRootFromStart(allocator, io, nested);
    defer allocator.free(found_nested);

    try std.testing.expect(std.mem.endsWith(u8, found_root, &tmp.sub_path));
    try std.testing.expectEqualStrings(found_root, found_nested);
}

test "git graph repo detection supports .git file worktree metadata" {
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

    const found = try findRepositoryRootFromStart(allocator, io, child);
    defer allocator.free(found);
    try std.testing.expect(std.mem.endsWith(u8, found, &tmp.sub_path));
}

test "git graph repo detection reports no repo" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_parent = try std.Io.Dir.openDirAbsolute(io, "/private/tmp", .{});
    defer tmp_parent.close(io);
    const leaf = try std.fmt.allocPrint(allocator, "flamingo-git-graph-no-repo-{d}", .{std.testing.random_seed});
    defer allocator.free(leaf);
    tmp_parent.deleteTree(io, leaf) catch {};
    try tmp_parent.createDirPath(io, leaf);
    defer tmp_parent.deleteTree(io, leaf) catch {};

    const root = try std.fs.path.join(allocator, &.{ "/private/tmp", leaf });
    defer allocator.free(root);

    try std.testing.expectError(error.NotGitRepository, findRepositoryRootFromStart(allocator, io, root));
}

test "git graph panel selection skips continuation rows and clamps" {
    var panel = GitGraphPanel.init(std.testing.allocator);
    defer panel.deinit();
    const allocator = panel.arena.allocator();

    try parseLogOutput(
        allocator,
        "|\\  \n" ++
            "* \x1faaaaaaa\x1faaaaaaaa\x1f\x1fAda\x1f2026-05-20\x1fFirst\x1e\n" ++
            "| * \x1fbbbbbbb\x1fbbbbbbbb\x1f\x1fAda\x1f2026-05-19\x1fSecond\x1e\n" ++
            "|/  \n",
        &panel.rows,
    );
    panel.clampSelection();
    try std.testing.expectEqual(@as(usize, 1), panel.selected_index);
    panel.moveDown();
    try std.testing.expectEqual(@as(usize, 2), panel.selected_index);
    panel.moveDown();
    try std.testing.expectEqual(@as(usize, 2), panel.selected_index);
    panel.pageUp(10);
    try std.testing.expectEqual(@as(usize, 1), panel.selected_index);
}

test "git graph panel details only toggles commits" {
    var panel = GitGraphPanel.init(std.testing.allocator);
    defer panel.deinit();
    const allocator = panel.arena.allocator();

    try parseLogOutput(allocator, "|\\  \n", &panel.rows);
    panel.clampSelection();
    try std.testing.expect(!panel.toggleDetails());

    try parseLogOutput(allocator, "* \x1faaaaaaa\x1faaaaaaaa\x1f\x1fAda\x1f2026-05-20\x1fFirst\x1e\n", &panel.rows);
    panel.clampSelection();
    try std.testing.expect(panel.toggleDetails());
    try std.testing.expect(panel.show_details);
}
