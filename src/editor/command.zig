const std = @import("std");
const editor = @import("editor.zig");
const navigation = @import("navigation.zig");
const fs_ops = @import("filesystem_ops.zig");
const commands = @import("commands.zig");
const todos = @import("todos.zig");
const comments = @import("comments.zig");
const workspace = @import("workspace.zig");
const git_graph = @import("git_graph.zig");
const command_parser = @import("tasks/command_parser.zig");
const task_mod = @import("tasks/task.zig");

pub const Command = enum {
    quit,
    quit_all,
    force_quit,
    write,
    write_all,
    write_quit,
    search,
    help,
    font_info,
    todos,
    comment,
    comments,
    git_diff,
    agent,
    proposals,
    run,
    tasks,
    task_stop,
    git_graph,
    git_diff_refresh,
    rename_file,
    delete_file,
    new_file,

    pub fn commandId(self: Command) commands.CommandId {
        return switch (self) {
            .quit => .app_quit,
            .quit_all => .app_quit_all,
            .force_quit => .app_force_quit_tab,
            .write => .file_write,
            .write_all => .file_write_all,
            .write_quit => .file_write_quit,
            .search => .command_search_open,
            .help => .help_open,
            .font_info => .font_info_open,
            .todos => .todos_open,
            .comment => .comment_create,
            .comments => .comments_open,
            .git_diff => .git_diff_open,
            .agent => .agent_open,
            .proposals => .proposals_open,
            .run => .task_run,
            .tasks => .tasks_open,
            .task_stop => .task_stop,
            .git_graph => .git_graph_open,
            .git_diff_refresh => .git_diff_refresh,
            .rename_file => .file_rename,
            .delete_file => .file_delete,
            .new_file => .file_new,
        };
    }

    pub fn name(self: Command) []const u8 {
        const meta = commands.metadata(self.commandId());
        return meta.command_names[0];
    }

    pub fn alias(self: Command) ?[]const u8 {
        const meta = commands.metadata(self.commandId());
        return if (meta.aliases.len > 0) meta.aliases[0] else null;
    }

    pub fn fromString(value: []const u8) ?Command {
        const id = commands.commandByCommandLineName(value) orelse return null;
        return legacyCommandFromCommandId(id);
    }
};

fn legacyCommandFromCommandId(id: commands.CommandId) ?Command {
    return switch (id) {
        .app_quit => .quit,
        .app_quit_all => .quit_all,
        .app_force_quit_tab => .force_quit,
        .file_write => .write,
        .file_write_all => .write_all,
        .file_write_quit => .write_quit,
        .command_search_open => .search,
        .help_open => .help,
        .font_info_open => .font_info,
        .todos_open => .todos,
        .comment_create => .comment,
        .comments_open => .comments,
        .git_diff_open => .git_diff,
        .agent_open => .agent,
        .proposals_open => .proposals,
        .task_run => .run,
        .tasks_open => .tasks,
        .task_stop => .task_stop,
        .git_graph_open => .git_graph,
        .git_diff_refresh => .git_diff_refresh,
        .file_rename => .rename_file,
        .file_delete => .delete_file,
        .file_new => .new_file,
        else => null,
    };
}

fn nextArg(it: *std.mem.SplitIterator(u8, .scalar)) ?[]const u8 {
    while (it.next()) |arg| {
        if (arg.len > 0) return arg;
    }
    return null;
}

fn requireNoMoreArgs(ed: *editor.Editor, it: *std.mem.SplitIterator(u8, .scalar)) bool {
    if (nextArg(it) != null) {
        ed.state.error_message = "Too many command arguments";
        ed.state.mode = .Normal;
        return false;
    }
    return true;
}

fn requireArg(ed: *editor.Editor, it: *std.mem.SplitIterator(u8, .scalar)) ?[]const u8 {
    return nextArg(it) orelse {
        ed.state.error_message = "Missing command argument";
        ed.state.mode = .Normal;
        return null;
    };
}

fn commandTail(input: []const u8, command_name: []const u8) []const u8 {
    var rest = input;
    rest = trimLeftAsciiWhitespace(rest);
    if (std.mem.startsWith(u8, rest, command_name)) rest = rest[command_name.len..];
    return trimLeftAsciiWhitespace(rest);
}

fn trimLeftAsciiWhitespace(input: []const u8) []const u8 {
    var index: usize = 0;
    while (index < input.len and std.ascii.isWhitespace(input[index])) : (index += 1) {}
    return input[index..];
}

fn setFsError(ed: *editor.Editor, err: anyerror) void {
    ed.state.error_message = fs_ops.userMessage(err);
    ed.state.mode = .Normal;
}

fn parseLineJump(input: []const u8) ?usize {
    if (input.len == 0) return null;
    if (std.ascii.isDigit(input[0])) {
        return std.fmt.parseInt(usize, input, 10) catch null;
    }

    var it = std.mem.splitScalar(u8, input, ' ');
    const name = it.next() orelse return null;
    if (!std.mem.eql(u8, name, "goto") and !std.mem.eql(u8, name, "line")) return null;

    const line_text = it.next() orelse return null;
    if (it.next() != null) return null;
    return std.fmt.parseInt(usize, line_text, 10) catch null;
}

pub fn execute(ed: *editor.Editor) !void {
    const command_input = if (ed.state.command_popup.visible)
        ed.state.command_popup.input.items
    else
        ed.state.command_buffer.items;
    defer if (ed.state.command_popup.visible) ed.state.command_popup.close();

    if (command_input.len == 0) {
        ed.state.mode = .Normal;
        return;
    }

    if (parseLineJump(command_input)) |line_number| {
        const row = line_number -| 1;
        const col = if (ed.currentTab()) |tab| tab.mainCursor().col else 0;
        _ = try navigation.jumpTo(ed, row, col, .{ .record_history = true });
        ed.state.mode = .Normal;
        ed.state.explorer_focused = false;
        return;
    }

    var it = std.mem.splitScalar(u8, command_input, ' ');
    const cmd = nextArg(&it) orelse return;
    const command = Command.fromString(cmd) orelse {
        ed.state.error_message = "Not an editor command";
        ed.state.mode = .Normal;
        return;
    };

    switch (command) {
        .quit => {
            if (ed.currentTab()) |tab| {
                if (tab.buf.is_dirty) {
                    ed.state.save_confirmation.open(tab.buf.filename);
                    ed.state.mode = .SaveConfirmation;
                    return;
                }
            }
            ed.closeTab();
        },
        .quit_all => {
            ed.state.quitting_all = true;
            ed.processQuitAll();
        },
        .force_quit => {
            ed.closeTab();
        },
        .write => {
            const filename = nextArg(&it);
            if (ed.currentTab()) |tab| {
                if (filename) |f| {
                    try tab.buf.setFilename(f);
                }
                if (tab.buf.filename != null) {
                    ed.saveTab(tab) catch {
                        ed.state.error_message = "Failed to save file";
                    };
                } else {
                    ed.state.error_message = "No file name";
                }
            }
            ed.state.mode = .Normal;
        },
        .write_all => {
            ed.processWriteAll();
            ed.state.mode = .Normal;
        },
        .write_quit => {
            const filename = nextArg(&it);
            if (ed.currentTab()) |tab| {
                if (filename) |f| {
                    try tab.buf.setFilename(f);
                }
                if (tab.buf.filename != null) {
                    ed.saveTab(tab) catch {
                        ed.state.error_message = "Failed to save file";
                        ed.state.mode = .Normal;
                        return;
                    };
                    ed.closeTab();
                } else {
                    ed.state.error_message = "No file name";
                    ed.state.mode = .Normal;
                }
            } else {
                ed.closeTab();
            }
        },
        .search => {
            const root_path = if (ed.state.tree) |tree| tree.root_path else ".";
            try ed.state.global_search.open(ed.allocator, root_path);
            ed.state.mode = .GlobalSearch;
            ed.markDirty(.full);
        },
        .help => {
            ed.state.help_popup.open();
            ed.state.mode = .Help;
            ed.markDirty(.full);
        },
        .font_info => {
            if (!requireNoMoreArgs(ed, &it)) return;
            ed.state.status_message = ed.fontInfoStatusMessage();
            ed.state.mode = .Normal;
            ed.markDirty(.partial);
        },
        .todos => {
            if (!requireNoMoreArgs(ed, &it)) return;
            try openTodoPanel(ed);
            ed.state.mode = .Normal;
            ed.state.explorer_focused = false;
            ed.state.comments_panel.focused = false;
            ed.terminal_panel.blur();
            ed.markDirty(.full);
        },
        .comment => {
            if (!requireNoMoreArgs(ed, &it)) return;
            try beginNewCommentFromSelection(ed);
        },
        .comments => {
            if (nextArg(&it)) |arg| {
                if (!std.mem.eql(u8, arg, "refresh")) {
                    ed.state.error_message = "Unknown comments command";
                    ed.state.mode = .Normal;
                    return;
                }
                if (!requireNoMoreArgs(ed, &it)) return;
                try openCommentsPanel(ed);
                try refreshCommentsPanel(ed);
                if (ed.state.comments_panel.load_error == null) {
                    ed.state.status_message = "Comments refreshed";
                }
            } else {
                try openCommentsPanel(ed);
            }
            ed.state.mode = .Normal;
            ed.state.explorer_focused = false;
            ed.state.todo_panel.focused = false;
            ed.terminal_panel.blur();
            ed.markDirty(.full);
        },
        .git_diff => {
            if (!requireNoMoreArgs(ed, &it)) return;
            try openGitDiffPanel(ed);
        },
        .agent => {
            if (!requireNoMoreArgs(ed, &it)) return;
            openAgentPanel(ed);
        },
        .proposals => {
            if (!requireNoMoreArgs(ed, &it)) return;
            openProposalsPanel(ed);
        },
        .run => {
            const tail = commandTail(command_input, cmd);
            try runWorkspaceTask(ed, tail);
        },
        .tasks => {
            if (!requireNoMoreArgs(ed, &it)) return;
            openTaskPanel(ed);
        },
        .task_stop => {
            if (!requireNoMoreArgs(ed, &it)) return;
            stopRunningTask(ed);
        },
        .git_graph => {
            if (!requireNoMoreArgs(ed, &it)) return;
            try openGitGraphPanel(ed);
        },
        .git_diff_refresh => {
            if (!requireNoMoreArgs(ed, &it)) return;
            ed.queueGitDiffRefreshForCurrentTab(true);
            ed.state.mode = .Normal;
            ed.markDirty(.partial);
        },
        .new_file => {
            const input_path = requireArg(ed, &it) orelse return;
            if (!requireNoMoreArgs(ed, &it)) return;
            const path = fs_ops.resolveProjectPath(ed.allocator, ed.io, ed.state.project_root, input_path) catch |err| {
                setFsError(ed, err);
                return;
            };
            defer ed.allocator.free(path);
            fs_ops.createFileAndOpen(ed, path, true) catch |err| {
                setFsError(ed, err);
                return;
            };
            ed.state.mode = .Normal;
        },
        .rename_file => {
            const old_input = requireArg(ed, &it) orelse return;
            const new_input = requireArg(ed, &it) orelse return;
            if (!requireNoMoreArgs(ed, &it)) return;
            const old_path = fs_ops.resolveProjectPath(ed.allocator, ed.io, ed.state.project_root, old_input) catch |err| {
                setFsError(ed, err);
                return;
            };
            defer ed.allocator.free(old_path);
            const new_path = fs_ops.resolveProjectPath(ed.allocator, ed.io, ed.state.project_root, new_input) catch |err| {
                setFsError(ed, err);
                return;
            };
            defer ed.allocator.free(new_path);
            fs_ops.renameNoOverwrite(ed.io, old_path, new_path) catch |err| {
                setFsError(ed, err);
                return;
            };
            fs_ops.updateOpenBuffersAfterRename(ed, old_path, new_path) catch |err| {
                setFsError(ed, err);
                return;
            };
            fs_ops.refreshExplorerBestEffort(ed, new_path) catch {};
            ed.state.mode = .Normal;
        },
        .delete_file => {
            const input_path = requireArg(ed, &it) orelse return;
            if (!requireNoMoreArgs(ed, &it)) return;
            const path = fs_ops.resolveProjectPath(ed.allocator, ed.io, ed.state.project_root, input_path) catch |err| {
                setFsError(ed, err);
                return;
            };
            defer ed.allocator.free(path);
            if (fs_ops.isOpenInEditor(ed, path)) {
                setFsError(ed, error.FileIsOpen);
                return;
            }
            fs_ops.deleteRegularFile(ed.io, path) catch |err| {
                setFsError(ed, err);
                return;
            };
            fs_ops.refreshExplorerBestEffort(ed, null) catch {};
            ed.state.mode = .Normal;
        },
    }
}

fn todoRoot(ed: *editor.Editor) []const u8 {
    if (ed.state.project_root) |root| return root;
    if (ed.state.tree) |tree| return tree.root_path;
    return ".";
}

pub fn openTodoPanel(ed: *editor.Editor) !void {
    const root = todoRoot(ed);
    ed.state.todo_panel.visible = true;
    ed.state.todo_panel.focused = true;
    ed.state.comments_panel.visible = false;
    ed.state.comments_panel.focused = false;

    const manual_available = try ensureTodoWorkspace(ed, root);
    ed.state.todo_panel.clearManual(ed.allocator);
    if (manual_available) {
        todos.loadManualTodos(ed.allocator, ed.io, root, &ed.state.todo_panel.manual_items) catch |err| switch (err) {
            error.NoWorkspace => ed.state.status_message = "Manual TODOs unavailable: could not create .flamingo workspace",
            error.InvalidWorkspace => ed.state.status_message = "Cannot use workspace TODOs: .flamingo exists and is not a directory",
            error.MalformedTodosJson => ed.state.error_message = "Could not read .flamingo/todos.json",
            else => return err,
        };
    }

    const needs_scan = ed.state.todo_panel.scan_status == .not_scanned or
        ed.state.todo_panel.last_scan_root == null or
        !std.mem.eql(u8, ed.state.todo_panel.last_scan_root.?, root);
    if (needs_scan) {
        try refreshTodoPanelCode(ed, root);
    }
    ed.state.todo_panel.clampSelection();
}

fn ensureTodoWorkspace(ed: *editor.Editor, root: []const u8) !bool {
    const status = workspace.detectWorkspace(ed.allocator, ed.io, root) catch {
        ed.state.clearWorkspace(ed.allocator);
        ed.state.status_message = "Could not inspect .flamingo workspace";
        return false;
    };

    switch (status) {
        .valid => {
            try ed.state.setWorkspaceRoot(ed.allocator, root);
            return true;
        },
        .invalid_path_exists => {
            ed.state.clearWorkspace(ed.allocator);
            ed.state.status_message = "Cannot use workspace TODOs: .flamingo exists and is not a directory";
            return false;
        },
        .none => {
            const result = workspace.createWorkspace(ed.allocator, ed.io, root) catch {
                ed.state.clearWorkspace(ed.allocator);
                ed.state.status_message = "Could not create .flamingo workspace for TODOs";
                return false;
            };
            switch (result) {
                .created, .already_exists => {
                    try ed.state.setWorkspaceRoot(ed.allocator, root);
                    if (result == .created) ed.state.status_message = "Workspace created for TODOs";
                    return true;
                },
                .invalid_path_exists => {
                    ed.state.clearWorkspace(ed.allocator);
                    ed.state.status_message = "Cannot use workspace TODOs: .flamingo exists and is not a directory";
                    return false;
                },
            }
        },
    }
}

pub fn refreshTodoPanelCode(ed: *editor.Editor, root: []const u8) !void {
    ed.state.todo_panel.clearCode(ed.allocator);
    todos.scanRoot(ed.allocator, ed.io, root, &ed.state.todo_panel.code_items) catch |err| {
        ed.state.todo_panel.scan_status = .scan_failed;
        ed.state.error_message = "Could not scan TODOs";
        return err;
    };
    ed.state.todo_panel.last_scan_root = try ed.allocator.dupe(u8, root);
    ed.state.todo_panel.scan_status = .scanned;
}

fn commentsRoot(ed: *editor.Editor) []const u8 {
    if (ed.state.project_root) |root| return root;
    if (ed.state.tree) |tree| return tree.root_path;
    return ".";
}

pub fn openGitGraphPanel(ed: *editor.Editor) !void {
    const explorer_root = if (ed.state.tree) |tree| tree.root_path else null;
    const current_file = if (ed.currentTab()) |tab| tab.buf.filename else null;
    ed.state.git_graph_panel.open(ed.allocator, ed.io, .{
        .project_root = ed.state.project_root,
        .explorer_root = explorer_root,
        .current_file = current_file,
    }) catch |err| switch (err) {
        error.NotGitRepository => {
            ed.state.error_message = "Not a Git repository";
            ed.state.mode = if (ed.state.tabs.items.len == 0) .Dashboard else .Normal;
            ed.markDirty(.full);
            return;
        },
        else => return err,
    };
    ed.state.mode = .GitGraph;
    ed.state.explorer_focused = false;
    ed.state.todo_panel.focused = false;
    ed.state.comments_panel.focused = false;
    ed.terminal_panel.blur();
    ed.markDirty(.full);
}

pub fn openGitDiffPanel(ed: *editor.Editor) !void {
    const explorer_root = if (ed.state.tree) |tree| tree.root_path else null;
    const current_file = if (ed.currentTab()) |tab| tab.buf.filename else null;
    try ed.state.git_diff_panel.open(ed.allocator, ed.io, .{
        .project_root = ed.state.project_root,
        .explorer_root = explorer_root,
        .current_file = current_file,
    });
    ed.state.mode = .GitDiff;
    ed.state.explorer_focused = false;
    ed.state.todo_panel.focused = false;
    ed.state.comments_panel.focused = false;
    ed.terminal_panel.blur();
    ed.markDirty(.full);
}

fn taskRoot(ed: *editor.Editor) ?[]const u8 {
    if (ed.state.project_root) |root| return root;
    if (ed.state.tree) |tree| return tree.root_path;
    if (ed.state.workspace.root_path) |root| return root;
    return null;
}

pub fn openTaskPanel(ed: *editor.Editor) void {
    ed.state.task_manager.open();
    ed.state.mode = .TaskPanel;
    ed.state.explorer_focused = false;
    ed.state.todo_panel.focused = false;
    ed.state.comments_panel.focused = false;
    ed.terminal_panel.blur();
    ed.markDirty(.full);
}

pub fn openAgentPanel(ed: *editor.Editor) void {
    ed.state.agent_manager.open();
    ed.state.mode = .Agent;
    ed.state.explorer_focused = false;
    ed.state.todo_panel.focused = false;
    ed.state.comments_panel.focused = false;
    ed.terminal_panel.blur();
    ed.markDirty(.full);
}

pub fn openProposalsPanel(ed: *editor.Editor) void {
    ed.state.proposal_manager.open();
    ed.state.mode = .Proposals;
    ed.state.explorer_focused = false;
    ed.state.todo_panel.focused = false;
    ed.state.comments_panel.focused = false;
    ed.terminal_panel.blur();
    ed.markDirty(.full);
}

pub fn runWorkspaceTask(ed: *editor.Editor, command_text: []const u8) !void {
    const root = taskRoot(ed) orelse {
        ed.state.error_message = "No workspace root available for task execution.";
        ed.state.mode = if (ed.state.tabs.items.len == 0) .Dashboard else .Normal;
        ed.markDirty(.partial);
        return;
    };

    var parsed = command_parser.parse(ed.allocator, command_text) catch |err| {
        ed.state.error_message = taskParseErrorMessage(err);
        ed.state.mode = if (ed.state.tabs.items.len == 0) .Dashboard else .Normal;
        ed.markDirty(.partial);
        return;
    };
    var parsed_owned = true;
    errdefer if (parsed_owned) parsed.deinit(ed.allocator);

    const id = try ed.state.task_manager.addQueuedTask(parsed, root, task_mod.nowMs(ed.io));
    parsed_owned = false;
    openTaskPanel(ed);

    const task = ed.state.task_manager.findTask(id) orelse return;
    ed.runtime.task_worker.startTask(id, task.argvConst(), task.cwd) catch |err| {
        const message = switch (err) {
            error.TaskAlreadyRunning => "Another task is already running.",
            else => "Unable to start task.",
        };
        try ed.state.task_manager.failToStart(id, message, task_mod.nowMs(ed.io));
        ed.state.error_message = message;
        ed.markDirty(.partial);
        return;
    };
}

pub fn stopRunningTask(ed: *editor.Editor) void {
    if (!ed.runtime.task_worker.hasRunningTask()) {
        ed.state.status_message = "No task is running";
        ed.state.mode = if (ed.state.task_manager.visible) .TaskPanel else .Normal;
        ed.markDirty(.partial);
        return;
    }
    ed.runtime.task_worker.cancelRunning();
    ed.state.status_message = "Cancelling task";
    openTaskPanel(ed);
}

fn taskParseErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.EmptyCommand => "Usage: :run <command>",
        error.UnterminatedQuote => "Task command has an unterminated quote",
        error.TrailingEscape => "Task command ends with an incomplete escape",
        else => "Could not parse task command",
    };
}

pub fn openCommentsPanel(ed: *editor.Editor) !void {
    const root = commentsRoot(ed);
    ed.state.comments_panel.visible = true;
    ed.state.comments_panel.focused = true;
    ed.state.todo_panel.visible = false;
    ed.state.todo_panel.focused = false;

    const storage_available = try ensureCommentsWorkspace(ed, root);
    if (storage_available) {
        try refreshCommentsPanel(ed);
    }
    ed.state.comments_panel.clampSelection();
    validateActiveFileComments(ed);
}

pub fn refreshCommentsPanel(ed: *editor.Editor) !void {
    const root = commentsRoot(ed);
    ed.state.comments_panel.load_error = null;
    comments.loadComments(ed.allocator, ed.io, root, &ed.state.comments_panel.store) catch |err| switch (err) {
        error.NoWorkspace => {
            ed.state.comments_panel.load_error = "Comments unavailable: could not create .flamingo workspace";
            ed.state.status_message = "Comments unavailable: could not create .flamingo workspace";
            return;
        },
        error.InvalidWorkspace => {
            ed.state.comments_panel.load_error = "Cannot use workspace comments: .flamingo exists and is not a directory";
            ed.state.status_message = "Cannot use workspace comments: .flamingo exists and is not a directory";
            return;
        },
        error.MalformedCommentsJson => {
            ed.state.comments_panel.load_error = comments.malformed_json_message;
            ed.state.error_message = comments.malformed_json_message;
            return;
        },
        else => return err,
    };
    ed.state.comments_panel.clampSelection();
    validateActiveFileComments(ed);
}

fn ensureCommentsWorkspace(ed: *editor.Editor, root: []const u8) !bool {
    const status = workspace.detectWorkspace(ed.allocator, ed.io, root) catch {
        ed.state.clearWorkspace(ed.allocator);
        ed.state.status_message = "Could not inspect .flamingo workspace";
        ed.state.comments_panel.load_error = "Could not inspect .flamingo workspace";
        return false;
    };

    switch (status) {
        .valid => {
            try ed.state.setWorkspaceRoot(ed.allocator, root);
            return true;
        },
        .invalid_path_exists => {
            ed.state.clearWorkspace(ed.allocator);
            ed.state.status_message = "Cannot use workspace comments: .flamingo exists and is not a directory";
            ed.state.comments_panel.load_error = "Cannot use workspace comments: .flamingo exists and is not a directory";
            return false;
        },
        .none => {
            const result = workspace.createWorkspace(ed.allocator, ed.io, root) catch {
                ed.state.clearWorkspace(ed.allocator);
                ed.state.status_message = "Could not create .flamingo workspace for comments";
                ed.state.comments_panel.load_error = "Comments unavailable: could not create .flamingo workspace";
                return false;
            };
            switch (result) {
                .created, .already_exists => {
                    try ed.state.setWorkspaceRoot(ed.allocator, root);
                    if (result == .created) ed.state.status_message = "Workspace created for comments";
                    return true;
                },
                .invalid_path_exists => {
                    ed.state.clearWorkspace(ed.allocator);
                    ed.state.status_message = "Cannot use workspace comments: .flamingo exists and is not a directory";
                    ed.state.comments_panel.load_error = "Cannot use workspace comments: .flamingo exists and is not a directory";
                    return false;
                },
            }
        },
    }
}

pub fn beginNewCommentFromSelection(ed: *editor.Editor) !void {
    const tab = ed.currentTab() orelse {
        ed.state.error_message = "No active file";
        ed.state.mode = .Normal;
        return;
    };
    const filename = tab.buf.filename orelse {
        ed.state.error_message = "Comments require a saved file";
        ed.state.mode = .Normal;
        return;
    };
    if (!comments.isSupportedFilePath(filename)) {
        ed.state.error_message = comments.unsupported_file_message;
        ed.state.mode = .Normal;
        return;
    }

    try openCommentsPanel(ed);
    if (ed.state.comments_panel.hasLoadError()) {
        ed.state.mode = .Normal;
        return;
    }

    var author = (try comments.resolveAuthor(ed.allocator, ed.io, commentsRoot(ed), &ed.config)) orelse {
        ed.state.error_message = comments.missing_author_message;
        ed.state.mode = .Normal;
        return;
    };
    author.deinit(ed.allocator);

    const cursor = tab.mainCursor().*;
    const range = comments.selectedRange(cursor) orelse {
        ed.state.error_message = "Select text before creating a comment";
        ed.state.mode = .Normal;
        return;
    };
    var anchor = try comments.anchorFromSelection(ed.allocator, &tab.buf, range.start_row, range.start_col, range.end_row, range.end_col);
    errdefer anchor.deinit(ed.allocator);
    if (std.mem.trim(u8, anchor.selected_text, " \t\r\n").len == 0) {
        anchor.deinit(ed.allocator);
        ed.state.error_message = "Select text before creating a comment";
        ed.state.mode = .Normal;
        return;
    }

    const relative_path = try comments.relativeFilePath(ed.allocator, commentsRoot(ed), filename);
    errdefer ed.allocator.free(relative_path);
    ed.state.comments_panel.pending_action.deinit(ed.allocator);
    ed.state.comments_panel.pending_action = .{ .new_thread = .{ .file_path = relative_path, .anchor = anchor } };
    try ed.state.prompt_popup.open(ed.allocator, .comment_new, "Add Comment", anchor.selected_text, "");
    ed.state.mode = .Prompt;
    ed.markDirty(.full);
}

pub fn validateActiveFileComments(ed: *editor.Editor) void {
    const tab = ed.currentTab() orelse return;
    const filename = tab.buf.filename orelse return;
    comments.validateAnchorsForFile(&ed.state.comments_panel.store, ed.state.workspace.root_path, filename, &tab.buf);
}

fn testingTmpRoot(allocator: std.mem.Allocator, tmp: anytype) ![]u8 {
    return std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
}

test ":todos creates missing workspace marker and activates workspace state" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const root = try testingTmpRoot(allocator, tmp);
    defer allocator.free(root);

    var ed = try editor.Editor.init(allocator, io, .{});
    defer ed.deinit();
    try ed.state.setProjectRoot(allocator, root);

    try openTodoPanel(&ed);

    try std.testing.expectEqual(workspace.WorkspaceStatus.valid, try workspace.detectWorkspace(allocator, io, root));
    try std.testing.expect(ed.state.workspace.active);
    try std.testing.expectEqualStrings(root, ed.state.workspace.root_path.?);
    try std.testing.expect(ed.state.todo_panel.visible);
    try std.testing.expect(ed.state.todo_panel.focused);
}

test ":todos lazy workspace creation enables manual todo persistence" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const root = try testingTmpRoot(allocator, tmp);
    defer allocator.free(root);

    var ed = try editor.Editor.init(allocator, io, .{});
    defer ed.deinit();
    try ed.state.setProjectRoot(allocator, root);

    try openTodoPanel(&ed);
    try todos.appendManualTodo(&ed.state.todo_panel, allocator, io, "Write README");
    try todos.saveManualTodos(allocator, io, root, ed.state.todo_panel.manual_items.items);

    _ = try tmp.dir.statFile(io, ".flamingo/todos.json", .{});
}

test ":todos uses existing workspace marker" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, workspace.directory_name);

    const root = try testingTmpRoot(allocator, tmp);
    defer allocator.free(root);

    var ed = try editor.Editor.init(allocator, io, .{});
    defer ed.deinit();
    try ed.state.setProjectRoot(allocator, root);

    try openTodoPanel(&ed);

    try std.testing.expect(ed.state.workspace.active);
    try std.testing.expectEqualStrings(root, ed.state.workspace.root_path.?);
    try std.testing.expectEqual(workspace.WorkspaceStatus.valid, try workspace.detectWorkspace(allocator, io, root));
}

test ":todos does not overwrite invalid workspace marker file" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = workspace.directory_name, .data = "not a directory" });

    const root = try testingTmpRoot(allocator, tmp);
    defer allocator.free(root);

    var ed = try editor.Editor.init(allocator, io, .{});
    defer ed.deinit();
    try ed.state.setProjectRoot(allocator, root);

    try openTodoPanel(&ed);

    const stat = try tmp.dir.statFile(io, workspace.directory_name, .{});
    try std.testing.expectEqual(.file, stat.kind);
    try std.testing.expect(!ed.state.workspace.active);
    try std.testing.expectEqual(workspace.WorkspaceStatus.invalid_path_exists, try workspace.detectWorkspace(allocator, io, root));
    try std.testing.expect(ed.state.status_message != null);
    try std.testing.expect(std.mem.indexOf(u8, ed.state.status_message.?, "not a directory") != null);
}

test "Command registry parses command names" {
    try std.testing.expectEqual(Command.quit, Command.fromString("q").?);
    try std.testing.expectEqual(Command.quit_all, Command.fromString("qall").?);
    try std.testing.expectEqual(Command.quit_all, Command.fromString("qa").?);
    try std.testing.expectEqual(Command.force_quit, Command.fromString("q!").?);
    try std.testing.expectEqual(Command.write, Command.fromString("w").?);
    try std.testing.expectEqual(Command.write_all, Command.fromString("wall").?);
    try std.testing.expectEqual(Command.write_all, Command.fromString("wa").?);
    try std.testing.expectEqual(Command.write_quit, Command.fromString("wq").?);
    try std.testing.expectEqual(Command.search, Command.fromString("search").?);
    try std.testing.expectEqual(Command.help, Command.fromString("help").?);
    try std.testing.expectEqual(Command.todos, Command.fromString("todos").?);
    try std.testing.expectEqual(Command.git_diff, Command.fromString("gitdiff").?);
    try std.testing.expectEqual(Command.agent, Command.fromString("agent").?);
    try std.testing.expectEqual(Command.proposals, Command.fromString("proposals").?);
    try std.testing.expectEqual(Command.run, Command.fromString("run").?);
    try std.testing.expectEqual(Command.tasks, Command.fromString("tasks").?);
    try std.testing.expectEqual(Command.task_stop, Command.fromString("taskstop").?);
    try std.testing.expectEqual(Command.rename_file, Command.fromString("renameFile").?);
    try std.testing.expectEqual(Command.rename_file, Command.fromString("rf").?);
    try std.testing.expectEqual(Command.delete_file, Command.fromString("deleteFile").?);
    try std.testing.expectEqual(Command.delete_file, Command.fromString("df").?);
    try std.testing.expectEqual(Command.new_file, Command.fromString("newFile").?);
    try std.testing.expectEqual(Command.new_file, Command.fromString("nf").?);
    try std.testing.expect(Command.fromString("nope") == null);
}

test "Command parsing agrees with command metadata for executable colon commands" {
    for (commands.commandPopupVisible()) |meta| {
        for (meta.command_names) |name| {
            const parsed = Command.fromString(name) orelse return error.TestExpectedEqual;
            try std.testing.expectEqual(meta.id, parsed.commandId());
        }
        for (meta.aliases) |alias_name| {
            const parsed = Command.fromString(alias_name) orelse return error.TestExpectedEqual;
            try std.testing.expectEqual(meta.id, parsed.commandId());
        }
    }

    try std.testing.expect(Command.fromString("goto") == null);
    try std.testing.expect(Command.fromString("line") == null);
    try std.testing.expect(Command.fromString("<number>") == null);
    try std.testing.expect(Command.fromString("mode.normal") == null);
}
