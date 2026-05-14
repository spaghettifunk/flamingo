const std = @import("std");
const logz = @import("logz");
const terminal = @import("../../terminal.zig");
const editor = @import("../editor.zig");
const buffer = @import("../model/buffer.zig");
const explorer = @import("../explorer.zig");
const global_search = @import("../global_search.zig");
const actions = @import("../actions.zig");
const normal_sequence = @import("normal_sequence.zig");
const navigation = @import("../navigation.zig");
const filesystem_picker = @import("../filesystem_picker.zig");
const fs_ops = @import("../filesystem_ops.zig");
const prompt_popup = @import("../prompt_popup.zig");
const terminal_panel = @import("../terminal_panel.zig");

fn matches(event: terminal.KeyEvent, expected: terminal.KeyEvent) bool {
    if (event.eql(expected)) return true;

    // macOS Option+Delete is commonly delivered by terminals as
    // Alt+Backspace, while the user-facing shortcut is named Alt+Delete.
    if (expected.alt and expected.key == .Delete) {
        var alt_backspace = expected;
        alt_backspace.key = .Backspace;
        return event.eql(alt_backspace);
    }

    // Most terminals encode Ctrl+Shift+letter the same way as Ctrl+letter, so
    // the shift bit can be lost before it reaches the editor.
    if (expected.ctrl and expected.shift and expected.key == .Char and
        expected.char >= 'a' and expected.char <= 'z')
    {
        var without_shift = expected;
        without_shift.shift = false;
        return event.eql(without_shift);
    }

    return false;
}

fn matchesMovement(event: terminal.KeyEvent, expected: terminal.KeyEvent) bool {
    if (matches(event, expected)) return true;

    // Shift extends a selection while preserving the underlying movement key.
    var without_shift = event;
    without_shift.shift = false;
    return event.shift and without_shift.eql(expected);
}

fn clearPendingNormalSequence(ed: *editor.Editor) void {
    ed.state.pending_normal_sequence.clear();
}

fn handleNormalSequence(ed: *editor.Editor, event: terminal.KeyEvent) !bool {
    const had_pending_sequence = ed.state.pending_normal_sequence.len > 0;
    var sequence = ed.state.pending_normal_sequence;
    if (!sequence.append(event)) {
        clearPendingNormalSequence(ed);
        return had_pending_sequence;
    }

    switch (normal_sequence.resolve(sequence)) {
        .command => |command| {
            clearPendingNormalSequence(ed);
            try executeNormalCommand(ed, command);
            return true;
        },
        .prefix => {
            ed.state.pending_normal_sequence = sequence;
            return true;
        },
        .none => {
            clearPendingNormalSequence(ed);
            // Invalid continuations such as "g" then "x" are consumed. We do
            // not redispatch the second key to avoid recursive/double execution.
            return had_pending_sequence;
        },
    }
}

fn executeNormalCommand(ed: *editor.Editor, command: normal_sequence.NormalCommand) !void {
    switch (command) {
        .jump_top => {
            if (ed.currentTab() != null) {
                _ = try navigation.jumpTo(ed, 0, 0, .{ .record_history = true });
            }
        },
        .jump_bottom => {
            if (ed.currentTab()) |tab| {
                const mc = tab.mainCursor();
                const row = if (tab.buf.lines.items.len == 0) 0 else tab.buf.lines.items.len - 1;
                _ = try navigation.jumpTo(ed, row, mc.col, .{ .record_history = true });
            }
        },
        .jump_matching_bracket => {
            if (ed.currentTab()) |tab| {
                const mc = tab.mainCursor();
                if (navigation.findMatchingBracket(&tab.buf, .{ .row = mc.row, .col = mc.col })) |target| {
                    _ = try navigation.jumpTo(ed, target.row, target.col, .{ .record_history = true });
                }
            }
        },
    }
}

const GlobalSearchAction = union(enum) {
    path: []u8,
    content: struct {
        open_path: []u8,
        row: usize,
        col: usize,
    },

    fn deinit(self: *GlobalSearchAction, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .path => |open_path| allocator.free(open_path),
            .content => |action| allocator.free(action.open_path),
        }
    }
};

fn selectedGlobalSearchAction(ed: *editor.Editor) !?GlobalSearchAction {
    const selected = ed.state.global_search.selectedResult() orelse return null;
    return switch (selected) {
        .path => |result| .{ .path = try ed.allocator.dupe(u8, result.open_path) },
        .content => |result| .{ .content = .{
            .open_path = try ed.allocator.dupe(u8, result.open_path),
            .row = result.row,
            .col = result.col,
        } },
    };
}

fn refreshGlobalSearchOrReport(ed: *editor.Editor) !void {
    ed.state.global_search.refresh(ed.allocator, ed.io) catch |err| switch (err) {
        global_search.Error.RootOpenFailed => {
            ed.state.error_message = "Could not search project root";
            ed.state.global_search.clearResults(ed.allocator);
        },
        else => return err,
    };
}

fn acceptGlobalSearchResult(ed: *editor.Editor) !void {
    var action = (try selectedGlobalSearchAction(ed)) orelse {
        ed.state.global_search.close(ed.allocator);
        ed.state.mode = .Normal;
        ed.markDirty(.full);
        return;
    };
    defer action.deinit(ed.allocator);

    ed.state.global_search.close(ed.allocator);
    ed.state.mode = .Normal;

    const open_path = switch (action) {
        .path => |path| path,
        .content => |content| content.open_path,
    };

    if (buffer.Buffer.loadFromFile(ed.allocator, ed.io, open_path)) |loaded| {
        var b = loaded;
        var consumed = false;
        errdefer if (!consumed) b.deinit();
        try navigation.recordCurrentJump(ed);
        try ed.addTab(b);
        consumed = true;
        switch (action) {
            .path => {},
            .content => |content| {
                _ = try navigation.jumpTo(ed, content.row, content.col, .{ .record_history = false });
            },
        }
    } else |err| {
        logz.err().fmt("msg", "failed to open global search file {s}: {s}", .{ open_path, @errorName(err) }).log();
        ed.state.error_message = "Could not open file";
        ed.markDirty(.full);
    }
}

fn pickerStartDir(ed: *editor.Editor) []const u8 {
    if (ed.state.project_root) |root| return root;
    if (ed.state.tree) |tree| return tree.root_path;
    return ".";
}

fn openDashboardPicker(ed: *editor.Editor, mode: filesystem_picker.PickerMode) !void {
    try ed.state.filesystem_picker.open(ed.allocator, ed.io, mode, pickerStartDir(ed));
    ed.state.mode = .FilesystemPicker;
    ed.markDirty(.full);
}

fn applyPickerResult(ed: *editor.Editor, result: filesystem_picker.PickerResult) !void {
    defer result.deinit(ed.allocator);
    switch (result) {
        .open_file => |path| {
            fs_ops.openFileInEditor(ed, path) catch |err| {
                ed.state.filesystem_picker.error_message = fs_ops.userMessage(err);
                return;
            };
        },
        .open_folder => |path| {
            fs_ops.openFolderInEditor(ed, path) catch |err| {
                ed.state.filesystem_picker.error_message = fs_ops.userMessage(err);
                return;
            };
        },
        .create_file => |path| {
            fs_ops.createFileAndOpen(ed, path, false) catch |err| {
                ed.state.filesystem_picker.error_message = fs_ops.userMessage(err);
                return;
            };
        },
    }
    ed.state.filesystem_picker.close(ed.allocator);
    ed.markDirty(.full);
}

fn openExplorerPrompt(ed: *editor.Editor, kind: prompt_popup.PromptKind) !void {
    const tree = if (ed.state.tree) |*tree| tree else return;
    if (tree.search_active) {
        ed.state.error_message = "Finish explorer search before file operations";
        return;
    }
    const node = tree.selectedNode();
    const context_path = switch (kind) {
        .explorer_new_file => tree.selectedBaseDirectory(),
        .explorer_rename, .explorer_delete_confirm => if (node) |n| n.absolute_path else return,
    };
    const title = switch (kind) {
        .explorer_new_file => "New File",
        .explorer_rename => "Rename",
        .explorer_delete_confirm => "Delete",
    };
    const initial = switch (kind) {
        .explorer_rename => std.fs.path.basename(context_path),
        else => "",
    };
    try ed.state.prompt_popup.open(ed.allocator, kind, title, context_path, initial);
    ed.state.mode = .Prompt;
    ed.markDirty(.full);
}

fn promptPath(ed: *editor.Editor, base: []const u8, input: []const u8) ![]u8 {
    if (input.len == 0) return error.EmptyPath;
    if (std.fs.path.isAbsolute(input)) return error.InvalidPath;
    try fs_ops.rejectCommandPath(input);
    const joined = try std.fs.path.join(ed.allocator, &.{ base, input });
    defer ed.allocator.free(joined);
    return fs_ops.resolvePathInsideProjectRoot(ed.allocator, ed.io, ed.state.project_root, joined);
}

fn applyPrompt(ed: *editor.Editor) !void {
    const kind = ed.state.prompt_popup.kind;
    const context = ed.state.prompt_popup.context_path;
    const input_text = ed.state.prompt_popup.input.items;

    switch (kind) {
        .explorer_new_file => {
            const path = promptPath(ed, context, input_text) catch |err| {
                ed.state.prompt_popup.error_message = fs_ops.userMessage(err);
                return;
            };
            defer ed.allocator.free(path);
            fs_ops.createFileAndOpen(ed, path, false) catch |err| {
                ed.state.prompt_popup.error_message = fs_ops.userMessage(err);
                return;
            };
            ed.state.prompt_popup.close(ed.allocator);
            ed.state.mode = .Normal;
        },
        .explorer_rename => {
            const stat = std.Io.Dir.cwd().statFile(ed.io, context, .{}) catch {
                ed.state.prompt_popup.error_message = "File does not exist";
                return;
            };
            if (stat.kind != .file) {
                ed.state.prompt_popup.error_message = "Folder rename is not supported in V1";
                return;
            }
            const parent = std.fs.path.dirname(context) orelse ".";
            const new_path = promptPath(ed, parent, input_text) catch |err| {
                ed.state.prompt_popup.error_message = fs_ops.userMessage(err);
                return;
            };
            defer ed.allocator.free(new_path);
            fs_ops.renameNoOverwrite(ed.io, context, new_path) catch |err| {
                ed.state.prompt_popup.error_message = fs_ops.userMessage(err);
                return;
            };
            try fs_ops.updateOpenBuffersAfterRename(ed, context, new_path);
            fs_ops.refreshExplorerBestEffort(ed, new_path) catch {};
            ed.state.prompt_popup.close(ed.allocator);
            ed.state.mode = .Normal;
        },
        .explorer_delete_confirm => {
            if (fs_ops.isOpenInEditor(ed, context)) {
                ed.state.prompt_popup.error_message = fs_ops.userMessage(error.FileIsOpen);
                return;
            }
            fs_ops.deleteRegularFile(ed.io, context) catch |err| {
                ed.state.prompt_popup.error_message = fs_ops.userMessage(err);
                return;
            };
            fs_ops.refreshExplorerBestEffort(ed, null) catch {};
            ed.state.prompt_popup.close(ed.allocator);
            ed.state.mode = .Normal;
        },
    }
}

fn enterNormalFromTerminal(ed: *editor.Editor) void {
    ed.terminal_panel.blur();
    ed.state.mode = .Normal;
}

fn showAndFocusTerminal(ed: *editor.Editor) !void {
    try ed.terminal_panel.show();
    try ed.terminal_panel.ensureStarted(ed.runtime.event_queue);
    ed.terminal_panel.focus();
    ed.state.explorer_focused = false;
    ed.state.mode = .Terminal;
    ed.markDirty(.full);
}

fn hideTerminal(ed: *editor.Editor) void {
    ed.terminal_panel.hide();
    ed.state.mode = .Normal;
    ed.markDirty(.full);
}

fn cyclePanelFocus(ed: *editor.Editor) !bool {
    const explorer_available = ed.state.explorer_visible;
    const terminal_available = ed.terminal_panel.visible;
    if (!explorer_available and !terminal_available) return false;

    if (explorer_available and terminal_available) {
        if (!ed.state.explorer_focused and !ed.terminal_panel.focused) {
            ed.state.explorer_focused = true;
            ed.terminal_panel.blur();
            if (ed.state.mode == .Terminal) ed.state.mode = .Normal;
        } else if (ed.state.explorer_focused) {
            ed.state.explorer_focused = false;
            try showAndFocusTerminal(ed);
        } else {
            enterNormalFromTerminal(ed);
        }
        ed.markDirty(.full);
        return true;
    }

    if (terminal_available) {
        if (ed.terminal_panel.focused) {
            enterNormalFromTerminal(ed);
        } else {
            try showAndFocusTerminal(ed);
        }
        ed.markDirty(.full);
        return true;
    }

    if (explorer_available) {
        ed.state.explorer_focused = !ed.state.explorer_focused;
        ed.markDirty(.full);
        return true;
    }

    return false;
}

fn handleTerminalInput(ed: *editor.Editor, event: terminal.KeyEvent) !void {
    if (matches(event, ed.keys.normal_mode)) {
        clearPendingNormalSequence(ed);
        enterNormalFromTerminal(ed);
        ed.markDirty(.full);
        return;
    }

    const body_height = ed.terminalPanelHeight() -| 1;
    if (event.key == .PageUp and !event.ctrl and !event.alt) {
        ed.terminal_panel.scrollUp(if (body_height > 0) body_height else 1, body_height);
        ed.markDirty(.partial);
        return;
    }
    if (event.key == .PageDown and !event.ctrl and !event.alt) {
        ed.terminal_panel.scrollDown(if (body_height > 0) body_height else 1, body_height);
        ed.markDirty(.partial);
        return;
    }
    if (event.key == .End and event.shift and !event.ctrl and !event.alt) {
        ed.terminal_panel.scrollToBottom();
        ed.markDirty(.partial);
        return;
    }

    var scratch: [16]u8 = undefined;
    const bytes = terminal_panel.keyEventToInput(event, &scratch) orelse return;
    ed.terminal_panel.scrollToBottom();
    // PTYs normally echo typed bytes. Keep the terminal model output-only here
    // so local input never races with or duplicates shell echo.
    ed.terminal_panel.writeInput(bytes) catch |err| {
        try ed.terminal_panel.appendOutput("\n[terminal input failed: ");
        try ed.terminal_panel.appendOutput(@errorName(err));
        try ed.terminal_panel.appendOutput("]\n");
        ed.markDirty(.partial);
    };
}

pub fn handleInput(ed: *editor.Editor, event: terminal.KeyEvent) !void {
    if (ed.state.error_message != null) {
        ed.state.error_message = null;
    }

    const keys = ed.keys;

    if (matches(event, keys.toggle_terminal)) {
        clearPendingNormalSequence(ed);
        if (ed.terminal_panel.visible) {
            hideTerminal(ed);
        } else {
            try showAndFocusTerminal(ed);
        }
        return;
    }

    if (matches(event, keys.toggle_explorer)) {
        clearPendingNormalSequence(ed);
        if (ed.state.tree == null) {
            ed.state.tree = explorer.Explorer.init(ed.allocator, ed.io, ".") catch null;
        }
        ed.state.explorer_visible = !ed.state.explorer_visible;
        if (ed.state.explorer_visible) {
            ed.state.explorer_focused = true;
            ed.terminal_panel.blur();
            if (ed.state.mode == .Terminal) ed.state.mode = .Normal;
        } else {
            ed.state.explorer_focused = false;
        }
        ed.markDirty(.full);
        return;
    }

    if (matches(event, keys.switch_focus)) {
        clearPendingNormalSequence(ed);
        if (try cyclePanelFocus(ed)) return;
    }

    if (ed.state.mode == .Terminal) {
        try handleTerminalInput(ed, event);
        return;
    }

    if (matches(event, keys.close_tab)) {
        clearPendingNormalSequence(ed);
        if (ed.state.mode != .Dashboard) {
            ed.closeTab();
        }
        return;
    }

    if (ed.state.explorer_focused and ed.state.explorer_visible and ed.state.tree != null and
        (ed.state.mode == .Normal or ed.state.mode == .Insert))
    {
        if (matches(event, keys.explorer_new_file)) {
            clearPendingNormalSequence(ed);
            try openExplorerPrompt(ed, .explorer_new_file);
            return;
        }
        if (matches(event, keys.explorer_rename)) {
            clearPendingNormalSequence(ed);
            try openExplorerPrompt(ed, .explorer_rename);
            return;
        }
        if (matches(event, keys.explorer_delete)) {
            clearPendingNormalSequence(ed);
            try openExplorerPrompt(ed, .explorer_delete_confirm);
            return;
        }
    }

    if (matches(event, keys.next_tab)) {
        clearPendingNormalSequence(ed);
        ed.nextTab();
        return;
    }

    if (matches(event, keys.previous_tab)) {
        clearPendingNormalSequence(ed);
        ed.prevTab();
        return;
    }

    // --- Global Actions (Normal & Insert) ---
    if (ed.state.mode == .Normal or ed.state.mode == .Insert) {
        if (matches(event, keys.select_all)) {
            clearPendingNormalSequence(ed);
            actions.selectAll(ed);
            return;
        }
        if (matches(event, keys.copy)) {
            clearPendingNormalSequence(ed);
            try actions.copy(ed);
            return;
        }
        if (matches(event, keys.cut)) {
            clearPendingNormalSequence(ed);
            try actions.cut(ed);
            return;
        }
        if (matches(event, keys.paste)) {
            clearPendingNormalSequence(ed);
            try actions.paste(ed);
            return;
        }
        if (matches(event, keys.save)) {
            clearPendingNormalSequence(ed);
            if (ed.currentTab()) |tab| {
                if (tab.buf.filename) |f| {
                    try tab.buf.saveToFile(ed.io, f);
                }
            }
            return;
        }
        if (matches(event, keys.undo)) {
            clearPendingNormalSequence(ed);
            try actions.undo(ed);
            return;
        }
        if (matches(event, keys.redo)) {
            clearPendingNormalSequence(ed);
            try actions.redo(ed);
            return;
        }
        if (matches(event, keys.delete_word_back)) {
            clearPendingNormalSequence(ed);
            try actions.deleteWordBack(ed);
            return;
        }
        if (matches(event, keys.duplicate_line)) {
            clearPendingNormalSequence(ed);
            try actions.duplicateLine(ed);
            return;
        }
        if (matches(event, keys.delete_line)) {
            clearPendingNormalSequence(ed);
            try actions.deleteLine(ed);
            return;
        }
        if (matches(event, keys.add_cursor_above)) {
            clearPendingNormalSequence(ed);
            try actions.addCursorAbove(ed);
            return;
        }
        if (matches(event, keys.add_cursor_below)) {
            clearPendingNormalSequence(ed);
            try actions.addCursorBelow(ed);
            return;
        }
        if (matches(event, keys.normal_mode)) {
            clearPendingNormalSequence(ed);
            actions.clearSelections(ed);
            if (ed.state.mode == .Insert) ed.state.mode = .Normal;
            return;
        }
    }

    if (ed.state.explorer_focused and ed.state.explorer_visible and ed.state.tree != null) {
        if (ed.state.mode == .Normal or ed.state.mode == .Insert) {
            if (ed.state.tree.?.search_active) {
                if (matches(event, keys.normal_mode)) {
                    ed.state.tree.?.cancelSearch();
                    return;
                } else if (matches(event, keys.prompt_backspace)) {
                    try ed.state.tree.?.backspaceSearch();
                    return;
                } else if (matches(event, keys.explorer_up)) {
                    ed.state.tree.?.moveUp();
                    return;
                } else if (matches(event, keys.explorer_down)) {
                    ed.state.tree.?.moveDown();
                    return;
                } else if (matches(event, keys.explorer_open)) {
                    if (ed.state.tree.?.selectedSearchResult()) |result| {
                        const path = try ed.allocator.dupe(u8, result.absolute_path);
                        defer ed.allocator.free(path);
                        const is_dir = result.is_dir;

                        try ed.state.tree.?.finishSearch();
                        if (is_dir) {
                            ed.state.tree.?.toggleExpand() catch {};
                        } else {
                            if (buffer.Buffer.loadFromFile(ed.allocator, ed.io, path)) |b| {
                                try navigation.recordCurrentJump(ed);
                                try ed.addTab(b);
                                ed.state.explorer_focused = false;
                                ed.state.mode = .Normal;
                            } else |err| {
                                logz.err().fmt("msg", "failed to open file {s}: {s}", .{ path, @errorName(err) }).log();
                                ed.state.error_message = "Could not open file";
                            }
                        }
                    } else {
                        ed.state.tree.?.finishSearch() catch {};
                    }
                    return;
                } else if (event.key == .Char and !event.ctrl and !event.alt) {
                    try ed.state.tree.?.appendSearchChar(event.char);
                    return;
                }
            } else if (matches(event, keys.search_mode)) {
                try ed.state.tree.?.startSearch();
                return;
            } else if (matches(event, keys.explorer_up)) {
                ed.state.tree.?.moveUp();
                return;
            } else if (matches(event, keys.explorer_down)) {
                ed.state.tree.?.moveDown();
                return;
            } else if (matches(event, keys.explorer_open)) {
                if (ed.state.tree.?.nodes.items.len > 0) {
                    const node = ed.state.tree.?.nodes.items[ed.state.tree.?.selected_index];
                    if (node.is_dir) {
                        ed.state.tree.?.toggleExpand() catch {};
                    } else {
                        if (buffer.Buffer.loadFromFile(ed.allocator, ed.io, node.absolute_path)) |b| {
                            try navigation.recordCurrentJump(ed);
                            try ed.addTab(b);
                            ed.state.explorer_focused = false;
                            ed.state.mode = .Normal;
                        } else |err| {
                            logz.err().fmt("msg", "failed to open file {s}: {s}", .{ node.absolute_path, @errorName(err) }).log();
                            ed.state.error_message = "Could not open file";
                        }
                    }
                }
                return;
            }
        }
    }

    switch (ed.state.mode) {
        .Dashboard => {
            const action =
                if (matches(event, keys.new_file))
                    .NewFile
                else if (matches(event, keys.open_file))
                    .OpenFile
                else if (matches(event, keys.open_folder))
                    .OpenFolder
                else if (matches(event, keys.settings))
                    .Settings
                else if (matches(event, keys.quit))
                    .Quit
                else if (matches(event, keys.dashboard_up)) blk: {
                    ed.state.dash.moveUp();
                    break :blk .None;
                } else if (matches(event, keys.dashboard_down)) blk: {
                    ed.state.dash.moveDown();
                    break :blk .None;
                } else if (matches(event, keys.dashboard_select))
                    ed.state.dash.selectedAction()
                else
                    .None;

            switch (action) {
                .NewFile => {
                    try openDashboardPicker(ed, .new_file_location);
                },
                .OpenFile => {
                    try openDashboardPicker(ed, .open_file);
                },
                .OpenFolder => {
                    try openDashboardPicker(ed, .open_folder);
                },
                .Quit => ed.should_quit = true,
                else => {},
            }
        },
        .Normal => {
            if (matches(event, keys.jump_back)) {
                clearPendingNormalSequence(ed);
                _ = try navigation.jumpBack(ed);
            } else if (matches(event, keys.jump_forward)) {
                clearPendingNormalSequence(ed);
                _ = try navigation.jumpForward(ed);
            } else if (try handleNormalSequence(ed, event)) {
                // Handled
            } else if (try handleMovement(ed, event)) {
                // Handled
            } else if (matches(event, keys.insert_mode)) {
                clearPendingNormalSequence(ed);
                ed.state.mode = .Insert;
            } else if (matches(event, keys.command_mode)) {
                clearPendingNormalSequence(ed);
                ed.state.mode = .Command;
                ed.state.command_buffer.clearRetainingCapacity();
                try ed.state.command_popup.open(ed.allocator);
            } else if (matches(event, keys.search_mode)) {
                clearPendingNormalSequence(ed);
                ed.state.mode = .Search;
                ed.state.search_buffer.clearRetainingCapacity();
                if (ed.state.search_system) |*s| s.clear();
            }

            // Keep cursor within line bounds
            if (ed.currentTab()) |tab| {
                const mc = tab.mainCursor();
                if (mc.row >= tab.buf.lines.items.len) {
                    mc.row = tab.buf.lines.items.len - 1;
                }
                const line = tab.buf.lines.items[mc.row];
                const len = line.len();
                if (mc.col > len) {
                    mc.col = len;
                }
            }
        },
        .Insert => {
            if (try handleMovement(ed, event)) {
                // Handled
            } else if (matches(event, keys.normal_mode)) {
                ed.state.mode = .Normal;
            } else if (matches(event, keys.insert_newline)) {
                if (ed.currentTab()) |tab| {
                    const mc = tab.mainCursor();
                    try tab.buf.insertNewline(mc.row, mc.col);
                    mc.row += 1;
                    mc.col = 0;
                    mc.preferred_col = null;
                }
            } else if (matches(event, keys.delete_back)) {
                if (ed.currentTab()) |tab| {
                    const mc = tab.mainCursor();
                    const row = mc.row;
                    var prev_len: usize = 0;
                    if (row > 0) {
                        prev_len = tab.buf.lines.items[row - 1].len();
                    }

                    if (try tab.buf.deleteCharBack(mc.row, mc.col)) {
                        mc.row -= 1;
                        mc.col = prev_len;
                    } else {
                        if (mc.col > 0) mc.col -= 1;
                    }
                    mc.preferred_col = null;
                }
            } else if (event.key == .Char and !event.ctrl and !event.alt) {
                if (ed.currentTab()) |tab| {
                    const mc = tab.mainCursor();
                    if (matches(event, keys.indent)) {
                        tab.buf.beginUndoGroup();
                        defer tab.buf.endUndoGroup();
                        for (0..4) |_| {
                            try tab.buf.insertChar(mc.row, mc.col, ' ');
                            mc.col += 1;
                        }
                    } else {
                        try tab.buf.insertChar(mc.row, mc.col, event.char);
                        mc.col += 1;
                    }
                    mc.preferred_col = null;
                }
            }
        },
        .Command => {
            if (matches(event, keys.normal_mode)) {
                clearPendingNormalSequence(ed);
                ed.state.mode = .Normal;
                ed.state.command_popup.close();
            } else if (matches(event, keys.prompt_backspace)) {
                try ed.state.command_popup.backspace(ed.allocator);
            } else if (matches(event, keys.indent)) {
                ed.state.command_popup.tabComplete();
            } else if (event.key == .Down) {
                ed.state.command_popup.selectNext();
            } else if (event.key == .Up) {
                ed.state.command_popup.selectPrevious();
            } else if (matches(event, keys.prompt_submit)) {
                try ed.state.command_popup.acceptSelected(ed.allocator);
                const command = @import("../command.zig");
                clearPendingNormalSequence(ed);
                try command.execute(ed);
            } else if (event.key == .Char and !event.ctrl and !event.alt) {
                try ed.state.command_popup.appendChar(ed.allocator, event.char);
            }
        },
        .OpenFilePrompt => {
            if (matches(event, keys.normal_mode)) {
                clearPendingNormalSequence(ed);
                ed.state.mode = .Dashboard;
            } else if (matches(event, keys.prompt_backspace)) {
                if (ed.state.command_buffer.items.len > 0) {
                    ed.state.command_buffer.shrinkRetainingCapacity(ed.state.command_buffer.items.len - 1);
                }
            } else if (matches(event, keys.prompt_submit)) {
                if (ed.state.command_buffer.items.len > 0) {
                    if (buffer.Buffer.loadFromFile(ed.allocator, ed.io, ed.state.command_buffer.items)) |b| {
                        try navigation.recordCurrentJump(ed);
                        try ed.addTab(b);
                        clearPendingNormalSequence(ed);
                        ed.state.mode = .Normal;
                    } else |_| {
                        ed.state.error_message = "Could not open file";
                        clearPendingNormalSequence(ed);
                        ed.state.mode = .Dashboard;
                    }
                } else {
                    clearPendingNormalSequence(ed);
                    ed.state.mode = .Dashboard;
                }
            } else if (event.key == .Char and !event.ctrl and !event.alt) {
                try ed.state.command_buffer.append(ed.allocator, event.char);
            }
        },
        .FilesystemPicker => {
            if (matches(event, keys.normal_mode)) {
                clearPendingNormalSequence(ed);
                ed.state.filesystem_picker.close(ed.allocator);
                ed.state.mode = .Dashboard;
                ed.markDirty(.full);
            } else if (matches(event, keys.prompt_backspace)) {
                try ed.state.filesystem_picker.backspace(ed.allocator, ed.io);
                ed.markDirty(.full);
            } else if (ed.state.filesystem_picker.mode == .new_file_location and ed.state.filesystem_picker.phase == .browsing and event.key == .Char and event.char == ' ' and !event.ctrl and !event.alt) {
                ed.state.filesystem_picker.beginNameInput();
                ed.markDirty(.full);
            } else if (ed.state.filesystem_picker.mode == .open_folder and event.key == .Char and event.char == ' ' and !event.ctrl and !event.alt) {
                if (try ed.state.filesystem_picker.selectFolder(ed.allocator)) |result| {
                    try applyPickerResult(ed, result);
                }
            } else if (event.key == .Up) {
                ed.state.filesystem_picker.moveUp();
                ed.markDirty(.full);
            } else if (event.key == .Down) {
                ed.state.filesystem_picker.moveDown();
                ed.markDirty(.full);
            } else if (matches(event, keys.prompt_submit)) {
                if (try ed.state.filesystem_picker.accept(ed.allocator, ed.io)) |result| {
                    try applyPickerResult(ed, result);
                }
                ed.markDirty(.full);
            } else if (event.key == .Char and !event.ctrl and !event.alt) {
                try ed.state.filesystem_picker.appendChar(ed.allocator, event.char);
                ed.markDirty(.full);
            }
        },
        .Prompt => {
            if (matches(event, keys.normal_mode) or (event.key == .Char and (event.char == 'n' or event.char == 'N') and ed.state.prompt_popup.kind == .explorer_delete_confirm)) {
                clearPendingNormalSequence(ed);
                ed.state.prompt_popup.close(ed.allocator);
                ed.state.mode = .Normal;
                ed.markDirty(.full);
            } else if (ed.state.prompt_popup.kind == .explorer_delete_confirm and event.key == .Char and (event.char == 'y' or event.char == 'Y')) {
                try applyPrompt(ed);
                ed.markDirty(.full);
            } else if (matches(event, keys.prompt_submit)) {
                try applyPrompt(ed);
                ed.markDirty(.full);
            } else if (matches(event, keys.prompt_backspace) and ed.state.prompt_popup.kind != .explorer_delete_confirm) {
                ed.state.prompt_popup.backspace();
                ed.markDirty(.full);
            } else if (event.key == .Char and !event.ctrl and !event.alt and ed.state.prompt_popup.kind != .explorer_delete_confirm) {
                try ed.state.prompt_popup.appendChar(ed.allocator, event.char);
                ed.markDirty(.full);
            }
        },
        .Search => {
            if (matches(event, keys.normal_mode)) {
                clearPendingNormalSequence(ed);
                ed.state.mode = .Normal;
                if (ed.state.search_system) |*s| s.clear();
                ed.state.search_buffer.clearRetainingCapacity();
            } else if (matches(event, keys.prompt_backspace)) {
                if (ed.state.search_buffer.items.len > 0) {
                    ed.state.search_buffer.shrinkRetainingCapacity(ed.state.search_buffer.items.len - 1);
                    if (ed.currentTab()) |tab| {
                        try ed.state.search_system.?.update(&tab.buf, ed.state.search_buffer.items);
                        if (ed.state.search_system.?.getActiveMatch()) |m| {
                            const mc = tab.mainCursor();
                            mc.row = m.row;
                            mc.col = m.col;
                            mc.preferred_col = null;
                            ed.clampScroll();
                        }
                    }
                }
            } else if (matches(event, keys.prompt_submit)) {
                clearPendingNormalSequence(ed);
                ed.state.mode = .Normal;
                if (ed.state.search_system) |*s| s.clear();
                ed.state.search_buffer.clearRetainingCapacity();
            } else if (matches(event, keys.search_next)) {
                if (ed.state.search_system) |*s| {
                    s.nextMatch();
                    if (s.getActiveMatch()) |m| {
                        if (ed.currentTab()) |tab| {
                            const mc = tab.mainCursor();
                            mc.row = m.row;
                            mc.col = m.col;
                            mc.preferred_col = null;
                            ed.clampScroll();
                        }
                    }
                }
            } else if (matches(event, keys.search_previous)) {
                if (ed.state.search_system) |*s| {
                    s.prevMatch();
                    if (s.getActiveMatch()) |m| {
                        if (ed.currentTab()) |tab| {
                            const mc = tab.mainCursor();
                            mc.row = m.row;
                            mc.col = m.col;
                            mc.preferred_col = null;
                            ed.clampScroll();
                        }
                    }
                }
            } else if (event.key == .Char and !event.ctrl and !event.alt) {
                try ed.state.search_buffer.append(ed.allocator, event.char);
                if (ed.currentTab()) |tab| {
                    try ed.state.search_system.?.update(&tab.buf, ed.state.search_buffer.items);
                    if (ed.state.search_system.?.getActiveMatch()) |m| {
                        const mc = tab.mainCursor();
                        mc.row = m.row;
                        mc.col = m.col;
                        mc.preferred_col = null;
                        ed.clampScroll();
                    }
                }
            }
        },
        .GlobalSearch => {
            if (matches(event, keys.normal_mode)) {
                clearPendingNormalSequence(ed);
                ed.state.global_search.close(ed.allocator);
                ed.state.mode = .Normal;
                ed.markDirty(.full);
            } else if (matches(event, keys.prompt_backspace)) {
                if (ed.state.global_search.input.items.len > 0) {
                    ed.state.global_search.input.shrinkRetainingCapacity(ed.state.global_search.input.items.len - 1);
                    try refreshGlobalSearchOrReport(ed);
                    ed.markDirty(.full);
                }
            } else if (matches(event, keys.indent)) {
                ed.state.global_search.selectNext();
                ed.markDirty(.full);
            } else if (event.key == .Down) {
                ed.state.global_search.selectNext();
                ed.markDirty(.full);
            } else if (event.key == .Up) {
                ed.state.global_search.selectPrevious();
                ed.markDirty(.full);
            } else if (matches(event, keys.prompt_submit)) {
                clearPendingNormalSequence(ed);
                try acceptGlobalSearchResult(ed);
            } else if (event.key == .Char and !event.ctrl and !event.alt) {
                try ed.state.global_search.input.append(ed.allocator, event.char);
                try refreshGlobalSearchOrReport(ed);
                ed.markDirty(.full);
            }
        },
        .Terminal => {
            try handleTerminalInput(ed, event);
        },
    }
}

pub fn handleMovement(ed: *editor.Editor, event: terminal.KeyEvent) !bool {
    const tab = ed.currentTab() orelse return false;
    const keys = ed.keys;
    const page_rows = @max(ed.editorVisibleRows(), 1);

    // Multi-cursor support: apply movement to all cursors
    var handled = false;
    for (tab.cursors.items) |*cursor| {
        if (event.shift) {
            if (cursor.selection_start == null) {
                cursor.selection_start = .{ .row = cursor.row, .col = cursor.col };
            }
        } else if (!event.ctrl and !event.alt) {
            // Only clear selection on plain arrows (no modifiers, except shift which extends)
            cursor.selection_start = null;
        }

        if (matchesMovement(event, keys.line_end)) {
            cursor.col = tab.buf.lines.items[cursor.row].len();
            cursor.preferred_col = null;
            handled = true;
        } else if (matchesMovement(event, keys.line_start)) {
            cursor.col = 0;
            cursor.preferred_col = null;
            handled = true;
        } else if (matchesMovement(event, keys.word_left)) {
            try tab.buf.jumpWordLeft(&cursor.row, &cursor.col);
            cursor.preferred_col = null;
            handled = true;
        } else if (matchesMovement(event, keys.word_right)) {
            try tab.buf.jumpWordRight(&cursor.row, &cursor.col);
            cursor.preferred_col = null;
            handled = true;
        } else if (matchesMovement(event, keys.move_up)) {
            const preferred_col = cursor.preferred_col orelse cursor.col;
            cursor.preferred_col = preferred_col;
            if (cursor.row > 0) cursor.row -= 1;
            const new_line_len = tab.buf.lines.items[cursor.row].len();
            cursor.col = @min(preferred_col, new_line_len);
            handled = true;
        } else if (matchesMovement(event, keys.move_down)) {
            const preferred_col = cursor.preferred_col orelse cursor.col;
            cursor.preferred_col = preferred_col;
            if (cursor.row < tab.buf.lines.items.len - 1) cursor.row += 1;
            const new_line_len = tab.buf.lines.items[cursor.row].len();
            cursor.col = @min(preferred_col, new_line_len);
            handled = true;
        } else if (event.key == .PageUp and !event.ctrl and !event.alt) {
            const preferred_col = cursor.preferred_col orelse cursor.col;
            cursor.preferred_col = preferred_col;
            cursor.row = cursor.row -| page_rows;
            const new_line_len = tab.buf.lines.items[cursor.row].len();
            cursor.col = @min(preferred_col, new_line_len);
            handled = true;
        } else if (event.key == .PageDown and !event.ctrl and !event.alt) {
            const preferred_col = cursor.preferred_col orelse cursor.col;
            cursor.preferred_col = preferred_col;
            cursor.row = @min(tab.buf.lines.items.len - 1, cursor.row + page_rows);
            const new_line_len = tab.buf.lines.items[cursor.row].len();
            cursor.col = @min(preferred_col, new_line_len);
            handled = true;
        } else if (matchesMovement(event, keys.move_left)) {
            if (cursor.col > 0) cursor.col -= 1;
            cursor.preferred_col = null;
            handled = true;
        } else if (matchesMovement(event, keys.move_right)) {
            const line = tab.buf.lines.items[cursor.row];
            if (cursor.col < line.len()) cursor.col += 1;
            cursor.preferred_col = null;
            handled = true;
        }
    }

    ed.noteKeypressMovementHandled(handled);
    if (handled) ed.clampScroll();
    return handled;
}
