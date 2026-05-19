const std = @import("std");
const config = @import("../config.zig");
const buffer_mod = @import("model/buffer.zig");
const tab_mod = @import("model/tab.zig");
const workspace = @import("workspace.zig");

pub const unsupported_file_message = "Comments are currently supported only for text and markdown-like files";
pub const missing_author_message = "No comment author configured. Set git user.name or add an author entry to config.toml.";
pub const malformed_json_message = "Cannot load comments.json: invalid JSON";

pub const StoreError = error{
    NoWorkspace,
    InvalidWorkspace,
    MalformedCommentsJson,
};

pub const CommentAuthor = struct {
    name: []u8,
    email: ?[]u8 = null,

    pub fn deinit(self: *CommentAuthor, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.email) |email| allocator.free(email);
        self.* = undefined;
    }

    pub fn clone(self: *const CommentAuthor, allocator: std.mem.Allocator) !CommentAuthor {
        const name = try allocator.dupe(u8, self.name);
        errdefer allocator.free(name);
        const email = if (self.email) |value| try allocator.dupe(u8, value) else null;
        errdefer if (email) |value| allocator.free(value);
        return .{ .name = name, .email = email };
    }
};

pub const CommentAnchor = struct {
    start_line: usize,
    start_col: usize,
    end_line: usize,
    end_col: usize,
    selected_text: []u8,
    context_before: []u8,
    context_after: []u8,

    pub fn deinit(self: *CommentAnchor, allocator: std.mem.Allocator) void {
        allocator.free(self.selected_text);
        allocator.free(self.context_before);
        allocator.free(self.context_after);
        self.* = undefined;
    }

    pub fn clone(self: *const CommentAnchor, allocator: std.mem.Allocator) !CommentAnchor {
        const selected_text = try allocator.dupe(u8, self.selected_text);
        errdefer allocator.free(selected_text);
        const context_before = try allocator.dupe(u8, self.context_before);
        errdefer allocator.free(context_before);
        const context_after = try allocator.dupe(u8, self.context_after);
        errdefer allocator.free(context_after);
        return .{
            .start_line = self.start_line,
            .start_col = self.start_col,
            .end_line = self.end_line,
            .end_col = self.end_col,
            .selected_text = selected_text,
            .context_before = context_before,
            .context_after = context_after,
        };
    }
};

pub const CommentMessage = struct {
    id: []u8,
    author: CommentAuthor,
    body: []u8,
    created_at_unix_ms: i64,
    updated_at_unix_ms: i64,

    pub fn deinit(self: *CommentMessage, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        self.author.deinit(allocator);
        allocator.free(self.body);
        self.* = undefined;
    }
};

pub const ThreadStatus = enum {
    open,

    pub fn label(self: ThreadStatus) []const u8 {
        return switch (self) {
            .open => "open",
        };
    }

    pub fn fromString(_: []const u8) ThreadStatus {
        return .open;
    }
};

pub const CommentThread = struct {
    id: []u8,
    file_path: []u8,
    anchor: CommentAnchor,
    status: ThreadStatus = .open,
    created_at_unix_ms: i64,
    updated_at_unix_ms: i64,
    comments: std.ArrayListUnmanaged(CommentMessage) = .empty,
    stale: bool = false,

    pub fn deinit(self: *CommentThread, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.file_path);
        self.anchor.deinit(allocator);
        for (self.comments.items) |*message| message.deinit(allocator);
        self.comments.deinit(allocator);
        self.* = undefined;
    }
};

pub const CommentStore = struct {
    version: u32 = 1,
    threads: std.ArrayListUnmanaged(CommentThread) = .empty,

    pub fn deinit(self: *CommentStore, allocator: std.mem.Allocator) void {
        self.clear(allocator);
        self.threads.deinit(allocator);
        self.* = .{};
    }

    pub fn clear(self: *CommentStore, allocator: std.mem.Allocator) void {
        for (self.threads.items) |*thread| thread.deinit(allocator);
        self.threads.clearRetainingCapacity();
        self.version = 1;
    }

    pub fn totalRows(self: *const CommentStore) usize {
        var total: usize = 0;
        for (self.threads.items) |thread| total += 1 + thread.comments.items.len;
        return total;
    }
};

pub const PendingNewThread = struct {
    file_path: []u8,
    anchor: CommentAnchor,

    pub fn deinit(self: *PendingNewThread, allocator: std.mem.Allocator) void {
        allocator.free(self.file_path);
        self.anchor.deinit(allocator);
        self.* = undefined;
    }
};

pub const ThreadRef = struct {
    thread_index: usize,
};

pub const MessageRef = struct {
    thread_index: usize,
    message_index: usize,
};

pub const PendingAction = union(enum) {
    none,
    new_thread: PendingNewThread,
    reply: ThreadRef,
    edit: MessageRef,
    delete: MessageRef,

    pub fn deinit(self: *PendingAction, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .new_thread => |*pending| pending.deinit(allocator),
            else => {},
        }
        self.* = .none;
    }
};

pub const SelectedRow = union(enum) {
    thread: usize,
    message: MessageRef,
};

pub const CommentsPanel = struct {
    visible: bool = false,
    focused: bool = false,
    selected_row: usize = 0,
    scroll_offset: usize = 0,
    store: CommentStore = .{},
    load_error: ?[]const u8 = null,
    pending_action: PendingAction = .none,
    next_id_counter: u64 = 0,

    pub fn deinit(self: *CommentsPanel, allocator: std.mem.Allocator) void {
        self.pending_action.deinit(allocator);
        self.store.deinit(allocator);
        self.* = .{};
    }

    pub fn clearLoaded(self: *CommentsPanel, allocator: std.mem.Allocator) void {
        self.store.clear(allocator);
        self.load_error = null;
        self.clampSelection();
    }

    pub fn totalRows(self: *const CommentsPanel) usize {
        return self.store.totalRows();
    }

    pub fn hasLoadError(self: *const CommentsPanel) bool {
        return self.load_error != null;
    }

    pub fn selectedRowKind(self: *const CommentsPanel) ?SelectedRow {
        if (self.totalRows() == 0) return null;
        var row: usize = 0;
        for (self.store.threads.items, 0..) |thread, thread_index| {
            if (row == self.selected_row) return .{ .thread = thread_index };
            row += 1;
            for (thread.comments.items, 0..) |_, message_index| {
                if (row == self.selected_row) {
                    return .{ .message = .{ .thread_index = thread_index, .message_index = message_index } };
                }
                row += 1;
            }
        }
        return null;
    }

    pub fn selectedThreadIndex(self: *const CommentsPanel) ?usize {
        return switch (self.selectedRowKind() orelse return null) {
            .thread => |index| index,
            .message => |message_ref| message_ref.thread_index,
        };
    }

    pub fn selectedMessageRefOrRoot(self: *const CommentsPanel) ?MessageRef {
        return switch (self.selectedRowKind() orelse return null) {
            .thread => |thread_index| blk: {
                if (thread_index >= self.store.threads.items.len) return null;
                if (self.store.threads.items[thread_index].comments.items.len == 0) return null;
                break :blk .{ .thread_index = thread_index, .message_index = 0 };
            },
            .message => |message_ref| message_ref,
        };
    }

    pub fn moveDown(self: *CommentsPanel) void {
        const total = self.totalRows();
        if (total == 0) return;
        self.selected_row = @min(self.selected_row + 1, total - 1);
    }

    pub fn moveUp(self: *CommentsPanel) void {
        if (self.selected_row > 0) self.selected_row -= 1;
    }

    pub fn clampSelection(self: *CommentsPanel) void {
        const total = self.totalRows();
        if (total == 0) {
            self.selected_row = 0;
            self.scroll_offset = 0;
        } else if (self.selected_row >= total) {
            self.selected_row = total - 1;
        }
    }

    pub fn adjustScroll(self: *CommentsPanel, body_rows: usize) void {
        if (body_rows == 0 or self.totalRows() == 0) {
            self.scroll_offset = 0;
            return;
        }
        if (self.selected_row < self.scroll_offset) {
            self.scroll_offset = self.selected_row;
        } else if (self.selected_row >= self.scroll_offset + body_rows) {
            self.scroll_offset = self.selected_row - body_rows + 1;
        }
    }
};

pub const RenderRange = struct {
    start_col: usize,
    end_col: usize,
    stale: bool,

    pub fn contains(self: RenderRange, col: usize) bool {
        return col >= self.start_col and col < self.end_col;
    }
};

pub fn isSupportedFilePath(path: []const u8) bool {
    const ext = std.fs.path.extension(path);
    const supported = [_][]const u8{ ".txt", ".md", ".markdown", ".rst", ".adoc", ".org" };
    for (supported) |candidate| {
        if (std.ascii.eqlIgnoreCase(ext, candidate)) return true;
    }
    return false;
}

pub fn commentsPath(allocator: std.mem.Allocator, io: std.Io, root_path: []const u8) ![]u8 {
    const status = try workspace.detectWorkspace(allocator, io, root_path);
    return switch (status) {
        .valid => std.fs.path.join(allocator, &.{ root_path, workspace.directory_name, "comments.json" }),
        .none => error.NoWorkspace,
        .invalid_path_exists => error.InvalidWorkspace,
    };
}

pub fn loadComments(allocator: std.mem.Allocator, io: std.Io, root_path: []const u8, out: *CommentStore) !void {
    const path = try commentsPath(allocator, io, root_path);
    defer allocator.free(path);

    const contents = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, std.Io.Limit.limited(4 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => {
            out.clear(allocator);
            return;
        },
        else => return err,
    };
    defer allocator.free(contents);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, contents, .{}) catch return error.MalformedCommentsJson;
    defer parsed.deinit();

    var loaded = CommentStore{};
    errdefer loaded.deinit(allocator);
    try parseCommentStore(allocator, parsed.value, &loaded);

    out.clear(allocator);
    out.threads.deinit(allocator);
    out.version = loaded.version;
    out.threads = loaded.threads;
    loaded.threads = .empty;
}

pub fn saveComments(allocator: std.mem.Allocator, io: std.Io, root_path: []const u8, store: *const CommentStore) !void {
    const path = try commentsPath(allocator, io, root_path);
    defer allocator.free(path);
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(tmp_path);

    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\n  \"version\": 1,\n  \"threads\": [\n");
    for (store.threads.items, 0..) |thread, thread_index| {
        if (thread_index > 0) try out.writer.writeAll(",\n");
        try writeThread(&out.writer, thread);
    }
    try out.writer.writeAll("\n  ]\n}\n");

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp_path, .data = out.written() });
    try std.Io.Dir.cwd().rename(tmp_path, std.Io.Dir.cwd(), path, io);
}

pub fn appendThread(
    panel: *CommentsPanel,
    allocator: std.mem.Allocator,
    io: std.Io,
    file_path: []const u8,
    anchor: *const CommentAnchor,
    author: *const CommentAuthor,
    body: []const u8,
) !void {
    const now = std.Io.Timestamp.now(io, .real).toMilliseconds();
    panel.next_id_counter +%= 1;
    const thread_id = try std.fmt.allocPrint(allocator, "thr-{d}-{d}", .{ now, panel.next_id_counter });
    var thread_id_owned = true;
    errdefer if (thread_id_owned) allocator.free(thread_id);
    const message_id = try std.fmt.allocPrint(allocator, "msg-{d}-{d}", .{ now, panel.next_id_counter });
    var message_id_owned = true;
    errdefer if (message_id_owned) allocator.free(message_id);
    const owned_path = try allocator.dupe(u8, file_path);
    var path_owned = true;
    errdefer if (path_owned) allocator.free(owned_path);
    var owned_anchor = try anchor.clone(allocator);
    var anchor_owned = true;
    errdefer if (anchor_owned) owned_anchor.deinit(allocator);
    var owned_author = try author.clone(allocator);
    var author_owned = true;
    errdefer if (author_owned) owned_author.deinit(allocator);
    const owned_body = try allocator.dupe(u8, body);
    var body_owned = true;
    errdefer if (body_owned) allocator.free(owned_body);

    var messages = std.ArrayListUnmanaged(CommentMessage).empty;
    errdefer {
        for (messages.items) |*message| message.deinit(allocator);
        messages.deinit(allocator);
    }
    try messages.append(allocator, .{
        .id = message_id,
        .author = owned_author,
        .body = owned_body,
        .created_at_unix_ms = now,
        .updated_at_unix_ms = now,
    });
    message_id_owned = false;
    author_owned = false;
    body_owned = false;
    try panel.store.threads.append(allocator, .{
        .id = thread_id,
        .file_path = owned_path,
        .anchor = owned_anchor,
        .status = .open,
        .created_at_unix_ms = now,
        .updated_at_unix_ms = now,
        .comments = messages,
    });
    thread_id_owned = false;
    path_owned = false;
    anchor_owned = false;
    messages = .empty;
    panel.selected_row = panel.store.totalRows() -| 1;
}

pub fn appendReply(
    panel: *CommentsPanel,
    allocator: std.mem.Allocator,
    io: std.Io,
    thread_index: usize,
    author: *const CommentAuthor,
    body: []const u8,
) !void {
    if (thread_index >= panel.store.threads.items.len) return;
    const now = std.Io.Timestamp.now(io, .real).toMilliseconds();
    panel.next_id_counter +%= 1;
    const message_id = try std.fmt.allocPrint(allocator, "msg-{d}-{d}", .{ now, panel.next_id_counter });
    errdefer allocator.free(message_id);
    var owned_author = try author.clone(allocator);
    errdefer owned_author.deinit(allocator);
    const owned_body = try allocator.dupe(u8, body);
    errdefer allocator.free(owned_body);

    const thread = &panel.store.threads.items[thread_index];
    try thread.comments.append(allocator, .{
        .id = message_id,
        .author = owned_author,
        .body = owned_body,
        .created_at_unix_ms = now,
        .updated_at_unix_ms = now,
    });
    thread.updated_at_unix_ms = now;
    panel.clampSelection();
}

pub fn editMessage(panel: *CommentsPanel, allocator: std.mem.Allocator, io: std.Io, message_ref: MessageRef, body: []const u8) !void {
    if (message_ref.thread_index >= panel.store.threads.items.len) return;
    const thread = &panel.store.threads.items[message_ref.thread_index];
    if (message_ref.message_index >= thread.comments.items.len) return;

    const owned_body = try allocator.dupe(u8, body);
    const now = std.Io.Timestamp.now(io, .real).toMilliseconds();
    const message = &thread.comments.items[message_ref.message_index];
    allocator.free(message.body);
    message.body = owned_body;
    message.updated_at_unix_ms = now;
    thread.updated_at_unix_ms = now;
}

pub fn deleteMessage(panel: *CommentsPanel, allocator: std.mem.Allocator, message_ref: MessageRef) void {
    if (message_ref.thread_index >= panel.store.threads.items.len) return;
    if (message_ref.message_index == 0) {
        var thread = panel.store.threads.orderedRemove(message_ref.thread_index);
        thread.deinit(allocator);
        panel.clampSelection();
        return;
    }

    const thread = &panel.store.threads.items[message_ref.thread_index];
    if (message_ref.message_index >= thread.comments.items.len) return;
    var message = thread.comments.orderedRemove(message_ref.message_index);
    message.deinit(allocator);
    panel.clampSelection();
}

pub fn selectedRange(cursor: tab_mod.Cursor) ?struct {
    start_row: usize,
    start_col: usize,
    end_row: usize,
    end_col: usize,
} {
    const ss = cursor.selection_start orelse return null;
    const same_row = ss.row == cursor.row;
    const start_row = @min(ss.row, cursor.row);
    const end_row = @max(ss.row, cursor.row);
    const start_col = if (same_row) @min(ss.col, cursor.col) else if (ss.row < cursor.row) ss.col else cursor.col;
    const end_col = if (same_row) @max(ss.col, cursor.col) else if (ss.row < cursor.row) cursor.col else ss.col;
    if (start_row == end_row and start_col == end_col) return null;
    return .{ .start_row = start_row, .start_col = start_col, .end_row = end_row, .end_col = end_col };
}

pub fn anchorFromSelection(
    allocator: std.mem.Allocator,
    buf: *buffer_mod.Buffer,
    start_row: usize,
    start_col: usize,
    end_row: usize,
    end_col: usize,
) !CommentAnchor {
    const selected_text = try buf.getRange(start_row, start_col, end_row, end_col);
    errdefer allocator.free(selected_text);
    const context_before = try contextBefore(allocator, buf, start_row, start_col);
    errdefer allocator.free(context_before);
    const context_after = try contextAfter(allocator, buf, end_row, end_col);
    errdefer allocator.free(context_after);
    return .{
        .start_line = start_row + 1,
        .start_col = start_col + 1,
        .end_line = end_row + 1,
        .end_col = end_col + 1,
        .selected_text = selected_text,
        .context_before = context_before,
        .context_after = context_after,
    };
}

pub fn validateAnchorsForFile(store: *CommentStore, root_path: ?[]const u8, filename: []const u8, buf: *const buffer_mod.Buffer) void {
    for (store.threads.items) |*thread| {
        if (!pathMatchesThread(root_path, filename, thread.file_path)) continue;
        thread.stale = !anchorMatchesBuffer(buf, &thread.anchor);
    }
}

pub fn anchorMatchesBuffer(buf: *const buffer_mod.Buffer, anchor: *const CommentAnchor) bool {
    if (anchor.start_line == 0 or anchor.start_col == 0 or anchor.end_line == 0 or anchor.end_col == 0) return false;
    const start_row = anchor.start_line - 1;
    const start_col = anchor.start_col - 1;
    const end_row = anchor.end_line - 1;
    const end_col = anchor.end_col - 1;
    if (start_row > end_row or end_row >= buf.lines.items.len) return false;
    if (start_col > buf.lines.items[start_row].len()) return false;
    if (end_col > buf.lines.items[end_row].len()) return false;
    if (start_row == end_row and start_col > end_col) return false;

    var selected_index: usize = 0;
    var row = start_row;
    while (row <= end_row) : (row += 1) {
        const line = &buf.lines.items[row];
        const row_start = if (row == start_row) start_col else 0;
        const row_end = if (row == end_row) end_col else line.len();
        var col = row_start;
        while (col < row_end) : (col += 1) {
            if (selected_index >= anchor.selected_text.len) return false;
            if ((line.byteAt(col) orelse return false) != anchor.selected_text[selected_index]) return false;
            selected_index += 1;
        }
        if (row < end_row) {
            if (selected_index >= anchor.selected_text.len or anchor.selected_text[selected_index] != '\n') return false;
            selected_index += 1;
        }
    }
    return selected_index == anchor.selected_text.len;
}

pub fn buildRenderRangesForLine(
    store: *const CommentStore,
    root_path: ?[]const u8,
    filename: []const u8,
    row: usize,
    storage: *[64]RenderRange,
) []const RenderRange {
    var count: usize = 0;
    for (store.threads.items) |thread| {
        if (count == storage.len) break;
        if (!pathMatchesThread(root_path, filename, thread.file_path)) continue;
        if (thread.anchor.start_line == 0 or thread.anchor.end_line == 0) continue;
        const start_row = thread.anchor.start_line - 1;
        const end_row = thread.anchor.end_line - 1;
        if (row < start_row or row > end_row) continue;
        const start_col = if (row == start_row) thread.anchor.start_col -| 1 else 0;
        const end_col = if (row == end_row) thread.anchor.end_col -| 1 else std.math.maxInt(usize);
        if (start_col == end_col) continue;
        storage[count] = .{ .start_col = start_col, .end_col = end_col, .stale = thread.stale };
        count += 1;
    }
    return storage[0..count];
}

pub fn pathMatchesThread(root_path: ?[]const u8, filename: []const u8, thread_file_path: []const u8) bool {
    if (std.mem.eql(u8, filename, thread_file_path)) return true;
    if (std.mem.startsWith(u8, filename, "./") and std.mem.eql(u8, filename[2..], thread_file_path)) return true;
    if (root_path) |root| {
        if (std.mem.eql(u8, root, ".")) return std.mem.eql(u8, filename, thread_file_path);
        if (std.mem.startsWith(u8, filename, root) and filename.len > root.len) {
            var rel = filename[root.len..];
            if (rel.len > 0 and (rel[0] == '/' or rel[0] == std.fs.path.sep)) rel = rel[1..];
            return std.mem.eql(u8, rel, thread_file_path);
        }
    }
    return false;
}

pub fn relativeFilePath(allocator: std.mem.Allocator, root_path: []const u8, filename: []const u8) ![]u8 {
    if (std.mem.eql(u8, root_path, ".")) {
        if (std.mem.startsWith(u8, filename, "./")) return allocator.dupe(u8, filename[2..]);
        return allocator.dupe(u8, filename);
    }
    if (std.mem.startsWith(u8, filename, root_path) and filename.len > root_path.len) {
        var rel = filename[root_path.len..];
        if (rel.len > 0 and (rel[0] == '/' or rel[0] == std.fs.path.sep)) rel = rel[1..];
        if (rel.len > 0) return allocator.dupe(u8, rel);
    }
    return allocator.dupe(u8, filename);
}

pub fn openPathForThread(allocator: std.mem.Allocator, root_path: []const u8, thread_file_path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(thread_file_path)) return allocator.dupe(u8, thread_file_path);
    if (std.mem.eql(u8, root_path, ".")) return allocator.dupe(u8, thread_file_path);
    return std.fs.path.join(allocator, &.{ root_path, thread_file_path });
}

pub fn resolveAuthor(
    allocator: std.mem.Allocator,
    io: std.Io,
    root_path: []const u8,
    cfg: *const config.Config,
) !?CommentAuthor {
    const inside_git = isInsideGitWorkTree(allocator, io, root_path);
    const git_name = if (inside_git) try gitConfigValue(allocator, io, root_path, "user.name") else null;
    defer if (git_name) |value| allocator.free(value);
    const git_email = if (inside_git) try gitConfigValue(allocator, io, root_path, "user.email") else null;
    defer if (git_email) |value| allocator.free(value);

    const chosen_name = if (git_name) |value|
        if (value.len > 0) value else cfg.author.name orelse ""
    else
        cfg.author.name orelse "";
    if (chosen_name.len == 0) return null;

    const chosen_email = if (git_email) |value|
        if (value.len > 0) value else cfg.author.email orelse ""
    else
        cfg.author.email orelse "";

    const owned_name = try allocator.dupe(u8, chosen_name);
    errdefer allocator.free(owned_name);
    const owned_email = if (chosen_email.len > 0) try allocator.dupe(u8, chosen_email) else null;
    errdefer if (owned_email) |value| allocator.free(value);
    return .{ .name = owned_name, .email = owned_email };
}

fn isInsideGitWorkTree(allocator: std.mem.Allocator, io: std.Io, root_path: []const u8) bool {
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "git", "-C", root_path, "rev-parse", "--is-inside-work-tree" },
        .stdout_limit = std.Io.Limit.limited(1024),
        .stderr_limit = std.Io.Limit.limited(1024),
    }) catch return false;
    defer allocator.free(result.stderr);
    defer allocator.free(result.stdout);
    switch (result.term) {
        .exited => |code| if (code != 0) return false,
        else => return false,
    }
    return std.mem.eql(u8, std.mem.trim(u8, result.stdout, " \t\r\n"), "true");
}

pub fn authorFromConfig(allocator: std.mem.Allocator, cfg: *const config.Config) !?CommentAuthor {
    const name = cfg.author.name orelse return null;
    if (std.mem.trim(u8, name, " \t\r\n").len == 0) return null;
    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);
    const email = if (cfg.author.email) |value| if (value.len > 0) try allocator.dupe(u8, value) else null else null;
    errdefer if (email) |value| allocator.free(value);
    return .{ .name = owned_name, .email = email };
}

fn gitConfigValue(allocator: std.mem.Allocator, io: std.Io, root_path: []const u8, key: []const u8) !?[]u8 {
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "git", "-C", root_path, "config", key },
        .stdout_limit = std.Io.Limit.limited(16 * 1024),
        .stderr_limit = std.Io.Limit.limited(16 * 1024),
    }) catch return null;
    defer allocator.free(result.stderr);
    defer allocator.free(result.stdout);
    switch (result.term) {
        .exited => |code| if (code != 0) return null,
        else => return null,
    }
    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (trimmed.len == 0) return null;
    return try allocator.dupe(u8, trimmed);
}

fn contextBefore(allocator: std.mem.Allocator, buf: *buffer_mod.Buffer, row: usize, col: usize) ![]u8 {
    if (row >= buf.lines.items.len) return allocator.dupe(u8, "");
    const line = try buf.lines.items[row].slice(allocator);
    defer allocator.free(line);
    const bounded_col = @min(col, line.len);
    const start = bounded_col -| 48;
    return allocator.dupe(u8, line[start..bounded_col]);
}

fn contextAfter(allocator: std.mem.Allocator, buf: *buffer_mod.Buffer, row: usize, col: usize) ![]u8 {
    if (row >= buf.lines.items.len) return allocator.dupe(u8, "");
    const line = try buf.lines.items[row].slice(allocator);
    defer allocator.free(line);
    const bounded_col = @min(col, line.len);
    const end = @min(line.len, bounded_col + 48);
    return allocator.dupe(u8, line[bounded_col..end]);
}

fn parseCommentStore(allocator: std.mem.Allocator, value: std.json.Value, out: *CommentStore) !void {
    const root = switch (value) {
        .object => |object| object,
        else => return error.MalformedCommentsJson,
    };
    const version = jsonInteger(root.get("version") orelse return error.MalformedCommentsJson) orelse return error.MalformedCommentsJson;
    if (version != 1) return error.MalformedCommentsJson;
    out.version = 1;
    const threads = switch (root.get("threads") orelse return error.MalformedCommentsJson) {
        .array => |array| array.items,
        else => return error.MalformedCommentsJson,
    };
    for (threads) |thread_value| {
        var thread = try parseThread(allocator, thread_value);
        errdefer thread.deinit(allocator);
        try out.threads.append(allocator, thread);
    }
}

fn parseThread(allocator: std.mem.Allocator, value: std.json.Value) !CommentThread {
    const object = switch (value) {
        .object => |thread_object| thread_object,
        else => return error.MalformedCommentsJson,
    };
    const id = try dupeRequiredString(allocator, object, "id");
    errdefer allocator.free(id);
    const file_path = try dupeRequiredString(allocator, object, "file_path");
    errdefer allocator.free(file_path);
    var anchor = try parseAnchor(allocator, object.get("anchor") orelse return error.MalformedCommentsJson);
    errdefer anchor.deinit(allocator);
    const status_text = jsonString(object.get("status") orelse .{ .string = "open" }) orelse "open";
    const created = jsonInteger(object.get("created_at_unix_ms") orelse .{ .integer = 0 }) orelse 0;
    const updated = jsonInteger(object.get("updated_at_unix_ms") orelse .{ .integer = created }) orelse created;

    var messages = std.ArrayListUnmanaged(CommentMessage).empty;
    errdefer {
        for (messages.items) |*message| message.deinit(allocator);
        messages.deinit(allocator);
    }
    const comments = switch (object.get("comments") orelse return error.MalformedCommentsJson) {
        .array => |array| array.items,
        else => return error.MalformedCommentsJson,
    };
    for (comments) |message_value| {
        var message = try parseMessage(allocator, message_value);
        errdefer message.deinit(allocator);
        try messages.append(allocator, message);
    }
    if (messages.items.len == 0) return error.MalformedCommentsJson;
    return .{
        .id = id,
        .file_path = file_path,
        .anchor = anchor,
        .status = ThreadStatus.fromString(status_text),
        .created_at_unix_ms = created,
        .updated_at_unix_ms = updated,
        .comments = messages,
    };
}

fn parseAnchor(allocator: std.mem.Allocator, value: std.json.Value) !CommentAnchor {
    const object = switch (value) {
        .object => |anchor_object| anchor_object,
        else => return error.MalformedCommentsJson,
    };
    const selected_text = try dupeRequiredString(allocator, object, "selected_text");
    errdefer allocator.free(selected_text);
    const context_before = try dupeOptionalString(allocator, object, "context_before", "");
    errdefer allocator.free(context_before);
    const context_after = try dupeOptionalString(allocator, object, "context_after", "");
    errdefer allocator.free(context_after);
    return .{
        .start_line = try requiredUsize(object, "start_line"),
        .start_col = try requiredUsize(object, "start_col"),
        .end_line = try requiredUsize(object, "end_line"),
        .end_col = try requiredUsize(object, "end_col"),
        .selected_text = selected_text,
        .context_before = context_before,
        .context_after = context_after,
    };
}

fn parseMessage(allocator: std.mem.Allocator, value: std.json.Value) !CommentMessage {
    const object = switch (value) {
        .object => |message_object| message_object,
        else => return error.MalformedCommentsJson,
    };
    const id = try dupeRequiredString(allocator, object, "id");
    errdefer allocator.free(id);
    var author = try parseAuthor(allocator, object.get("author") orelse return error.MalformedCommentsJson);
    errdefer author.deinit(allocator);
    const body = try dupeRequiredString(allocator, object, "body");
    errdefer allocator.free(body);
    const created = jsonInteger(object.get("created_at_unix_ms") orelse .{ .integer = 0 }) orelse 0;
    const updated = jsonInteger(object.get("updated_at_unix_ms") orelse .{ .integer = created }) orelse created;
    return .{
        .id = id,
        .author = author,
        .body = body,
        .created_at_unix_ms = created,
        .updated_at_unix_ms = updated,
    };
}

fn parseAuthor(allocator: std.mem.Allocator, value: std.json.Value) !CommentAuthor {
    const object = switch (value) {
        .object => |author_object| author_object,
        else => return error.MalformedCommentsJson,
    };
    const name = try dupeRequiredString(allocator, object, "name");
    errdefer allocator.free(name);
    const email = if (jsonString(object.get("email") orelse .{ .string = "" })) |email_text|
        if (email_text.len > 0) try allocator.dupe(u8, email_text) else null
    else
        null;
    errdefer if (email) |value_email| allocator.free(value_email);
    return .{ .name = name, .email = email };
}

fn writeThread(writer: anytype, thread: CommentThread) !void {
    try writer.writeAll("    {\n");
    try writeJsonField(writer, "id", thread.id, true, 6);
    try writeJsonField(writer, "file_path", thread.file_path, true, 6);
    try writer.writeAll("      \"anchor\": {\n");
    try writer.print("        \"start_line\": {d},\n", .{thread.anchor.start_line});
    try writer.print("        \"start_col\": {d},\n", .{thread.anchor.start_col});
    try writer.print("        \"end_line\": {d},\n", .{thread.anchor.end_line});
    try writer.print("        \"end_col\": {d},\n", .{thread.anchor.end_col});
    try writeJsonField(writer, "selected_text", thread.anchor.selected_text, true, 8);
    try writeJsonField(writer, "context_before", thread.anchor.context_before, true, 8);
    try writeJsonField(writer, "context_after", thread.anchor.context_after, false, 8);
    try writer.writeAll("      },\n");
    try writeJsonField(writer, "status", thread.status.label(), true, 6);
    try writer.print("      \"created_at_unix_ms\": {d},\n", .{thread.created_at_unix_ms});
    try writer.print("      \"updated_at_unix_ms\": {d},\n", .{thread.updated_at_unix_ms});
    try writer.writeAll("      \"comments\": [\n");
    for (thread.comments.items, 0..) |message, index| {
        if (index > 0) try writer.writeAll(",\n");
        try writeMessage(writer, message);
    }
    try writer.writeAll("\n      ]\n");
    try writer.writeAll("    }");
}

fn writeMessage(writer: anytype, message: CommentMessage) !void {
    try writer.writeAll("        {\n");
    try writeJsonField(writer, "id", message.id, true, 10);
    try writer.writeAll("          \"author\": {\n");
    try writeJsonField(writer, "name", message.author.name, message.author.email != null, 12);
    if (message.author.email) |email| try writeJsonField(writer, "email", email, false, 12);
    try writer.writeAll("          },\n");
    try writeJsonField(writer, "body", message.body, true, 10);
    try writer.print("          \"created_at_unix_ms\": {d},\n", .{message.created_at_unix_ms});
    try writer.print("          \"updated_at_unix_ms\": {d}\n", .{message.updated_at_unix_ms});
    try writer.writeAll("        }");
}

fn writeJsonField(writer: anytype, name: []const u8, value: []const u8, comma: bool, indent: usize) !void {
    try writeIndent(writer, indent);
    try writer.print("\"{s}\": \"", .{name});
    try writeJsonStringContents(writer, value);
    try writer.writeAll(if (comma) "\",\n" else "\"\n");
}

fn writeIndent(writer: anytype, count: usize) !void {
    for (0..count) |_| try writer.writeByte(' ');
}

fn writeJsonStringContents(writer: anytype, value: []const u8) !void {
    for (value) |ch| {
        switch (ch) {
            '\\' => try writer.writeAll("\\\\"),
            '"' => try writer.writeAll("\\\""),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (ch < 0x20) {
                    try writer.print("\\u{X:0>4}", .{ch});
                } else {
                    try writer.writeByte(ch);
                }
            },
        }
    }
}

fn requiredUsize(object: std.json.ObjectMap, key: []const u8) !usize {
    const value = jsonInteger(object.get(key) orelse return error.MalformedCommentsJson) orelse return error.MalformedCommentsJson;
    if (value < 0) return error.MalformedCommentsJson;
    return @intCast(value);
}

fn dupeRequiredString(allocator: std.mem.Allocator, object: std.json.ObjectMap, key: []const u8) ![]u8 {
    const value = jsonString(object.get(key) orelse return error.MalformedCommentsJson) orelse return error.MalformedCommentsJson;
    return allocator.dupe(u8, value);
}

fn dupeOptionalString(allocator: std.mem.Allocator, object: std.json.ObjectMap, key: []const u8, fallback: []const u8) ![]u8 {
    const value = jsonString(object.get(key) orelse .{ .string = fallback }) orelse fallback;
    return allocator.dupe(u8, value);
}

fn jsonString(value: std.json.Value) ?[]const u8 {
    return switch (value) {
        .string => |string| string,
        else => null,
    };
}

fn jsonInteger(value: std.json.Value) ?i64 {
    return switch (value) {
        .integer => |integer| @intCast(integer),
        else => null,
    };
}

test "comments supported file detection" {
    try std.testing.expect(isSupportedFilePath("notes.txt"));
    try std.testing.expect(isSupportedFilePath("README.md"));
    try std.testing.expect(isSupportedFilePath("docs/spec.markdown"));
    try std.testing.expect(isSupportedFilePath("doc.rst"));
    try std.testing.expect(isSupportedFilePath("guide.adoc"));
    try std.testing.expect(isSupportedFilePath("agenda.org"));
    try std.testing.expect(!isSupportedFilePath("main.zig"));
    try std.testing.expect(!isSupportedFilePath("config.toml"));
}

test "comments load save round trip and malformed protection" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, ".flamingo");

    const root_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root_path);

    var panel = CommentsPanel{};
    defer panel.deinit(allocator);

    var anchor = CommentAnchor{
        .start_line = 1,
        .start_col = 1,
        .end_line = 1,
        .end_col = 6,
        .selected_text = try allocator.dupe(u8, "hello"),
        .context_before = try allocator.dupe(u8, ""),
        .context_after = try allocator.dupe(u8, " world"),
    };
    defer anchor.deinit(allocator);
    var author = CommentAuthor{
        .name = try allocator.dupe(u8, "Davide"),
        .email = try allocator.dupe(u8, "davide@example.com"),
    };
    defer author.deinit(allocator);

    try appendThread(&panel, allocator, io, "notes.md", &anchor, &author, "Clarify this");
    try appendReply(&panel, allocator, io, 0, &author, "Agreed");
    try saveComments(allocator, io, root_path, &panel.store);

    var loaded = CommentStore{};
    defer loaded.deinit(allocator);
    try loadComments(allocator, io, root_path, &loaded);
    try std.testing.expectEqual(@as(usize, 1), loaded.threads.items.len);
    try std.testing.expectEqualStrings("notes.md", loaded.threads.items[0].file_path);
    try std.testing.expectEqualStrings("hello", loaded.threads.items[0].anchor.selected_text);
    try std.testing.expectEqual(@as(usize, 2), loaded.threads.items[0].comments.items.len);
    try std.testing.expectEqualStrings("Clarify this", loaded.threads.items[0].comments.items[0].body);

    try tmp.dir.writeFile(io, .{ .sub_path = ".flamingo/comments.json", .data = "{ nope" });
    try std.testing.expectError(error.MalformedCommentsJson, loadComments(allocator, io, root_path, &loaded));
}

test "comments anchor matching detects stale text" {
    const allocator = std.testing.allocator;
    var buf = try buffer_mod.Buffer.init(allocator);
    defer buf.deinit();
    var first = buf.lines.orderedRemove(0);
    first.deinit();
    try buf.lines.append(allocator, try buffer_mod.Line.fromSlice(allocator, "The scheduler chooses latency"));

    var anchor = try anchorFromSelection(allocator, &buf, 0, 4, 0, 13);
    defer anchor.deinit(allocator);
    try std.testing.expect(anchorMatchesBuffer(&buf, &anchor));
    allocator.free(anchor.selected_text);
    anchor.selected_text = try allocator.dupe(u8, "different");
    try std.testing.expect(!anchorMatchesBuffer(&buf, &anchor));
}

test "comments author config fallback" {
    const allocator = std.testing.allocator;
    const cfg = config.Config{
        .author = .{ .name = "Davide", .email = "davide@example.com" },
    };
    var author = (try authorFromConfig(allocator, &cfg)).?;
    defer author.deinit(allocator);
    try std.testing.expectEqualStrings("Davide", author.name);
    try std.testing.expectEqualStrings("davide@example.com", author.email.?);

    const missing = config.Config{};
    try std.testing.expect((try authorFromConfig(allocator, &missing)) == null);
}
