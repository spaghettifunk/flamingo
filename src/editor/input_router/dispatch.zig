const std = @import("std");
const builtin = @import("builtin");
const logz = @import("logz");
const terminal = @import("../../terminal.zig");
const editor = @import("../editor.zig");
const buffer = @import("../model/buffer.zig");
const explorer = @import("../explorer.zig");
const global_search = @import("../global_search.zig");
const actions = @import("../actions.zig");
const commands = @import("../commands.zig");
const keybindings = @import("../keybindings.zig");
const normal_sequence = @import("normal_sequence.zig");
const navigation = @import("../navigation.zig");
const filesystem_picker = @import("../filesystem_picker.zig");
const fs_ops = @import("../filesystem_ops.zig");
const prompt_popup = @import("../prompt_popup.zig");
const terminal_panel = @import("../terminal_panel.zig");
const todos = @import("../todos.zig");
const comments = @import("../comments.zig");
const multi_cursor = @import("../multi_cursor.zig");
const command_parser = @import("../tasks/command_parser.zig");
const task_mod = @import("../tasks/task.zig");
const agent_mod = @import("../agent/session.zig");
const agent_context_builder = @import("../agent/context_builder.zig");
const execution_pipeline = @import("../agent/execution_pipeline.zig");
const agent_policy = @import("../agent/policy.zig");
const workspace_guard = @import("../agent/workspace_guard.zig");

fn commandAllowedInResolvedContext(context: commands.CommandContext, id: commands.CommandId) bool {
    return switch (context) {
        .command_line => switch (id) {
            .command_cancel,
            .command_backspace,
            .command_suggestion_next,
            .command_suggestion_previous,
            .command_execute,
            => true,
            else => false,
        },
        .search => switch (id) {
            .search_cancel,
            .search_backspace,
            .search_accept,
            .search_next_match,
            .search_previous_match,
            => true,
            else => false,
        },
        .global_search => switch (id) {
            .global_search_cancel,
            .global_search_backspace,
            .global_search_accept,
            .global_search_select_next,
            .global_search_select_previous,
            => true,
            else => false,
        },
        .todo_panel => switch (id) {
            .todo_panel_close,
            .todo_panel_move_up,
            .todo_panel_move_down,
            .todo_panel_refresh,
            .todo_panel_new,
            .todo_panel_edit,
            .todo_panel_delete,
            .todo_panel_toggle,
            .todo_panel_open_selected,
            => true,
            else => false,
        },
        .comments_panel => switch (id) {
            .comments_panel_close,
            .comments_panel_move_up,
            .comments_panel_move_down,
            .comments_panel_refresh,
            .comments_panel_reply,
            .comments_panel_edit,
            .comments_panel_delete,
            .comments_panel_new,
            .comments_panel_open_selected,
            => true,
            else => false,
        },
        .git_graph => switch (id) {
            .git_graph_close,
            .git_graph_move_up,
            .git_graph_move_down,
            .git_graph_page_up,
            .git_graph_page_down,
            .git_graph_first,
            .git_graph_last,
            .git_graph_refresh,
            .git_graph_toggle_details,
            => true,
            else => false,
        },
        .git_diff => switch (id) {
            .git_diff_close,
            .git_diff_move_up,
            .git_diff_move_down,
            .git_diff_page_up,
            .git_diff_page_down,
            .git_diff_refresh_panel,
            .git_diff_open_selected,
            => true,
            else => false,
        },
        .task_panel => switch (id) {
            .task_panel_close,
            .task_panel_scroll_up,
            .task_panel_scroll_down,
            .task_panel_page_up,
            .task_panel_page_down,
            .task_panel_previous_task,
            .task_panel_next_task,
            .task_panel_rerun,
            .task_panel_cancel,
            => true,
            else => false,
        },
        .agent => switch (id) {
            .agent_close,
            .agent_submit,
            .agent_backspace,
            .agent_insert_newline,
            .agent_toggle_mode,
            .agent_cancel,
            .agent_approval_approve,
            .agent_approval_deny,
            .agent_scroll_up,
            .agent_scroll_down,
            .agent_page_up,
            .agent_page_down,
            => true,
            else => false,
        },
        .proposals => switch (id) {
            .proposals_close,
            .proposals_move_up,
            .proposals_move_down,
            .proposals_page_up,
            .proposals_page_down,
            .proposals_previous,
            .proposals_next,
            .proposals_approve_apply,
            .proposals_reject,
            .proposals_open_file,
            => true,
            else => false,
        },
        .explorer => switch (id) {
            .explorer_move_up,
            .explorer_move_down,
            .explorer_open_selected,
            .explorer_search_open,
            .explorer_new_file,
            .explorer_rename,
            .explorer_delete,
            => true,
            else => false,
        },
        .explorer_search => switch (id) {
            .explorer_search_cancel,
            .explorer_search_backspace,
            .explorer_move_up,
            .explorer_move_down,
            .explorer_open_selected,
            => true,
            else => false,
        },
        .dashboard => switch (id) {
            .mode_command,
            .dashboard_new_file,
            .dashboard_open_file,
            .dashboard_open_folder,
            .dashboard_create_workspace,
            .dashboard_settings,
            .dashboard_move_up,
            .dashboard_move_down,
            .dashboard_select,
            .app_quit_flamingo,
            => true,
            else => false,
        },
        .picker => switch (id) {
            .picker_cancel,
            .picker_back,
            .picker_move_up,
            .picker_move_down,
            .picker_accept,
            => true,
            else => false,
        },
        .picker_new_file => switch (id) {
            .picker_begin_name_input => true,
            else => false,
        },
        .picker_open_folder => switch (id) {
            .picker_select_folder,
            .picker_select_current_folder,
            => true,
            else => false,
        },
        .open_file_prompt => switch (id) {
            .open_file_prompt_cancel,
            .open_file_prompt_backspace,
            .open_file_prompt_submit,
            => true,
            else => false,
        },
        .insert => switch (id) {
            .mode_normal,
            .editing_insert_newline,
            .editing_delete_back,
            .editing_indent,
            .file_write,
            .editing_undo,
            .editing_redo,
            .editing_select_all,
            .editing_copy,
            .editing_cut,
            .editing_paste,
            .editing_delete_word_back,
            .editing_duplicate_line,
            .editing_delete_line,
            .editing_add_cursor_above,
            .editing_add_cursor_below,
            .navigation_move_up,
            .navigation_move_down,
            .navigation_move_left,
            .navigation_move_right,
            .navigation_page_up,
            .navigation_page_down,
            .navigation_line_start,
            .navigation_line_end,
            .navigation_word_left,
            .navigation_word_right,
            .completion_auto_trigger,
            .completion_trigger,
            => true,
            else => false,
        },
        .terminal => switch (id) {
            .terminal_unfocus,
            .terminal_scroll_page_up,
            .terminal_scroll_page_down,
            .terminal_scroll_bottom,
            => true,
            else => false,
        },
        .help => switch (id) {
            .help_close,
            .help_scroll_up,
            .help_scroll_down,
            .help_page_up,
            .help_page_down,
            => true,
            else => false,
        },
        .prompt => switch (id) {
            .prompt_cancel,
            .prompt_confirm,
            .prompt_submit,
            .prompt_backspace,
            => true,
            else => false,
        },
        .save_confirmation => switch (id) {
            .save_confirmation_save,
            .save_confirmation_discard,
            .save_confirmation_cancel,
            => true,
            else => false,
        },
        else => false,
    };
}

fn resolveDefaultContextCommand(ed: *const editor.Editor, context: commands.CommandContext, event: terminal.KeyEvent) ?commands.CommandId {
    const result = ed.keybinding_registry.resolve(context, keybindings.KeySequence.fromEvent(event));
    const id = switch (result) {
        .command => |id| id,
        else => return null,
    };
    return if (commandAllowedInResolvedContext(context, id)) id else null;
}

fn resolveRegistryCommand(ed: *const editor.Editor, context: commands.CommandContext, event: terminal.KeyEvent) ?commands.CommandId {
    return switch (context) {
        .normal => normal_sequence.resolveActionCommand(&ed.keybinding_registry, event),
        .global => normal_sequence.resolveGlobalActionCommand(&ed.keybinding_registry, event),
        .command_line,
        .search,
        .global_search,
        .todo_panel,
        .comments_panel,
        .git_graph,
        .git_diff,
        .task_panel,
        .agent,
        .explorer,
        .explorer_search,
        .dashboard,
        .picker,
        .picker_new_file,
        .picker_open_folder,
        .open_file_prompt,
        .insert,
        .terminal,
        .help,
        .prompt,
        .save_confirmation,
        => resolveDefaultContextCommand(ed, context, event),
        else => null,
    };
}

fn registryCommandMatches(ed: *const editor.Editor, context: commands.CommandContext, event: terminal.KeyEvent, id: commands.CommandId) bool {
    return (resolveRegistryCommand(ed, context, event) orelse return false) == id;
}

fn resolveNormalMovementCommand(ed: *editor.Editor, event: terminal.KeyEvent) ?commands.CommandId {
    return normal_sequence.resolveMovementCommand(&ed.keybinding_registry, event);
}

fn resolveInsertMovementCommand(ed: *editor.Editor, event: terminal.KeyEvent) ?commands.CommandId {
    if (resolveDefaultContextCommand(ed, .insert, event)) |command| {
        if (switch (command) {
            .navigation_line_end,
            .navigation_line_start,
            .navigation_word_left,
            .navigation_word_right,
            .navigation_move_up,
            .navigation_move_down,
            .navigation_page_up,
            .navigation_page_down,
            .navigation_move_left,
            .navigation_move_right,
            => true,
            else => false,
        }) return command;
    }
    return null;
}

fn resolveNormalJumpCommand(ed: *editor.Editor, event: terminal.KeyEvent) ?commands.CommandId {
    return normal_sequence.resolveJumpCommand(&ed.keybinding_registry, event);
}

fn movementCommandForEvent(ed: *editor.Editor, event: terminal.KeyEvent) ?commands.CommandId {
    if (ed.state.mode == .Normal) {
        return resolveNormalMovementCommand(ed, event);
    }
    if (ed.state.mode == .Insert) {
        return resolveInsertMovementCommand(ed, event);
    }
    return null;
}

fn normalSharedActionCommandForEvent(ed: *editor.Editor, event: terminal.KeyEvent) ?commands.CommandId {
    const context: commands.CommandContext = if (ed.state.mode == .Insert) .insert else .normal;
    const command = resolveRegistryCommand(ed, context, event) orelse return null;
    return switch (command) {
        .editing_select_all,
        .editing_copy,
        .editing_cut,
        .editing_paste,
        .file_write,
        .editing_undo,
        .editing_redo,
        .editing_delete_word_back,
        .editing_duplicate_line,
        .editing_delete_line,
        .editing_add_cursor_above,
        .editing_add_cursor_below,
        .editing_select_next_occurrence,
        .mode_normal,
        => command,
        else => null,
    };
}

fn normalModeActionCommandForEvent(ed: *editor.Editor, event: terminal.KeyEvent) ?commands.CommandId {
    const command = resolveRegistryCommand(ed, .normal, event) orelse return null;
    return switch (command) {
        .mode_insert,
        .mode_command,
        .mode_search,
        .completion_auto_trigger,
        .completion_trigger,
        => command,
        else => null,
    };
}

fn commandLineActionCommandForEvent(ed: *editor.Editor, event: terminal.KeyEvent) ?commands.CommandId {
    return resolveDefaultContextCommand(ed, .command_line, event);
}

fn searchActionCommandForEvent(ed: *editor.Editor, event: terminal.KeyEvent) ?commands.CommandId {
    return resolveDefaultContextCommand(ed, .search, event);
}

fn globalSearchActionCommandForEvent(ed: *editor.Editor, event: terminal.KeyEvent) ?commands.CommandId {
    return resolveDefaultContextCommand(ed, .global_search, event);
}

fn todoPanelActionCommandForEvent(ed: *editor.Editor, event: terminal.KeyEvent) ?commands.CommandId {
    return resolveDefaultContextCommand(ed, .todo_panel, event);
}

fn commentsPanelActionCommandForEvent(ed: *editor.Editor, event: terminal.KeyEvent) ?commands.CommandId {
    return resolveDefaultContextCommand(ed, .comments_panel, event);
}

const GitGraphInputResult = union(enum) {
    none,
    prefix,
    command: commands.CommandId,
};

fn gitGraphActionCommandForEvent(ed: *editor.Editor, event: terminal.KeyEvent) GitGraphInputResult {
    var sequence = ed.state.git_graph_panel.pending_sequence;
    if (!sequence.append(event)) {
        ed.state.git_graph_panel.pending_sequence.clear();
        return .none;
    }

    switch (ed.keybinding_registry.resolve(.git_graph, sequence)) {
        .command => |command| {
            ed.state.git_graph_panel.pending_sequence.clear();
            return if (commandAllowedInResolvedContext(.git_graph, command))
                .{ .command = command }
            else
                .none;
        },
        .prefix => {
            ed.state.git_graph_panel.pending_sequence = sequence;
            return .prefix;
        },
        .none => {
            ed.state.git_graph_panel.pending_sequence.clear();
            return .none;
        },
    }
}

fn gitDiffActionCommandForEvent(ed: *editor.Editor, event: terminal.KeyEvent) ?commands.CommandId {
    return resolveDefaultContextCommand(ed, .git_diff, event);
}

fn taskPanelActionCommandForEvent(ed: *editor.Editor, event: terminal.KeyEvent) ?commands.CommandId {
    return resolveDefaultContextCommand(ed, .task_panel, event);
}

fn agentActionCommandForEvent(ed: *editor.Editor, event: terminal.KeyEvent) ?commands.CommandId {
    return resolveDefaultContextCommand(ed, .agent, event);
}

fn proposalsActionCommandForEvent(ed: *editor.Editor, event: terminal.KeyEvent) ?commands.CommandId {
    return resolveDefaultContextCommand(ed, .proposals, event);
}

fn explorerFileActionCommandForEvent(ed: *editor.Editor, event: terminal.KeyEvent) ?commands.CommandId {
    const command = resolveDefaultContextCommand(ed, .explorer, event) orelse return null;
    return switch (command) {
        .explorer_new_file,
        .explorer_rename,
        .explorer_delete,
        => command,
        else => null,
    };
}

fn explorerActionCommandForEvent(ed: *editor.Editor, event: terminal.KeyEvent) ?commands.CommandId {
    return resolveDefaultContextCommand(ed, .explorer, event);
}

fn explorerSearchActionCommandForEvent(ed: *editor.Editor, event: terminal.KeyEvent) ?commands.CommandId {
    return resolveDefaultContextCommand(ed, .explorer_search, event);
}

fn dashboardActionCommandForEvent(ed: *editor.Editor, event: terminal.KeyEvent) ?commands.CommandId {
    return resolveDefaultContextCommand(ed, .dashboard, event);
}

fn pickerActionCommandForEvent(ed: *editor.Editor, event: terminal.KeyEvent) ?commands.CommandId {
    return resolveDefaultContextCommand(ed, .picker, event);
}

fn pickerNewFileActionCommandForEvent(ed: *editor.Editor, event: terminal.KeyEvent) ?commands.CommandId {
    return if (registryCommandMatches(ed, .picker_new_file, event, .picker_begin_name_input))
        .picker_begin_name_input
    else
        null;
}

fn pickerOpenFolderActionCommandForEvent(ed: *editor.Editor, event: terminal.KeyEvent) ?commands.CommandId {
    return if (registryCommandMatches(ed, .picker_open_folder, event, .picker_select_folder))
        .picker_select_folder
    else if (registryCommandMatches(ed, .picker_open_folder, event, .picker_select_current_folder))
        .picker_select_current_folder
    else
        null;
}

fn openFilePromptActionCommandForEvent(ed: *editor.Editor, event: terminal.KeyEvent) ?commands.CommandId {
    return resolveDefaultContextCommand(ed, .open_file_prompt, event);
}

fn insertActionCommandForEvent(ed: *editor.Editor, event: terminal.KeyEvent) ?commands.CommandId {
    const command = resolveDefaultContextCommand(ed, .insert, event) orelse return null;
    return switch (command) {
        .editing_insert_newline, .editing_delete_back, .editing_indent => command,
        else => null,
    };
}

fn terminalActionCommandForEvent(ed: *editor.Editor, event: terminal.KeyEvent) ?commands.CommandId {
    return resolveDefaultContextCommand(ed, .terminal, event);
}

fn helpActionCommandForEvent(ed: *editor.Editor, event: terminal.KeyEvent) ?commands.CommandId {
    return resolveDefaultContextCommand(ed, .help, event);
}

fn promptActionCommandForEvent(ed: *editor.Editor, event: terminal.KeyEvent) ?commands.CommandId {
    const is_delete_confirm = ed.state.prompt_popup.kind == .explorer_delete_confirm or
        ed.state.prompt_popup.kind == .todo_delete_confirm or
        ed.state.prompt_popup.kind == .comment_delete_confirm;
    const command = resolveDefaultContextCommand(ed, .prompt, event) orelse return null;
    return switch (command) {
        .prompt_cancel => if (is_delete_confirm or !isPlainPromptNoKey(event)) .prompt_cancel else null,
        .prompt_confirm => if (is_delete_confirm) .prompt_confirm else null,
        .prompt_submit => .prompt_submit,
        .prompt_backspace => if (is_delete_confirm) null else .prompt_backspace,
        else => null,
    };
}

fn isPlainPromptNoKey(event: terminal.KeyEvent) bool {
    return event.key == .Char and !event.ctrl and !event.alt and !event.shift and
        (event.char == 'n' or event.char == 'N');
}

fn saveConfirmationActionCommandForEvent(ed: *editor.Editor, event: terminal.KeyEvent) ?commands.CommandId {
    return resolveDefaultContextCommand(ed, .save_confirmation, event);
}

fn clearPendingNormalSequence(ed: *editor.Editor) void {
    ed.state.pending_normal_sequence.clear();
}

fn clearCurrentMultiCursor(ed: *editor.Editor) void {
    if (ed.currentTab()) |tab| {
        tab.multi_cursor.clear(ed.allocator);
    }
}

fn applyPrimaryCursorPosition(tab: *editor.Tab, pos: multi_cursor.CursorPosition) void {
    const mc = tab.mainCursor();
    mc.row = @min(pos.row, tab.buf.lines.items.len - 1);
    mc.col = @min(pos.col, tab.buf.lines.items[mc.row].len());
    mc.selection_start = null;
    mc.preferred_col = null;
}

fn clampMultiCursor(tab: *editor.Tab, cursor: *multi_cursor.CursorPosition) void {
    if (tab.buf.lines.items.len == 0) {
        cursor.row = 0;
        cursor.col = 0;
        return;
    }
    cursor.row = @min(cursor.row, tab.buf.lines.items.len - 1);
    cursor.row = tab.buf.clampToVisibleLine(cursor.row);
    cursor.col = @min(cursor.col, tab.buf.lines.items[cursor.row].len());
}

fn moveMultiCursor(tab: *editor.Tab, cursor: *multi_cursor.CursorPosition, movement_command: commands.CommandId, page_rows: usize) !void {
    clampMultiCursor(tab, cursor);
    if (movement_command == .navigation_line_end) {
        cursor.col = tab.buf.lines.items[cursor.row].len();
    } else if (movement_command == .navigation_line_start) {
        cursor.col = 0;
    } else if (movement_command == .navigation_word_left) {
        try tab.buf.jumpWordLeft(&cursor.row, &cursor.col);
    } else if (movement_command == .navigation_word_right) {
        try tab.buf.jumpWordRight(&cursor.row, &cursor.col);
    } else if (movement_command == .navigation_move_up) {
        const preferred_col = cursor.col;
        cursor.row = tab.buf.prevVisibleLine(cursor.row);
        cursor.col = @min(preferred_col, tab.buf.lines.items[cursor.row].len());
    } else if (movement_command == .navigation_move_down) {
        const preferred_col = cursor.col;
        cursor.row = tab.buf.nextVisibleLine(cursor.row);
        cursor.col = @min(preferred_col, tab.buf.lines.items[cursor.row].len());
    } else if (movement_command == .navigation_page_up) {
        const preferred_col = cursor.col;
        for (0..page_rows) |_| {
            const next = tab.buf.prevVisibleLine(cursor.row);
            if (next == cursor.row) break;
            cursor.row = next;
        }
        cursor.col = @min(preferred_col, tab.buf.lines.items[cursor.row].len());
    } else if (movement_command == .navigation_page_down) {
        const preferred_col = cursor.col;
        for (0..page_rows) |_| {
            const next = tab.buf.nextVisibleLine(cursor.row);
            if (next == cursor.row) break;
            cursor.row = next;
        }
        cursor.col = @min(preferred_col, tab.buf.lines.items[cursor.row].len());
    } else if (movement_command == .navigation_move_left) {
        if (cursor.col > 0) cursor.col -= 1;
    } else if (movement_command == .navigation_move_right) {
        if (cursor.col < tab.buf.lines.items[cursor.row].len()) cursor.col += 1;
    }
    clampMultiCursor(tab, cursor);
}

fn handleActiveMultiCursorMovement(ed: *editor.Editor, tab: *editor.Tab, movement_command: commands.CommandId, page_rows: usize) !bool {
    if (!tab.multi_cursor.active) return false;

    if (tab.multi_cursor.hasSelections()) {
        const edge: multi_cursor.SelectionEdge = switch (movement_command) {
            .navigation_move_left => .start,
            else => .end,
        };
        const pos = try multi_cursor.syncCursorsToSelections(ed.allocator, &tab.multi_cursor, edge, true);
        if (movement_command == .navigation_move_left or movement_command == .navigation_move_right) {
            if (pos) |cursor_pos| applyPrimaryCursorPosition(tab, cursor_pos);
            ed.noteKeypressMovementHandled(true);
            ed.clampScroll();
            return true;
        }
    }

    if (!tab.multi_cursor.hasCursors()) return false;
    for (tab.multi_cursor.cursors.items) |*cursor| {
        try moveMultiCursor(tab, cursor, movement_command, page_rows);
    }
    multi_cursor.dedupeSortedCursors(&tab.multi_cursor);
    if (tab.multi_cursor.cursors.items.len > 0) {
        applyPrimaryCursorPosition(tab, tab.multi_cursor.cursors.items[tab.multi_cursor.cursors.items.len - 1]);
    }
    ed.noteKeypressMovementHandled(true);
    ed.clampScroll();
    return true;
}

fn selectNextOccurrence(ed: *editor.Editor) !void {
    if (ed.currentTab()) |tab| {
        const mc = tab.mainCursor();
        const range = if (mc.selection_start) |ss|
            multi_cursor.normalizedSelection(ss.row, ss.col, mc.row, mc.col)
        else
            multi_cursor.wordSelectionAtCursor(&tab.buf, mc.row, mc.col) orelse return;
        if (try multi_cursor.beginSelectNextOccurrence(ed.allocator, &tab.multi_cursor, &tab.buf, tab.syntax_buffer_id, range)) {
            if (tab.multi_cursor.selections.items.len > 0) {
                const last = tab.multi_cursor.selections.items[tab.multi_cursor.selections.items.len - 1];
                mc.row = last.end_line;
                mc.col = last.end_col;
                mc.selection_start = .{ .row = last.start_line, .col = last.start_col };
                mc.preferred_col = null;
            }
        }
    }
}

fn handleNormalSequence(ed: *editor.Editor, event: terminal.KeyEvent) !bool {
    const had_pending_sequence = ed.state.pending_normal_sequence.len > 0;
    var sequence = ed.state.pending_normal_sequence;
    if (!sequence.append(event)) {
        clearPendingNormalSequence(ed);
        return had_pending_sequence;
    }

    switch (normal_sequence.resolve(&ed.keybinding_registry, sequence)) {
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
        .jump_to_function_definition => try ed.requestDefinitionAtCursor(),
        .scroll_left_small => ed.applyHorizontalScrollCommand(.left_small),
        .scroll_right_small => ed.applyHorizontalScrollCommand(.right_small),
        .scroll_left_half => ed.applyHorizontalScrollCommand(.left_half),
        .scroll_right_half => ed.applyHorizontalScrollCommand(.right_half),
        .scroll_cursor_start => ed.applyHorizontalScrollCommand(.cursor_start),
        .scroll_cursor_end => ed.applyHorizontalScrollCommand(.cursor_end),
        .fold_current => {
            if (ed.currentTab()) |tab| {
                const mc = tab.mainCursor();
                try tab.buf.foldCurrentBraceBlock(mc.row, mc.col);
                clampAfterFoldChange(ed);
            }
        },
        .unfold_current => {
            if (ed.currentTab()) |tab| {
                const mc = tab.mainCursor();
                tab.buf.unfoldCurrentBraceBlock(mc.row, mc.col);
                clampAfterFoldChange(ed);
            }
        },
        .toggle_fold_current => {
            if (ed.currentTab()) |tab| {
                const mc = tab.mainCursor();
                try tab.buf.toggleCurrentBraceBlock(mc.row, mc.col);
                clampAfterFoldChange(ed);
            }
        },
        .fold_all => {
            if (ed.currentTab()) |tab| {
                try tab.buf.foldAllBraceBlocks();
                clampAfterFoldChange(ed);
            }
        },
        .unfold_all => {
            if (ed.currentTab()) |tab| {
                tab.buf.unfoldAllBraceBlocks();
                clampAfterFoldChange(ed);
            }
        },
        .toggle_fold_all => {
            if (ed.currentTab()) |tab| {
                try tab.buf.toggleAllBraceBlocks();
                clampAfterFoldChange(ed);
            }
        },
        .next_comment => try jumpCommentAnchor(ed, .next),
        .previous_comment => try jumpCommentAnchor(ed, .previous),
    }
}

const CommentJumpDirection = enum { next, previous };

fn commentPanelRowForThread(panel: *const comments.CommentsPanel, thread_index: usize) ?usize {
    var row: usize = 0;
    for (panel.store.threads.items, 0..) |thread, index| {
        if (index == thread_index) return row;
        row += 1 + thread.comments.items.len;
    }
    return null;
}

fn jumpCommentAnchor(ed: *editor.Editor, direction: CommentJumpDirection) !void {
    const tab = ed.currentTab() orelse return;
    const filename = tab.buf.filename orelse return;
    {
        const command_module = @import("../command.zig");
        command_module.validateActiveFileComments(ed);
    }
    const mc = tab.mainCursor();
    var best_index: ?usize = null;
    var best_row: usize = 0;
    var best_col: usize = 0;
    var wrap_index: ?usize = null;
    var wrap_row: usize = 0;
    var wrap_col: usize = 0;

    for (ed.state.comments_panel.store.threads.items, 0..) |thread, thread_index| {
        if (!comments.pathMatchesThread(ed.state.workspace.root_path, filename, thread.file_path)) continue;
        if (thread.anchor.start_line == 0 or thread.anchor.start_col == 0) continue;
        const row = thread.anchor.start_line - 1;
        const col = thread.anchor.start_col - 1;
        const after_cursor = row > mc.row or (row == mc.row and col > mc.col);
        const before_cursor = row < mc.row or (row == mc.row and col < mc.col);
        switch (direction) {
            .next => {
                if (wrap_index == null or row < wrap_row or (row == wrap_row and col < wrap_col)) {
                    wrap_index = thread_index;
                    wrap_row = row;
                    wrap_col = col;
                }
                if (after_cursor and (best_index == null or row < best_row or (row == best_row and col < best_col))) {
                    best_index = thread_index;
                    best_row = row;
                    best_col = col;
                }
            },
            .previous => {
                if (wrap_index == null or row > wrap_row or (row == wrap_row and col > wrap_col)) {
                    wrap_index = thread_index;
                    wrap_row = row;
                    wrap_col = col;
                }
                if (before_cursor and (best_index == null or row > best_row or (row == best_row and col > best_col))) {
                    best_index = thread_index;
                    best_row = row;
                    best_col = col;
                }
            },
        }
    }

    const target_index = best_index orelse wrap_index orelse {
        ed.state.status_message = "No comments in current file";
        return;
    };
    const target = ed.state.comments_panel.store.threads.items[target_index];
    _ = try navigation.jumpTo(ed, target.anchor.start_line -| 1, target.anchor.start_col -| 1, .{ .record_history = true });
    if (commentPanelRowForThread(&ed.state.comments_panel, target_index)) |row| {
        ed.state.comments_panel.selected_row = row;
    }
}

fn clampAfterFoldChange(ed: *editor.Editor) void {
    const tab = ed.currentTab() orelse return;
    for (tab.cursors.items) |*cursor| {
        cursor.row = tab.buf.clampToVisibleLine(cursor.row);
        cursor.col = @min(cursor.col, tab.buf.lines.items[cursor.row].len());
        cursor.preferred_col = null;
        if (cursor.selection_start) |selection_start| {
            const row = tab.buf.clampToVisibleLine(selection_start.row);
            cursor.selection_start = .{
                .row = row,
                .col = @min(selection_start.col, tab.buf.lines.items[row].len()),
            };
        }
    }
    tab.scroll_row = tab.buf.clampToVisibleLine(tab.scroll_row);
    ed.clampScroll();
    ed.markDirty(.full);
}

fn saveCurrentFile(ed: *editor.Editor) !void {
    try ed.saveCurrentBuffer();
}

fn executeSharedActionCommand(ed: *editor.Editor, command: commands.CommandId) !void {
    clearPendingNormalSequence(ed);
    switch (command) {
        .editing_select_all => {
            clearCurrentMultiCursor(ed);
            actions.selectAll(ed);
        },
        .editing_copy => try actions.copy(ed),
        .editing_cut => {
            clearCurrentMultiCursor(ed);
            try actions.cut(ed);
        },
        .editing_paste => {
            clearCurrentMultiCursor(ed);
            try actions.paste(ed);
        },
        .file_write => saveCurrentFile(ed) catch |err| {
            if (err != error.InvalidConfig) ed.state.error_message = "Failed to save file";
        },
        .editing_undo => {
            clearCurrentMultiCursor(ed);
            try actions.undo(ed);
        },
        .editing_redo => {
            clearCurrentMultiCursor(ed);
            try actions.redo(ed);
        },
        .editing_delete_word_back => {
            clearCurrentMultiCursor(ed);
            try actions.deleteWordBack(ed);
        },
        .editing_duplicate_line => {
            clearCurrentMultiCursor(ed);
            try actions.duplicateLine(ed);
        },
        .editing_delete_line => {
            clearCurrentMultiCursor(ed);
            try actions.deleteLine(ed);
        },
        .editing_add_cursor_above => {
            clearCurrentMultiCursor(ed);
            try actions.addCursorAbove(ed);
        },
        .editing_add_cursor_below => {
            clearCurrentMultiCursor(ed);
            try actions.addCursorBelow(ed);
        },
        .editing_select_next_occurrence => try selectNextOccurrence(ed),
        .mode_normal => {
            clearCurrentMultiCursor(ed);
            actions.clearSelections(ed);
            if (ed.state.mode == .Insert) ed.state.mode = .Normal;
        },
        else => unreachable,
    }
}

fn executeNormalModeActionCommand(ed: *editor.Editor, command: commands.CommandId) !void {
    clearPendingNormalSequence(ed);
    switch (command) {
        .mode_insert => {
            if (ed.currentTab()) |tab| {
                if (tab.multi_cursor.hasSelections()) {
                    if (try multi_cursor.syncCursorsToSelections(ed.allocator, &tab.multi_cursor, .end, false)) |pos| {
                        applyPrimaryCursorPosition(tab, pos);
                    }
                }
            }
            ed.state.mode = .Insert;
        },
        .mode_command => {
            clearCurrentMultiCursor(ed);
            ed.state.mode = .Command;
            ed.state.command_buffer.clearRetainingCapacity();
            try ed.state.command_popup.open(ed.allocator);
        },
        .mode_search => {
            clearCurrentMultiCursor(ed);
            ed.state.mode = .Search;
            ed.state.search_buffer.clearRetainingCapacity();
            if (ed.state.search_system) |*s| s.clear();
            ed.markDirty(.full);
        },
        .completion_auto_trigger, .completion_trigger => {},
        else => unreachable,
    }
}

fn executeCommandLineActionCommand(ed: *editor.Editor, command: commands.CommandId) !void {
    switch (command) {
        .command_cancel => {
            clearPendingNormalSequence(ed);
            ed.state.mode = .Normal;
            ed.state.command_popup.close();
        },
        .command_backspace => try ed.state.command_popup.backspace(ed.allocator),
        .command_suggestion_next => ed.state.command_popup.tabComplete(),
        .command_suggestion_previous => ed.state.command_popup.selectPrevious(),
        .command_execute => {
            try ed.state.command_popup.acceptSelected(ed.allocator);
            const command_module = @import("../command.zig");
            clearPendingNormalSequence(ed);
            try command_module.execute(ed);
        },
        else => unreachable,
    }
}

fn closeSearch(ed: *editor.Editor) void {
    clearPendingNormalSequence(ed);
    ed.state.mode = .Normal;
    if (ed.state.search_system) |*s| s.clear();
    ed.state.search_buffer.clearRetainingCapacity();
    ed.markDirty(.full);
}

fn moveCursorToActiveSearchMatch(ed: *editor.Editor) void {
    if (ed.state.search_system) |*search_system| {
        const match = search_system.getActiveMatch() orelse return;
        const tab = ed.currentTab() orelse return;
        const mc = tab.mainCursor();
        mc.row = tab.buf.clampToVisibleLine(match.row);
        mc.col = @min(match.col, tab.buf.lines.items[mc.row].len());
        mc.preferred_col = null;
        ed.clampScroll();
    }
}

fn refreshSearchFromBuffer(ed: *editor.Editor) !void {
    if (ed.currentTab()) |tab| {
        try ed.state.search_system.?.update(&tab.buf, ed.state.search_buffer.items);
        moveCursorToActiveSearchMatch(ed);
    }
}

fn executeSearchActionCommand(ed: *editor.Editor, command: commands.CommandId) !void {
    switch (command) {
        .search_cancel, .search_accept => closeSearch(ed),
        .search_backspace => {
            if (ed.state.search_buffer.items.len > 0) {
                ed.state.search_buffer.shrinkRetainingCapacity(ed.state.search_buffer.items.len - 1);
                try refreshSearchFromBuffer(ed);
                ed.markDirty(.full);
            }
        },
        .search_next_match => {
            if (ed.state.search_system) |*s| {
                s.nextMatch();
                moveCursorToActiveSearchMatch(ed);
                ed.markDirty(.partial);
            }
        },
        .search_previous_match => {
            if (ed.state.search_system) |*s| {
                s.prevMatch();
                moveCursorToActiveSearchMatch(ed);
                ed.markDirty(.partial);
            }
        },
        else => unreachable,
    }
}

fn executeGlobalSearchActionCommand(ed: *editor.Editor, command: commands.CommandId) !void {
    switch (command) {
        .global_search_cancel => {
            clearPendingNormalSequence(ed);
            ed.state.global_search.close(ed.allocator);
            ed.state.mode = .Normal;
            ed.markDirty(.full);
        },
        .global_search_backspace => {
            if (ed.state.global_search.input.items.len > 0) {
                ed.state.global_search.input.shrinkRetainingCapacity(ed.state.global_search.input.items.len - 1);
                try refreshGlobalSearchOrReport(ed);
                ed.markDirty(.full);
            }
        },
        .global_search_select_next => {
            ed.state.global_search.selectNext();
            ed.markDirty(.full);
        },
        .global_search_select_previous => {
            ed.state.global_search.selectPrevious();
            ed.markDirty(.full);
        },
        .global_search_accept => {
            clearPendingNormalSequence(ed);
            try acceptGlobalSearchResult(ed);
        },
        else => unreachable,
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
    ed.state.explorer_focused = false;

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
            .path => {
                _ = try navigation.jumpTo(ed, 0, 0, .{ .record_history = false });
            },
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

fn todoRoot(ed: *editor.Editor) []const u8 {
    if (ed.state.project_root) |root| return root;
    if (ed.state.tree) |tree| return tree.root_path;
    return ".";
}

fn commentsRoot(ed: *editor.Editor) []const u8 {
    if (ed.state.project_root) |root| return root;
    if (ed.state.tree) |tree| return tree.root_path;
    return ".";
}

fn saveManualTodosOrReport(ed: *editor.Editor) !bool {
    todos.saveManualTodos(ed.allocator, ed.io, todoRoot(ed), ed.state.todo_panel.manual_items.items) catch |err| switch (err) {
        error.NoWorkspace => {
            ed.state.status_message = "Manual TODOs unavailable: could not create .flamingo workspace";
            return false;
        },
        error.InvalidWorkspace => {
            ed.state.status_message = "Cannot use workspace TODOs: .flamingo exists and is not a directory";
            return false;
        },
        else => return err,
    };
    return true;
}

fn refreshTodoPanel(ed: *editor.Editor) !void {
    const root = todoRoot(ed);
    const command_module = @import("../command.zig");
    try command_module.refreshTodoPanelCode(ed, root);
    ed.state.status_message = "TODOs refreshed";
}

fn saveCommentsOrReport(ed: *editor.Editor) !bool {
    if (ed.state.comments_panel.load_error) |message| {
        ed.state.prompt_popup.error_message = message;
        return false;
    }
    comments.saveComments(ed.allocator, ed.io, commentsRoot(ed), &ed.state.comments_panel.store) catch |err| switch (err) {
        error.NoWorkspace => {
            ed.state.prompt_popup.error_message = "Comments unavailable: could not create .flamingo workspace";
            return false;
        },
        error.InvalidWorkspace => {
            ed.state.prompt_popup.error_message = "Cannot use workspace comments: .flamingo exists and is not a directory";
            return false;
        },
        else => return err,
    };
    return true;
}

fn refreshCommentsPanel(ed: *editor.Editor) !void {
    const command_module = @import("../command.zig");
    try command_module.refreshCommentsPanel(ed);
    if (ed.state.comments_panel.load_error == null) {
        ed.state.status_message = "Comments refreshed";
    }
}

fn selectedManualTodoIndex(ed: *editor.Editor) ?usize {
    return switch (ed.state.todo_panel.selectedKind() orelse return null) {
        .manual => |index| index,
        .code => null,
    };
}

fn openTodoPrompt(ed: *editor.Editor, kind: prompt_popup.PromptKind) !void {
    switch (kind) {
        .todo_new => try ed.state.prompt_popup.open(ed.allocator, .todo_new, "New TODO", "", ""),
        .todo_edit => {
            const index = selectedManualTodoIndex(ed) orelse {
                ed.state.status_message = "Code TODOs must be edited in the source file";
                return;
            };
            const title = ed.state.todo_panel.manual_items.items[index].title;
            try ed.state.prompt_popup.open(ed.allocator, .todo_edit, "Edit TODO", "", title);
        },
        .todo_delete_confirm => {
            const index = selectedManualTodoIndex(ed) orelse {
                ed.state.status_message = "Code TODOs must be edited in the source file";
                return;
            };
            const title = ed.state.todo_panel.manual_items.items[index].title;
            try ed.state.prompt_popup.open(ed.allocator, .todo_delete_confirm, "Delete TODO", title, "");
        },
        else => unreachable,
    }
    ed.state.mode = .Prompt;
    ed.markDirty(.full);
}

fn openSelectedTodo(ed: *editor.Editor) !void {
    switch (ed.state.todo_panel.selectedKind() orelse return) {
        .manual => {
            try openTodoPrompt(ed, .todo_edit);
        },
        .code => |index| {
            const item = ed.state.todo_panel.code_items.items[index];
            var b = buffer.Buffer.loadFromFile(ed.allocator, ed.io, item.open_path) catch {
                ed.state.error_message = "Could not open TODO file";
                return;
            };
            var consumed = false;
            errdefer if (!consumed) b.deinit();
            try navigation.recordCurrentJump(ed);
            try ed.addTab(b);
            consumed = true;
            _ = try navigation.jumpTo(ed, item.line -| 1, item.column -| 1, .{ .record_history = false });
            ed.state.todo_panel.focused = false;
            ed.state.explorer_focused = false;
            ed.state.mode = .Normal;
        },
    }
}

fn executeTodoPanelActionCommand(ed: *editor.Editor, command: commands.CommandId) !void {
    clearPendingNormalSequence(ed);
    switch (command) {
        .todo_panel_close => {
            ed.state.todo_panel.visible = false;
            ed.state.todo_panel.focused = false;
            ed.state.mode = .Normal;
            ed.markDirty(.full);
        },
        .todo_panel_move_up => ed.state.todo_panel.moveUp(),
        .todo_panel_move_down => ed.state.todo_panel.moveDown(),
        .todo_panel_refresh => try refreshTodoPanel(ed),
        .todo_panel_new => {
            if (todos.manualTodosPath(ed.allocator, ed.io, todoRoot(ed))) |path| {
                ed.allocator.free(path);
                try openTodoPrompt(ed, .todo_new);
            } else |err| switch (err) {
                error.NoWorkspace => ed.state.status_message = "Manual TODOs unavailable: could not create .flamingo workspace",
                error.InvalidWorkspace => ed.state.status_message = "Cannot use workspace TODOs: .flamingo exists and is not a directory",
                else => return err,
            }
        },
        .todo_panel_edit => try openTodoPrompt(ed, .todo_edit),
        .todo_panel_delete => try openTodoPrompt(ed, .todo_delete_confirm),
        .todo_panel_toggle => {
            const index = selectedManualTodoIndex(ed) orelse {
                ed.state.status_message = "Code TODOs must be edited in the source file";
                return;
            };
            const old_status = ed.state.todo_panel.manual_items.items[index].status;
            todos.toggleManualTodo(&ed.state.todo_panel, ed.io, index);
            if (!(try saveManualTodosOrReport(ed))) {
                ed.state.todo_panel.manual_items.items[index].status = old_status;
            }
        },
        .todo_panel_open_selected => try openSelectedTodo(ed),
        else => unreachable,
    }
}

fn selectedCommentDeleteLabel(ed: *editor.Editor) []const u8 {
    const message_ref = ed.state.comments_panel.selectedMessageRefOrRoot() orelse return "selected comment";
    if (message_ref.thread_index >= ed.state.comments_panel.store.threads.items.len) return "selected comment";
    const thread = ed.state.comments_panel.store.threads.items[message_ref.thread_index];
    if (message_ref.message_index >= thread.comments.items.len) return "selected comment";
    return thread.comments.items[message_ref.message_index].body;
}

fn openCommentPrompt(ed: *editor.Editor, kind: prompt_popup.PromptKind) !void {
    if (ed.state.comments_panel.load_error) |message| {
        ed.state.error_message = message;
        return;
    }
    ed.state.comments_panel.pending_action.deinit(ed.allocator);
    switch (kind) {
        .comment_reply => {
            const thread_index = ed.state.comments_panel.selectedThreadIndex() orelse {
                ed.state.status_message = "No comment thread selected";
                return;
            };
            ed.state.comments_panel.pending_action = .{ .reply = .{ .thread_index = thread_index } };
            try ed.state.prompt_popup.open(ed.allocator, .comment_reply, "Reply", "", "");
        },
        .comment_edit => {
            const message_ref = ed.state.comments_panel.selectedMessageRefOrRoot() orelse {
                ed.state.status_message = "No comment selected";
                return;
            };
            const thread = ed.state.comments_panel.store.threads.items[message_ref.thread_index];
            const body = thread.comments.items[message_ref.message_index].body;
            ed.state.comments_panel.pending_action = .{ .edit = message_ref };
            try ed.state.prompt_popup.open(ed.allocator, .comment_edit, "Edit Comment", "", body);
        },
        .comment_delete_confirm => {
            const message_ref = ed.state.comments_panel.selectedMessageRefOrRoot() orelse {
                ed.state.status_message = "No comment selected";
                return;
            };
            ed.state.comments_panel.pending_action = .{ .delete = message_ref };
            try ed.state.prompt_popup.open(ed.allocator, .comment_delete_confirm, "Delete Comment", selectedCommentDeleteLabel(ed), "");
        },
        else => unreachable,
    }
    ed.state.mode = .Prompt;
    ed.markDirty(.full);
}

fn openSelectedComment(ed: *editor.Editor) !void {
    const thread_index = ed.state.comments_panel.selectedThreadIndex() orelse return;
    if (thread_index >= ed.state.comments_panel.store.threads.items.len) return;
    const thread = ed.state.comments_panel.store.threads.items[thread_index];
    const open_path = try comments.openPathForThread(ed.allocator, commentsRoot(ed), thread.file_path);
    defer ed.allocator.free(open_path);

    if (ed.currentTab()) |tab| {
        if (tab.buf.filename) |filename| {
            if (comments.pathMatchesThread(ed.state.workspace.root_path, filename, thread.file_path)) {
                _ = try navigation.jumpTo(ed, thread.anchor.start_line -| 1, thread.anchor.start_col -| 1, .{ .record_history = true });
                ed.state.comments_panel.focused = false;
                ed.state.mode = .Normal;
                return;
            }
        }
    }

    var b = buffer.Buffer.loadFromFile(ed.allocator, ed.io, open_path) catch {
        ed.state.error_message = "Could not open comment file";
        return;
    };
    var consumed = false;
    errdefer if (!consumed) b.deinit();
    try navigation.recordCurrentJump(ed);
    try ed.addTab(b);
    consumed = true;
    _ = try navigation.jumpTo(ed, thread.anchor.start_line -| 1, thread.anchor.start_col -| 1, .{ .record_history = false });
    ed.state.comments_panel.focused = false;
    ed.state.explorer_focused = false;
    ed.state.mode = .Normal;
}

fn executeCommentsPanelActionCommand(ed: *editor.Editor, command: commands.CommandId) !void {
    clearPendingNormalSequence(ed);
    switch (command) {
        .comments_panel_close => {
            ed.state.comments_panel.visible = false;
            ed.state.comments_panel.focused = false;
            ed.state.mode = .Normal;
            ed.markDirty(.full);
        },
        .comments_panel_move_up => ed.state.comments_panel.moveUp(),
        .comments_panel_move_down => ed.state.comments_panel.moveDown(),
        .comments_panel_refresh => try refreshCommentsPanel(ed),
        .comments_panel_reply => try openCommentPrompt(ed, .comment_reply),
        .comments_panel_edit => try openCommentPrompt(ed, .comment_edit),
        .comments_panel_delete => try openCommentPrompt(ed, .comment_delete_confirm),
        .comments_panel_new => {
            const command_module = @import("../command.zig");
            try command_module.beginNewCommentFromSelection(ed);
        },
        .comments_panel_open_selected => try openSelectedComment(ed),
        else => unreachable,
    }
}

fn gitGraphPageRows(ed: *const editor.Editor) usize {
    return @max(@as(usize, 1), (ed.height * 70) / 100 -| 6);
}

fn gitDiffPageRows(ed: *const editor.Editor) usize {
    return @max(@as(usize, 1), (ed.height * 70) / 100 -| 6);
}

fn closeGitGraph(ed: *editor.Editor) void {
    ed.state.git_graph_panel.close();
    ed.state.mode = .Normal;
    ed.markDirty(.full);
}

fn closeGitDiff(ed: *editor.Editor) void {
    ed.state.git_diff_panel.close();
    ed.state.mode = .Normal;
    ed.markDirty(.full);
}

fn executeGitGraphActionCommand(ed: *editor.Editor, command: commands.CommandId) !void {
    switch (command) {
        .git_graph_close => closeGitGraph(ed),
        .git_graph_move_up => {
            ed.state.git_graph_panel.moveUp();
            ed.markDirty(.full);
        },
        .git_graph_move_down => {
            ed.state.git_graph_panel.moveDown();
            ed.markDirty(.full);
        },
        .git_graph_page_up => {
            ed.state.git_graph_panel.pageUp(gitGraphPageRows(ed));
            ed.markDirty(.full);
        },
        .git_graph_page_down => {
            ed.state.git_graph_panel.pageDown(gitGraphPageRows(ed));
            ed.markDirty(.full);
        },
        .git_graph_first => {
            ed.state.git_graph_panel.firstCommit();
            ed.markDirty(.full);
        },
        .git_graph_last => {
            ed.state.git_graph_panel.lastCommit();
            ed.markDirty(.full);
        },
        .git_graph_refresh => {
            ed.state.git_graph_panel.refresh(ed.allocator, ed.io) catch |err| switch (err) {
                error.NotGitRepository => {
                    ed.state.git_graph_panel.error_message = "Not a Git repository";
                    ed.state.error_message = "Not a Git repository";
                    ed.markDirty(.full);
                    return;
                },
                else => return err,
            };
            if (ed.state.git_graph_panel.error_message == null) {
                ed.state.status_message = "Git Graph refreshed";
            }
            ed.markDirty(.full);
        },
        .git_graph_toggle_details => {
            _ = ed.state.git_graph_panel.toggleDetails();
            ed.markDirty(.full);
        },
        else => unreachable,
    }
}

const GitDiffOpenTarget = struct {
    path: []const u8,
    line: ?usize = null,
    deleted: bool = false,
};

fn selectedGitDiffOpenTarget(ed: *editor.Editor) ?GitDiffOpenTarget {
    const panel = &ed.state.git_diff_panel;
    const row = panel.selectedRow() orelse return null;
    const path = row.file_path orelse return null;
    var target_line = row.new_line;
    if (target_line == null and panel.selected_index > 0) {
        var index = panel.selected_index;
        while (index > 0) {
            index -= 1;
            const candidate = panel.rows.items[index];
            const candidate_path = candidate.file_path orelse continue;
            if (!std.mem.eql(u8, candidate_path, path)) break;
            if (candidate.new_line) |line| {
                target_line = line;
                break;
            }
        }
    }
    return .{
        .path = path,
        .line = target_line,
        .deleted = row.change_kind != null and row.change_kind.? == .deleted,
    };
}

fn openSelectedGitDiffFile(ed: *editor.Editor) !void {
    const target = selectedGitDiffOpenTarget(ed) orelse return;
    if (target.deleted) {
        ed.state.status_message = "Deleted file cannot be opened from the working tree";
        return;
    }
    const root = ed.state.git_diff_panel.repo_root orelse return;
    const open_path = if (std.fs.path.isAbsolute(target.path))
        try ed.allocator.dupe(u8, target.path)
    else
        try std.fs.path.join(ed.allocator, &.{ root, target.path });
    defer ed.allocator.free(open_path);

    var b = buffer.Buffer.loadFromFile(ed.allocator, ed.io, open_path) catch {
        ed.state.error_message = "Could not open Git diff file";
        return;
    };
    var consumed = false;
    errdefer if (!consumed) b.deinit();
    try navigation.recordCurrentJump(ed);
    try ed.addTab(b);
    consumed = true;
    const row = if (target.line) |line| line -| 1 else 0;
    _ = try navigation.jumpTo(ed, row, 0, .{ .record_history = false });
    ed.state.mode = .Normal;
    ed.state.git_diff_panel.close();
    ed.state.explorer_focused = false;
}

fn executeGitDiffActionCommand(ed: *editor.Editor, command: commands.CommandId) !void {
    switch (command) {
        .git_diff_close => closeGitDiff(ed),
        .git_diff_move_up => {
            ed.state.git_diff_panel.moveUp();
            ed.markDirty(.full);
        },
        .git_diff_move_down => {
            ed.state.git_diff_panel.moveDown();
            ed.markDirty(.full);
        },
        .git_diff_page_up => {
            ed.state.git_diff_panel.pageUp(gitDiffPageRows(ed));
            ed.markDirty(.full);
        },
        .git_diff_page_down => {
            ed.state.git_diff_panel.pageDown(gitDiffPageRows(ed));
            ed.markDirty(.full);
        },
        .git_diff_refresh_panel => {
            ed.state.git_diff_panel.refresh(ed.allocator, ed.io) catch |err| switch (err) {
                error.NotGitRepository => {
                    ed.state.git_diff_panel.error_message = "This workspace is not a Git repository.";
                    ed.state.error_message = "This workspace is not a Git repository.";
                    ed.markDirty(.full);
                    return;
                },
                else => return err,
            };
            if (ed.state.git_diff_panel.error_message == null) {
                ed.state.status_message = "Git Diff refreshed";
            }
            ed.markDirty(.full);
        },
        .git_diff_open_selected => try openSelectedGitDiffFile(ed),
        else => unreachable,
    }
}

fn pickerStartDir(ed: *editor.Editor) []const u8 {
    if (ed.state.project_root) |root| return root;
    if (ed.state.tree) |tree| return tree.root_path;
    return ".";
}

fn openSaveConfirmation(ed: *editor.Editor) void {
    const tab = ed.currentTab() orelse return;
    ed.state.save_confirmation.open(tab.buf.filename);
    ed.state.mode = .SaveConfirmation;
    ed.markDirty(.full);
}

fn openDashboardPicker(ed: *editor.Editor, mode: filesystem_picker.PickerMode) !void {
    try openDashboardPickerWithFolderPurpose(ed, mode, .open_folder);
}

fn openDashboardPickerWithFolderPurpose(
    ed: *editor.Editor,
    mode: filesystem_picker.PickerMode,
    folder_purpose: filesystem_picker.FolderPickerPurpose,
) !void {
    try ed.state.filesystem_picker.openWithFolderPurpose(ed.allocator, ed.io, mode, folder_purpose, pickerStartDir(ed));
    ed.state.mode = .FilesystemPicker;
    ed.markDirty(.full);
}

fn applyPickerResult(ed: *editor.Editor, result: filesystem_picker.PickerResult) !void {
    defer result.deinit(ed.allocator);
    switch (result) {
        .open_file => |path| {
            fs_ops.openFileInEditor(ed, path) catch |err| {
                ed.state.filesystem_picker.error_message = fs_ops.userMessage(err);
                ed.markDirty(.full);
                return;
            };
        },
        .open_folder => |path| {
            switch (ed.state.filesystem_picker.folder_purpose) {
                .open_folder => {
                    fs_ops.openFolderInEditor(ed, path) catch |err| {
                        ed.state.filesystem_picker.error_message = fs_ops.userMessage(err);
                        ed.markDirty(.full);
                        return;
                    };
                },
                .create_workspace => {
                    const create_result = fs_ops.createWorkspaceAndOpenFolder(ed, path) catch |err| {
                        ed.state.filesystem_picker.error_message = fs_ops.workspaceCreateErrorMessage(err);
                        ed.markDirty(.full);
                        return;
                    };
                    switch (create_result) {
                        .created => ed.state.status_message = fs_ops.workspaceCreateMessage(create_result),
                        .already_exists, .invalid_path_exists => {
                            ed.state.filesystem_picker.error_message = fs_ops.workspaceCreateMessage(create_result);
                            ed.markDirty(.full);
                            return;
                        },
                    }
                },
            }
        },
        .create_file => |path| {
            fs_ops.createFileAndOpen(ed, path, false) catch |err| {
                ed.state.filesystem_picker.error_message = fs_ops.userMessage(err);
                ed.markDirty(.full);
                return;
            };
        },
    }
    ed.state.filesystem_picker.close(ed.allocator);
    ed.markDirty(.full);
}

fn executeDashboardSelectedAction(ed: *editor.Editor) !void {
    switch (ed.state.dash.selectedAction()) {
        .NewFile => try openDashboardPicker(ed, .new_file_location),
        .OpenFile => try openDashboardPicker(ed, .open_file),
        .OpenFolder => try openDashboardPicker(ed, .open_folder),
        .CreateWorkspace => try openDashboardPickerWithFolderPurpose(ed, .open_folder, .create_workspace),
        .Settings => try fs_ops.openSettingsConfig(ed),
        .Quit => ed.should_quit = true,
        else => {},
    }
}

fn taskPanelOutputRows(ed: *const editor.Editor) usize {
    return @max(ed.height / 2, 1);
}

fn taskRoot(ed: *editor.Editor) ?[]const u8 {
    if (ed.state.project_root) |root| return root;
    if (ed.state.tree) |tree| return tree.root_path;
    if (ed.state.workspace.root_path) |root| return root;
    return null;
}

fn rerunSelectedTask(ed: *editor.Editor) !void {
    const selected = ed.state.task_manager.selectedTaskConst() orelse {
        ed.state.status_message = "No task selected";
        return;
    };
    if (selected.status == .running or selected.status == .queued) {
        ed.state.status_message = "Task is still running";
        return;
    }
    const root = taskRoot(ed) orelse {
        ed.state.error_message = "No workspace root available for task execution.";
        return;
    };
    var parsed = command_parser.parse(ed.allocator, selected.command_display) catch |err| {
        ed.state.error_message = switch (err) {
            error.EmptyCommand => "Usage: :run <command>",
            error.UnterminatedQuote => "Task command has an unterminated quote",
            error.TrailingEscape => "Task command ends with an incomplete escape",
            else => "Could not parse task command",
        };
        return;
    };
    var parsed_owned = true;
    errdefer if (parsed_owned) parsed.deinit(ed.allocator);
    const id = try ed.state.task_manager.addQueuedTask(parsed, root, task_mod.nowMs(ed.io));
    parsed_owned = false;
    const task = ed.state.task_manager.findTask(id) orelse return;
    ed.runtime.task_worker.startTask(id, task.argvConst(), task.cwd) catch |err| {
        const message = switch (err) {
            error.TaskAlreadyRunning => "Another task is already running.",
            else => "Unable to start task.",
        };
        try ed.state.task_manager.failToStart(id, message, task_mod.nowMs(ed.io));
        ed.state.error_message = message;
        return;
    };
}

fn executeTaskPanelActionCommand(ed: *editor.Editor, command: commands.CommandId) !void {
    const rows = taskPanelOutputRows(ed);
    switch (command) {
        .task_panel_close => {
            ed.state.task_manager.close();
            ed.state.mode = .Normal;
            ed.markDirty(.full);
        },
        .task_panel_scroll_up => {
            ed.state.task_manager.scrollUp(1);
            ed.markDirty(.partial);
        },
        .task_panel_scroll_down => {
            ed.state.task_manager.scrollDown(1, rows);
            ed.markDirty(.partial);
        },
        .task_panel_page_up => {
            ed.state.task_manager.scrollUp(rows);
            ed.markDirty(.partial);
        },
        .task_panel_page_down => {
            ed.state.task_manager.scrollDown(rows, rows);
            ed.markDirty(.partial);
        },
        .task_panel_previous_task => {
            ed.state.task_manager.selectPrevious();
            ed.markDirty(.partial);
        },
        .task_panel_next_task => {
            ed.state.task_manager.selectNext();
            ed.markDirty(.partial);
        },
        .task_panel_rerun => {
            try rerunSelectedTask(ed);
            ed.markDirty(.full);
        },
        .task_panel_cancel => {
            if (ed.runtime.task_worker.hasRunningTask()) {
                ed.runtime.task_worker.cancelRunning();
                ed.state.status_message = "Cancelling task";
            } else {
                ed.state.status_message = "No task is running";
            }
            ed.markDirty(.partial);
        },
        else => unreachable,
    }
}

fn agentEventRows(ed: *const editor.Editor) usize {
    return @max(ed.height / 2, 1);
}

fn agentRoot(ed: *editor.Editor) []const u8 {
    if (ed.state.project_root) |root| return root;
    if (ed.state.tree) |tree| return tree.root_path;
    if (ed.state.workspace.root_path) |root| return root;
    return ".";
}

fn proposalDiffRows(ed: *const editor.Editor) usize {
    const selected = ed.state.proposal_manager.selectedProposalConst() orelse return 0;
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, selected.unified_diff, '\n');
    while (it.next()) |_| count += 1;
    return count;
}

fn proposalVisibleRows(ed: *const editor.Editor) usize {
    return @max(ed.height / 2, 1);
}

fn startAgentSession(ed: *editor.Editor) !void {
    const prompt = std.mem.trim(u8, ed.state.agent_manager.prompt_input.items, " \t\r\n");
    if (prompt.len == 0) {
        ed.state.status_message = "Agent prompt is empty";
        return;
    }
    const id = ed.state.agent_manager.createSession(agent_mod.nowMs(ed.io)) catch |err| switch (err) {
        error.AgentSessionAlreadyRunning => {
            ed.state.status_message = "Agent session is already running";
            return;
        },
        error.EmptyPrompt => {
            ed.state.status_message = "Agent prompt is empty";
            return;
        },
        else => return err,
    };
    const session = ed.state.agent_manager.findSession(id) orelse return;
    const session_mode = session.mode;
    const session_prompt = session.prompt;
    if (!builtin.is_test) logz.debug().fmt("msg", "startAgentSession: Starting agent session {d} (mode: {s}) with prompt: '{s}'", .{ id, @tagName(session_mode), prompt }).log();

    var active_snapshot: ?[]u8 = null;
    defer if (active_snapshot) |snapshot| ed.allocator.free(snapshot);
    const active_buffer = if (ed.state.currentTab()) |tab| active: {
        const filename = tab.buf.filename orelse break :active null;
        active_snapshot = tab.buf.toOwnedTextSnapshot(ed.allocator) catch null;
        break :active if (active_snapshot) |snapshot|
            agent_context_builder.ActiveBufferContext{ .path = filename, .content = snapshot }
        else
            null;
    } else null;
    var builder = agent_context_builder.AgentContextBuilder.init(
        ed.allocator,
        ed.io,
        agentRoot(ed),
        agent_policy.AgentPolicyConfig.fromAgentConfig(ed.config.agent),
        .{
            .max_context_files = ed.config.agent.limits.max_context_files,
            .max_context_file_bytes = ed.config.agent.limits.max_context_file_bytes,
            .max_context_total_bytes = ed.config.agent.limits.max_context_total_bytes,
        },
        ed.config.agent.validation.commands,
        active_buffer,
    );
    const package = builder.build(session, session_prompt, session_mode) catch |err| {
        const message = switch (err) {
            error.OutOfMemory => "Unable to build agent context: out of memory.",
            else => "Unable to build agent context.",
        };
        if (!builtin.is_test) logz.debug().fmt("msg", "startAgentSession: Context package build failed (session {d}): {s}", .{ id, message }).log();
        try ed.state.agent_manager.failToStart(id, message, agent_mod.nowMs(ed.io));
        ed.state.error_message = message;
        return;
    };
    if (!builtin.is_test) logz.debug().fmt("msg", "startAgentSession: Context package built successfully (session {d})", .{id}).log();
    if (ed.config.debug) {
        if (package.formatDetails(ed.allocator)) |details| {
            defer ed.allocator.free(details);
            if (!builtin.is_test) logz.debug().fmt("context_details", "\n{s}", .{details}).log();
        } else |_| {}
    }

    ed.state.agent_manager.attachContextPackage(id, package);
    const started_session = ed.state.agent_manager.findSession(id) orelse return;
    const context = &started_session.context_package.?;
    var backend = ed.runtime.agentBackend();
    backend.startSession(.{
        .session_id = id,
        .mode = started_session.mode,
        .prompt = started_session.prompt,
        .workspace_root = agentRoot(ed),
        .context = context,
    }) catch |err| {
        const message = switch (err) {
            error.AgentSessionAlreadyRunning => "Agent session is already running.",
            error.AgentBackendUnavailable => backend.availabilityMessage() orelse "Agent backend unavailable.",
            else => "Unable to start agent.",
        };
        if (!builtin.is_test) logz.debug().fmt("msg", "startAgentSession: Agent backend start failed (session {d}): {s}", .{ id, message }).log();
        try ed.state.agent_manager.failToStart(id, message, agent_mod.nowMs(ed.io));
        ed.state.error_message = message;
        return;
    };
    if (!builtin.is_test) logz.debug().fmt("msg", "startAgentSession: Agent backend session started successfully (session {d})", .{id}).log();
}

fn closeAgentPanel(ed: *editor.Editor) void {
    if (!ed.state.agent_manager.close()) {
        ed.state.status_message = "Cancel the running agent session first";
        ed.markDirty(.partial);
        return;
    }
    ed.state.mode = .Normal;
    ed.markDirty(.full);
}

fn cancelAgentSession(ed: *editor.Editor) void {
    if (execution_pipeline.cancelActiveExecution(ed)) {
        ed.markDirty(.partial);
        return;
    }
    var backend = ed.runtime.agentBackend();
    if (!backend.hasRunningSession()) {
        ed.state.status_message = "No agent session is running";
        ed.markDirty(.partial);
        return;
    }
    if (ed.state.agent_manager.selectedSessionConst()) |session| {
        backend.cancelSession(session.id);
    } else {
        backend.cancelSession(0);
    }
    ed.state.status_message = "Cancelling agent session";
    ed.markDirty(.partial);
}

fn executeAgentActionCommand(ed: *editor.Editor, command: commands.CommandId) !void {
    const rows = agentEventRows(ed);
    switch (command) {
        .agent_close => closeAgentPanel(ed),
        .agent_submit => {
            try startAgentSession(ed);
            ed.markDirty(.full);
        },
        .agent_backspace => {
            ed.state.agent_manager.backspacePrompt();
            ed.markDirty(.partial);
        },
        .agent_insert_newline => {
            try ed.state.agent_manager.appendPromptNewline();
            ed.markDirty(.partial);
        },
        .agent_toggle_mode => {
            ed.state.agent_manager.toggleMode();
            ed.markDirty(.partial);
        },
        .agent_cancel => cancelAgentSession(ed),
        .agent_approval_approve => {
            if (!execution_pipeline.approvePendingApproval(ed)) ed.state.status_message = "No pending approval";
            ed.markDirty(.partial);
        },
        .agent_approval_deny => {
            if (!execution_pipeline.denyPendingApproval(ed)) ed.state.status_message = "No pending approval";
            ed.markDirty(.partial);
        },
        .agent_scroll_up => {
            if (shouldScrollAgentPrompt(ed)) {
                ed.state.agent_manager.scrollPromptUp(1);
            } else {
                ed.state.agent_manager.scrollUp(1);
            }
            ed.markDirty(.partial);
        },
        .agent_scroll_down => {
            if (shouldScrollAgentPrompt(ed)) {
                ed.state.agent_manager.scrollPromptDown(1);
            } else {
                ed.state.agent_manager.scrollDown(1, rows);
            }
            ed.markDirty(.partial);
        },
        .agent_page_up => {
            if (shouldScrollAgentPrompt(ed)) {
                ed.state.agent_manager.scrollPromptUp(rows);
            } else {
                ed.state.agent_manager.scrollUp(rows);
            }
            ed.markDirty(.partial);
        },
        .agent_page_down => {
            if (shouldScrollAgentPrompt(ed)) {
                ed.state.agent_manager.scrollPromptDown(rows);
            } else {
                ed.state.agent_manager.scrollDown(rows, rows);
            }
            ed.markDirty(.partial);
        },
        else => unreachable,
    }
}

fn shouldScrollAgentPrompt(ed: *const editor.Editor) bool {
    const session = ed.state.agent_manager.selectedSessionConst() orelse return ed.state.agent_manager.canEditPrompt();
    return ed.state.agent_manager.canEditPrompt() and session.events.items.len == 0;
}

fn closeProposalsPanel(ed: *editor.Editor) void {
    ed.state.proposal_manager.close();
    ed.state.mode = .Normal;
    ed.markDirty(.full);
}

fn appendProposalEvent(ed: *editor.Editor, proposal_id: u64, kind: agent_mod.AgentEventKind, comptime fmt: []const u8, args: anytype) void {
    const proposal = ed.state.proposal_manager.getProposalConst(proposal_id) orelse return;
    var buf: [256]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch return;
    ed.state.agent_manager.appendEvent(proposal.session_id, kind, text, agent_mod.nowMs(ed.io)) catch |err| {
        logz.err().fmt("msg", "failed to append proposal event: {any}", .{err}).log();
    };
}

fn rejectSelectedProposal(ed: *editor.Editor) void {
    const selected = ed.state.proposal_manager.selectedProposalConst() orelse {
        ed.state.status_message = "No proposal selected";
        return;
    };
    const id = selected.id;
    ed.state.proposal_manager.rejectProposal(id, agent_mod.nowMs(ed.io)) catch |err| {
        ed.state.error_message = proposalActionErrorMessage(err);
        return;
    };
    appendProposalEvent(ed, id, .proposal_rejected, "Proposal #{d} rejected.", .{id});
    ed.state.status_message = "Proposal rejected";
}

fn approveApplySelectedProposal(ed: *editor.Editor) void {
    const selected = ed.state.proposal_manager.selectedProposalConst() orelse {
        ed.state.status_message = "No proposal selected";
        return;
    };
    execution_pipeline.approveApplyAndStart(ed, selected.id);
}

fn openSelectedProposalFile(ed: *editor.Editor) !void {
    const selected = ed.state.proposal_manager.selectedProposalConst() orelse {
        ed.state.status_message = "No proposal selected";
        return;
    };
    const path = workspace_guard.resolveWorkspacePath(ed.allocator, ed.io, agentRoot(ed), selected.file_path) catch |err| {
        ed.state.error_message = proposalApplyErrorMessage(err);
        return;
    };
    defer ed.allocator.free(path);
    fs_ops.openFileInEditor(ed, path) catch |err| {
        ed.state.error_message = proposalApplyErrorMessage(err);
        return;
    };
    ed.markDirty(.full);
}

fn proposalActionErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.ProposalNotFound => "Proposal not found",
        error.ProposalNotPending => "Proposal is not pending",
        error.ProposalNotApplicable => "Proposal cannot be changed from its current state",
        else => "Proposal action failed",
    };
}

fn proposalApplyErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.OutsideWorkspace => "Proposal target is outside the workspace",
        error.GitInternalsForbidden => "Proposal cannot target .git internals",
        error.BinaryFile => "Proposal target appears to be binary",
        error.PathAlreadyExists => "Proposal target already exists",
        error.FileNotFound => "Proposal target file was not found",
        error.ExpectedFile => "Proposal target is not a file",
        error.HunkMismatch => "Proposal no longer matches the target file",
        error.InvalidLine => "Proposal target line is invalid",
        else => "Proposal apply failed",
    };
}

fn executeProposalsActionCommand(ed: *editor.Editor, command: commands.CommandId) !void {
    const rows = proposalVisibleRows(ed);
    switch (command) {
        .proposals_close => closeProposalsPanel(ed),
        .proposals_move_up => {
            ed.state.proposal_manager.scrollUp(1);
            ed.markDirty(.partial);
        },
        .proposals_move_down => {
            ed.state.proposal_manager.scrollDown(1, proposalDiffRows(ed), rows);
            ed.markDirty(.partial);
        },
        .proposals_page_up => {
            ed.state.proposal_manager.scrollUp(rows);
            ed.markDirty(.partial);
        },
        .proposals_page_down => {
            ed.state.proposal_manager.scrollDown(rows, proposalDiffRows(ed), rows);
            ed.markDirty(.partial);
        },
        .proposals_previous => {
            ed.state.proposal_manager.selectPrevious();
            ed.markDirty(.partial);
        },
        .proposals_next => {
            ed.state.proposal_manager.selectNext();
            ed.markDirty(.partial);
        },
        .proposals_approve_apply => {
            approveApplySelectedProposal(ed);
            ed.markDirty(.full);
        },
        .proposals_reject => {
            rejectSelectedProposal(ed);
            ed.markDirty(.partial);
        },
        .proposals_open_file => try openSelectedProposalFile(ed),
        else => unreachable,
    }
}

fn executeDashboardActionCommand(ed: *editor.Editor, command: commands.CommandId) !void {
    switch (command) {
        .mode_command => {
            clearCurrentMultiCursor(ed);
            clearPendingNormalSequence(ed);
            ed.state.mode = .Command;
            ed.state.command_buffer.clearRetainingCapacity();
            try ed.state.command_popup.open(ed.allocator);
        },
        .dashboard_new_file => try openDashboardPicker(ed, .new_file_location),
        .dashboard_open_file => try openDashboardPicker(ed, .open_file),
        .dashboard_open_folder => try openDashboardPicker(ed, .open_folder),
        .dashboard_create_workspace => try openDashboardPickerWithFolderPurpose(ed, .open_folder, .create_workspace),
        .dashboard_settings => try fs_ops.openSettingsConfig(ed),
        .app_quit_flamingo => ed.should_quit = true,
        .dashboard_move_up => ed.state.dash.moveUp(),
        .dashboard_move_down => ed.state.dash.moveDown(),
        .dashboard_select => try executeDashboardSelectedAction(ed),
        else => unreachable,
    }
}

fn executePickerActionCommand(ed: *editor.Editor, command: commands.CommandId) !void {
    switch (command) {
        .picker_cancel => {
            clearPendingNormalSequence(ed);
            ed.state.filesystem_picker.close(ed.allocator);
            ed.state.mode = .Dashboard;
            ed.markDirty(.full);
        },
        .picker_back => {
            try ed.state.filesystem_picker.backspace(ed.allocator, ed.io);
            ed.markDirty(.full);
        },
        .picker_move_up => {
            ed.state.filesystem_picker.moveUp();
            ed.markDirty(.full);
        },
        .picker_move_down => {
            ed.state.filesystem_picker.moveDown();
            ed.markDirty(.full);
        },
        .picker_accept => {
            if (try ed.state.filesystem_picker.accept(ed.allocator, ed.io)) |result| {
                try applyPickerResult(ed, result);
            }
            ed.markDirty(.full);
        },
        .picker_begin_name_input => {
            ed.state.filesystem_picker.beginNameInput();
            ed.markDirty(.full);
        },
        .picker_select_folder => {
            if (try ed.state.filesystem_picker.selectFolder(ed.allocator)) |result| {
                try applyPickerResult(ed, result);
            } else {
                ed.markDirty(.full);
            }
        },
        .picker_select_current_folder => {
            if (try ed.state.filesystem_picker.selectCurrentFolder(ed.allocator)) |result| {
                try applyPickerResult(ed, result);
            }
        },
        else => unreachable,
    }
}

fn executeOpenFilePromptActionCommand(ed: *editor.Editor, command: commands.CommandId) !void {
    switch (command) {
        .open_file_prompt_cancel => {
            clearPendingNormalSequence(ed);
            ed.state.mode = .Dashboard;
        },
        .open_file_prompt_backspace => {
            if (ed.state.command_buffer.items.len > 0) {
                ed.state.command_buffer.shrinkRetainingCapacity(ed.state.command_buffer.items.len - 1);
            }
        },
        .open_file_prompt_submit => {
            if (ed.state.command_buffer.items.len > 0) {
                if (buffer.Buffer.loadFromFile(ed.allocator, ed.io, ed.state.command_buffer.items)) |b| {
                    try navigation.recordCurrentJump(ed);
                    try ed.addTab(b);
                    clearPendingNormalSequence(ed);
                    ed.state.mode = .Normal;
                    ed.state.explorer_focused = false;
                } else |_| {
                    ed.state.error_message = "Could not open file";
                    clearPendingNormalSequence(ed);
                    ed.state.mode = .Dashboard;
                }
            } else {
                clearPendingNormalSequence(ed);
                ed.state.mode = .Dashboard;
            }
        },
        else => unreachable,
    }
}

fn executeInsertActionCommand(ed: *editor.Editor, command: commands.CommandId) !void {
    switch (command) {
        .editing_insert_newline => {
            if (ed.currentTab()) |tab| {
                if (tab.multi_cursor.active) {
                    ed.state.status_message = "Multi-cursor newline is not implemented yet";
                    return;
                }
                const mc = tab.mainCursor();
                try tab.buf.insertNewline(mc.row, mc.col);
                mc.row += 1;
                mc.col = 0;
                mc.preferred_col = null;
            }
        },
        .editing_delete_back => {
            if (ed.currentTab()) |tab| {
                if (tab.multi_cursor.active) {
                    if (try multi_cursor.backspaceAtCursors(&tab.multi_cursor, &tab.buf)) |pos| {
                        applyPrimaryCursorPosition(tab, pos);
                    }
                    return;
                }
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
        },
        .editing_indent => {
            if (ed.currentTab()) |tab| {
                if (tab.multi_cursor.active) {
                    if (tab.multi_cursor.hasSelections()) {
                        _ = try multi_cursor.replaceSelectionsWithText(ed.allocator, &tab.multi_cursor, &tab.buf, "    ");
                    } else {
                        _ = try multi_cursor.insertTextAtCursors(&tab.multi_cursor, &tab.buf, "    ");
                    }
                    if (tab.multi_cursor.cursors.items.len > 0) {
                        applyPrimaryCursorPosition(tab, tab.multi_cursor.cursors.items[tab.multi_cursor.cursors.items.len - 1]);
                    }
                    return;
                }
                const mc = tab.mainCursor();
                clampCursorToBuffer(tab, mc);
                tab.buf.beginUndoGroup();
                defer tab.buf.endUndoGroup();
                for (0..4) |_| {
                    try tab.buf.insertChar(mc.row, mc.col, ' ');
                    mc.col += 1;
                }
                mc.preferred_col = null;
            }
        },
        else => unreachable,
    }
}

fn executeTerminalActionCommand(ed: *editor.Editor, command: commands.CommandId) void {
    const body_height = ed.terminalPanelHeight() -| 1;
    switch (command) {
        .terminal_unfocus => {
            clearPendingNormalSequence(ed);
            enterNormalFromTerminal(ed);
            ed.markDirty(.full);
        },
        .terminal_scroll_page_up => {
            ed.terminal_panel.scrollUp(if (body_height > 0) body_height else 1, body_height);
            ed.markDirty(.partial);
        },
        .terminal_scroll_page_down => {
            ed.terminal_panel.scrollDown(if (body_height > 0) body_height else 1, body_height);
            ed.markDirty(.partial);
        },
        .terminal_scroll_bottom => {
            ed.terminal_panel.scrollToBottom();
            ed.markDirty(.partial);
        },
        else => unreachable,
    }
}

fn executeHelpActionCommand(ed: *editor.Editor, command: commands.CommandId) void {
    switch (command) {
        .help_close => {
            clearPendingNormalSequence(ed);
            ed.state.help_popup.close();
            ed.state.mode = if (ed.state.tabs.items.len == 0) .Dashboard else .Normal;
            ed.markDirty(.full);
        },
        .help_scroll_up => {
            ed.state.help_popup.scrollUp(1);
            ed.markDirty(.full);
        },
        .help_scroll_down => {
            ed.state.help_popup.scrollDown(&ed.keybinding_registry, 1, ed.helpPopupBodyRows());
            ed.markDirty(.full);
        },
        .help_page_up => {
            const rows = ed.helpPopupBodyRows();
            ed.state.help_popup.scrollUp(rows);
            ed.markDirty(.full);
        },
        .help_page_down => {
            const rows = ed.helpPopupBodyRows();
            ed.state.help_popup.scrollDown(&ed.keybinding_registry, rows, rows);
            ed.markDirty(.full);
        },
        else => unreachable,
    }
}

fn executePromptActionCommand(ed: *editor.Editor, command: commands.CommandId) !void {
    switch (command) {
        .prompt_cancel => {
            clearPendingNormalSequence(ed);
            switch (ed.state.prompt_popup.kind) {
                .comment_new, .comment_reply, .comment_edit, .comment_delete_confirm => {
                    ed.state.comments_panel.pending_action.deinit(ed.allocator);
                },
                else => {},
            }
            ed.state.prompt_popup.close(ed.allocator);
            ed.state.mode = .Normal;
            ed.markDirty(.full);
        },
        .prompt_confirm, .prompt_submit => {
            try applyPrompt(ed);
            ed.markDirty(.full);
        },
        .prompt_backspace => {
            ed.state.prompt_popup.backspace();
            ed.markDirty(.full);
        },
        else => unreachable,
    }
}

fn executeSaveConfirmationActionCommand(ed: *editor.Editor, command: commands.CommandId) void {
    switch (command) {
        .save_confirmation_save => {
            if (ed.currentTab()) |tab| {
                if (tab.buf.filename != null) {
                    ed.saveTab(tab) catch {
                        ed.state.error_message = "Failed to save file";
                        ed.state.save_confirmation.close();
                        ed.state.mode = .Normal;
                        ed.markDirty(.full);
                        return;
                    };
                } else {
                    ed.state.error_message = "No file name — use :w <filename> first";
                    ed.state.save_confirmation.close();
                    ed.state.mode = .Normal;
                    ed.markDirty(.full);
                    return;
                }
            }
            ed.state.save_confirmation.close();
            ed.closeTab();
            if (ed.state.quitting_all) {
                ed.processQuitAll();
            }
        },
        .save_confirmation_discard => {
            ed.state.save_confirmation.close();
            if (ed.currentTab()) |tab| tab.buf.is_dirty = false;
            ed.closeTab();
            if (ed.state.quitting_all) {
                ed.processQuitAll();
            }
        },
        .save_confirmation_cancel => {
            ed.state.save_confirmation.close();
            ed.state.quitting_all = false;
            ed.state.mode = .Normal;
            ed.markDirty(.full);
        },
        else => unreachable,
    }
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
        else => unreachable,
    };
    const title = switch (kind) {
        .explorer_new_file => "New File",
        .explorer_rename => "Rename",
        .explorer_delete_confirm => "Delete",
        else => unreachable,
    };
    const initial = switch (kind) {
        .explorer_rename => std.fs.path.basename(context_path),
        else => "",
    };
    try ed.state.prompt_popup.open(ed.allocator, kind, title, context_path, initial);
    ed.state.mode = .Prompt;
    ed.markDirty(.full);
}

fn openExplorerSelected(ed: *editor.Editor) !void {
    const tree = if (ed.state.tree) |*tree| tree else return;
    if (tree.nodes.items.len == 0) return;

    const node = tree.nodes.items[tree.selected_index];
    if (node.is_dir) {
        tree.toggleExpand() catch {};
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

fn openExplorerSearchSelected(ed: *editor.Editor) !void {
    const tree = if (ed.state.tree) |*tree| tree else return;
    if (tree.selectedSearchResult()) |result| {
        const path = try ed.allocator.dupe(u8, result.absolute_path);
        defer ed.allocator.free(path);
        const is_dir = result.is_dir;

        try tree.finishSearch();
        if (is_dir) {
            tree.toggleExpand() catch {};
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
        tree.finishSearch() catch {};
    }
}

fn executeExplorerFileActionCommand(ed: *editor.Editor, command: commands.CommandId) !void {
    clearPendingNormalSequence(ed);
    switch (command) {
        .explorer_new_file => try openExplorerPrompt(ed, .explorer_new_file),
        .explorer_rename => try openExplorerPrompt(ed, .explorer_rename),
        .explorer_delete => try openExplorerPrompt(ed, .explorer_delete_confirm),
        else => unreachable,
    }
}

fn executeExplorerActionCommand(ed: *editor.Editor, command: commands.CommandId) !void {
    const tree = if (ed.state.tree) |*tree| tree else return;
    switch (command) {
        .explorer_search_open => try tree.startSearch(),
        .explorer_move_up => tree.moveUp(),
        .explorer_move_down => tree.moveDown(),
        .explorer_open_selected => try openExplorerSelected(ed),
        else => unreachable,
    }
}

fn executeExplorerSearchActionCommand(ed: *editor.Editor, command: commands.CommandId) !void {
    const tree = if (ed.state.tree) |*tree| tree else return;
    switch (command) {
        .explorer_search_cancel => tree.cancelSearch(),
        .explorer_search_backspace => try tree.backspaceSearch(),
        .explorer_move_up => tree.moveUp(),
        .explorer_move_down => tree.moveDown(),
        .explorer_open_selected => try openExplorerSearchSelected(ed),
        else => unreachable,
    }
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
        .todo_new => {
            const title = std.mem.trim(u8, input_text, " \t\r\n");
            if (title.len == 0) {
                ed.state.prompt_popup.error_message = "TODO title is required";
                return;
            }
            const before_len = ed.state.todo_panel.manual_items.items.len;
            try todos.appendManualTodo(&ed.state.todo_panel, ed.allocator, ed.io, title);
            if (!(try saveManualTodosOrReport(ed))) {
                todos.deleteManualTodo(&ed.state.todo_panel, ed.allocator, before_len);
                return;
            }
            ed.state.prompt_popup.close(ed.allocator);
            ed.state.mode = .Normal;
            ed.state.todo_panel.focused = true;
        },
        .todo_edit => {
            const title = std.mem.trim(u8, input_text, " \t\r\n");
            if (title.len == 0) {
                ed.state.prompt_popup.error_message = "TODO title is required";
                return;
            }
            const index = selectedManualTodoIndex(ed) orelse {
                ed.state.prompt_popup.error_message = "No manual TODO selected";
                return;
            };
            const item = &ed.state.todo_panel.manual_items.items[index];
            const old_title = try ed.allocator.dupe(u8, item.title);
            defer ed.allocator.free(old_title);
            try todos.editManualTodo(&ed.state.todo_panel, ed.allocator, ed.io, index, title);
            if (!(try saveManualTodosOrReport(ed))) {
                _ = todos.editManualTodo(&ed.state.todo_panel, ed.allocator, ed.io, index, old_title) catch {};
                return;
            }
            ed.state.prompt_popup.close(ed.allocator);
            ed.state.mode = .Normal;
            ed.state.todo_panel.focused = true;
        },
        .todo_delete_confirm => {
            const index = selectedManualTodoIndex(ed) orelse {
                ed.state.prompt_popup.error_message = "No manual TODO selected";
                return;
            };
            todos.deleteManualTodo(&ed.state.todo_panel, ed.allocator, index);
            if (!(try saveManualTodosOrReport(ed))) {
                ed.state.prompt_popup.error_message = "Could not persist TODO delete";
                return;
            }
            ed.state.prompt_popup.close(ed.allocator);
            ed.state.mode = .Normal;
            ed.state.todo_panel.focused = true;
        },
        .comment_new => {
            const body = std.mem.trim(u8, input_text, " \t\r\n");
            if (body.len == 0) {
                ed.state.prompt_popup.error_message = "Comment body is required";
                return;
            }
            const pending = switch (ed.state.comments_panel.pending_action) {
                .new_thread => |*pending| pending,
                else => {
                    ed.state.prompt_popup.error_message = "No pending comment selection";
                    return;
                },
            };
            var author = (try comments.resolveAuthor(ed.allocator, ed.io, commentsRoot(ed), &ed.config)) orelse {
                ed.state.prompt_popup.error_message = comments.missing_author_message;
                return;
            };
            defer author.deinit(ed.allocator);
            const before_len = ed.state.comments_panel.store.threads.items.len;
            try comments.appendThread(&ed.state.comments_panel, ed.allocator, ed.io, pending.file_path, &pending.anchor, &author, body);
            if (!(try saveCommentsOrReport(ed))) {
                if (ed.state.comments_panel.store.threads.items.len > before_len) {
                    var thread = ed.state.comments_panel.store.threads.orderedRemove(before_len);
                    thread.deinit(ed.allocator);
                    ed.state.comments_panel.clampSelection();
                }
                return;
            }
            ed.state.comments_panel.pending_action.deinit(ed.allocator);
            ed.state.prompt_popup.close(ed.allocator);
            ed.state.mode = .Normal;
            ed.state.comments_panel.focused = true;
            {
                const command_module = @import("../command.zig");
                command_module.validateActiveFileComments(ed);
            }
        },
        .comment_reply => {
            const body = std.mem.trim(u8, input_text, " \t\r\n");
            if (body.len == 0) {
                ed.state.prompt_popup.error_message = "Reply body is required";
                return;
            }
            const thread_ref = switch (ed.state.comments_panel.pending_action) {
                .reply => |thread_ref| thread_ref,
                else => {
                    ed.state.prompt_popup.error_message = "No pending comment thread";
                    return;
                },
            };
            if (thread_ref.thread_index >= ed.state.comments_panel.store.threads.items.len) {
                ed.state.prompt_popup.error_message = "No comment thread selected";
                return;
            }
            var author = (try comments.resolveAuthor(ed.allocator, ed.io, commentsRoot(ed), &ed.config)) orelse {
                ed.state.prompt_popup.error_message = comments.missing_author_message;
                return;
            };
            defer author.deinit(ed.allocator);
            const before_len = ed.state.comments_panel.store.threads.items[thread_ref.thread_index].comments.items.len;
            try comments.appendReply(&ed.state.comments_panel, ed.allocator, ed.io, thread_ref.thread_index, &author, body);
            if (!(try saveCommentsOrReport(ed))) {
                comments.deleteMessage(&ed.state.comments_panel, ed.allocator, .{
                    .thread_index = thread_ref.thread_index,
                    .message_index = before_len,
                });
                return;
            }
            ed.state.comments_panel.pending_action.deinit(ed.allocator);
            ed.state.prompt_popup.close(ed.allocator);
            ed.state.mode = .Normal;
            ed.state.comments_panel.focused = true;
        },
        .comment_edit => {
            const body = std.mem.trim(u8, input_text, " \t\r\n");
            if (body.len == 0) {
                ed.state.prompt_popup.error_message = "Comment body is required";
                return;
            }
            const message_ref = switch (ed.state.comments_panel.pending_action) {
                .edit => |message_ref| message_ref,
                else => {
                    ed.state.prompt_popup.error_message = "No pending comment edit";
                    return;
                },
            };
            if (message_ref.thread_index >= ed.state.comments_panel.store.threads.items.len or
                message_ref.message_index >= ed.state.comments_panel.store.threads.items[message_ref.thread_index].comments.items.len)
            {
                ed.state.prompt_popup.error_message = "No comment selected";
                return;
            }
            const old_body = try ed.allocator.dupe(u8, ed.state.comments_panel.store.threads.items[message_ref.thread_index].comments.items[message_ref.message_index].body);
            defer ed.allocator.free(old_body);
            try comments.editMessage(&ed.state.comments_panel, ed.allocator, ed.io, message_ref, body);
            if (!(try saveCommentsOrReport(ed))) {
                _ = comments.editMessage(&ed.state.comments_panel, ed.allocator, ed.io, message_ref, old_body) catch {};
                return;
            }
            ed.state.comments_panel.pending_action.deinit(ed.allocator);
            ed.state.prompt_popup.close(ed.allocator);
            ed.state.mode = .Normal;
            ed.state.comments_panel.focused = true;
        },
        .comment_delete_confirm => {
            const message_ref = switch (ed.state.comments_panel.pending_action) {
                .delete => |message_ref| message_ref,
                else => {
                    ed.state.prompt_popup.error_message = "No pending comment delete";
                    return;
                },
            };
            comments.deleteMessage(&ed.state.comments_panel, ed.allocator, message_ref);
            if (!(try saveCommentsOrReport(ed))) {
                ed.state.prompt_popup.error_message = "Could not persist comment delete";
                return;
            }
            ed.state.comments_panel.pending_action.deinit(ed.allocator);
            ed.state.prompt_popup.close(ed.allocator);
            ed.state.mode = .Normal;
            ed.state.comments_panel.focused = true;
        },
    }
}

fn enterNormalFromTerminal(ed: *editor.Editor) void {
    ed.terminal_panel.blur();
    ed.state.mode = .Normal;
}

fn showAndFocusTerminal(ed: *editor.Editor) !void {
    clearCurrentMultiCursor(ed);
    try ed.terminal_panel.show();
    const panel_rows = ed.terminalPanelHeight() -| 1;
    try ed.terminal_panel.ensureStarted(ed.runtime.event_queue, ed.width, panel_rows);
    ed.terminal_panel.focus();
    ed.state.explorer_focused = false;
    ed.state.todo_panel.focused = false;
    ed.state.comments_panel.focused = false;
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
    const todo_available = ed.state.todo_panel.visible;
    const comments_available = ed.state.comments_panel.visible;
    const right_panel_available = todo_available or comments_available;
    const right_panel_focused = ed.state.todo_panel.focused or ed.state.comments_panel.focused;
    if (!explorer_available and !terminal_available and !right_panel_available) return false;

    if (explorer_available or terminal_available or right_panel_available) {
        if (explorer_available and !ed.state.explorer_focused and !ed.terminal_panel.focused and !right_panel_focused) {
            ed.state.explorer_focused = true;
            ed.terminal_panel.blur();
            if (ed.state.mode == .Terminal) ed.state.mode = .Normal;
        } else if (ed.state.explorer_focused and right_panel_available) {
            ed.state.explorer_focused = false;
            ed.state.todo_panel.focused = todo_available;
            ed.state.comments_panel.focused = comments_available;
            ed.terminal_panel.blur();
            if (ed.state.mode == .Terminal) ed.state.mode = .Normal;
        } else if ((ed.state.explorer_focused or right_panel_focused) and terminal_available) {
            ed.state.explorer_focused = false;
            ed.state.todo_panel.focused = false;
            ed.state.comments_panel.focused = false;
            try showAndFocusTerminal(ed);
        } else if (ed.terminal_panel.focused) {
            enterNormalFromTerminal(ed);
            ed.state.todo_panel.focused = false;
            ed.state.comments_panel.focused = false;
        } else if (right_panel_available) {
            ed.state.todo_panel.focused = todo_available and !right_panel_focused;
            ed.state.comments_panel.focused = comments_available and !right_panel_focused;
            ed.state.explorer_focused = false;
            ed.terminal_panel.blur();
            if (ed.state.mode == .Terminal) ed.state.mode = .Normal;
        } else if (explorer_available) {
            ed.state.explorer_focused = !ed.state.explorer_focused;
            ed.state.todo_panel.focused = false;
            ed.state.comments_panel.focused = false;
        }
        ed.markDirty(.full);
        return true;
    }
    return false;
}

fn handleTerminalInput(ed: *editor.Editor, event: terminal.KeyEvent) !void {
    if (terminalActionCommandForEvent(ed, event)) |command| {
        executeTerminalActionCommand(ed, command);
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

fn handleHelpInput(ed: *editor.Editor, event: terminal.KeyEvent) void {
    if (helpActionCommandForEvent(ed, event)) |command| {
        executeHelpActionCommand(ed, command);
    }
}

fn handleGitGraphInput(ed: *editor.Editor, event: terminal.KeyEvent) !void {
    switch (gitGraphActionCommandForEvent(ed, event)) {
        .command => |command| try executeGitGraphActionCommand(ed, command),
        .prefix, .none => {},
    }
}

fn handleGitDiffInput(ed: *editor.Editor, event: terminal.KeyEvent) !void {
    if (gitDiffActionCommandForEvent(ed, event)) |command| {
        try executeGitDiffActionCommand(ed, command);
    }
}

fn handleTaskPanelInput(ed: *editor.Editor, event: terminal.KeyEvent) !void {
    if (taskPanelActionCommandForEvent(ed, event)) |command| {
        try executeTaskPanelActionCommand(ed, command);
    }
}

fn handleAgentInput(ed: *editor.Editor, event: terminal.KeyEvent) !void {
    if (event.key == .Char and !event.ctrl and !event.alt and event.char == 'q' and
        (ed.state.agent_manager.prompt_input.items.len == 0 or !ed.state.agent_manager.canEditPrompt()))
    {
        closeAgentPanel(ed);
        return;
    }

    if (agentActionCommandForEvent(ed, event)) |command| {
        if ((command == .agent_approval_approve or command == .agent_approval_deny) and
            ed.state.agent_manager.selectedPendingApproval() == null)
        {
            if (event.key == .Char and !event.ctrl and !event.alt) {
                try ed.state.agent_manager.appendPromptChar(event.char);
                ed.markDirty(.partial);
            }
            return;
        }
        try executeAgentActionCommand(ed, command);
        return;
    }

    if (event.key == .Char and !event.ctrl and !event.alt) {
        try ed.state.agent_manager.appendPromptChar(event.char);
        ed.markDirty(.partial);
    }
}

fn handleProposalsInput(ed: *editor.Editor, event: terminal.KeyEvent) !void {
    if (proposalsActionCommandForEvent(ed, event)) |command| {
        try executeProposalsActionCommand(ed, command);
    }
}

pub fn handleInput(ed: *editor.Editor, event: terminal.KeyEvent) !void {
    if (ed.state.error_message != null) {
        ed.state.error_message = null;
    }
    if (ed.state.status_message != null) {
        ed.state.status_message = null;
    }

    if (ed.state.mode == .Help) {
        handleHelpInput(ed, event);
        return;
    }

    if (ed.state.mode == .GitGraph) {
        try handleGitGraphInput(ed, event);
        return;
    }

    if (ed.state.mode == .GitDiff) {
        try handleGitDiffInput(ed, event);
        return;
    }

    if (ed.state.mode == .TaskPanel) {
        try handleTaskPanelInput(ed, event);
        return;
    }

    if (ed.state.mode == .Agent) {
        try handleAgentInput(ed, event);
        return;
    }

    if (registryCommandMatches(ed, .global, event, .terminal_toggle)) {
        clearPendingNormalSequence(ed);
        if (ed.terminal_panel.visible) {
            hideTerminal(ed);
        } else {
            try showAndFocusTerminal(ed);
        }
        return;
    }

    if (registryCommandMatches(ed, .global, event, .explorer_toggle)) {
        clearPendingNormalSequence(ed);
        clearCurrentMultiCursor(ed);
        if (ed.state.tree == null) {
            ed.state.tree = explorer.Explorer.init(ed.allocator, ed.io, ".") catch null;
        }
        ed.state.explorer_visible = !ed.state.explorer_visible;
        if (ed.state.explorer_visible) {
            ed.state.explorer_focused = true;
            ed.state.todo_panel.focused = false;
            ed.state.comments_panel.focused = false;
            ed.terminal_panel.blur();
            if (ed.state.mode == .Terminal) ed.state.mode = .Normal;
        } else {
            ed.state.explorer_focused = false;
        }
        ed.markDirty(.full);
        return;
    }

    if (registryCommandMatches(ed, .global, event, .app_cycle_panel_focus)) {
        clearPendingNormalSequence(ed);
        clearCurrentMultiCursor(ed);
        if (try cyclePanelFocus(ed)) return;
    }

    if (ed.state.mode == .Terminal) {
        try handleTerminalInput(ed, event);
        return;
    }

    if (registryCommandMatches(ed, .global, event, .app_close_tab)) {
        clearPendingNormalSequence(ed);
        if (ed.state.mode != .Dashboard) {
            // If the buffer has unsaved changes, show the confirmation popup
            // instead of silently discarding them.
            if (ed.currentTab()) |tab| {
                if (tab.buf.is_dirty) {
                    clearCurrentMultiCursor(ed);
                    openSaveConfirmation(ed);
                    return;
                }
            }
            ed.closeTab();
            return;
        }
    }

    if (ed.state.todo_panel.visible and ed.state.todo_panel.focused and
        (ed.state.mode == .Normal or ed.state.mode == .Insert))
    {
        if (todoPanelActionCommandForEvent(ed, event)) |command| {
            try executeTodoPanelActionCommand(ed, command);
            return;
        }
    }

    if (ed.state.comments_panel.visible and ed.state.comments_panel.focused and
        (ed.state.mode == .Normal or ed.state.mode == .Insert))
    {
        if (commentsPanelActionCommandForEvent(ed, event)) |command| {
            try executeCommentsPanelActionCommand(ed, command);
            return;
        }
    }

    if (ed.state.explorer_focused and ed.state.explorer_visible and ed.state.tree != null and
        (ed.state.mode == .Normal or ed.state.mode == .Insert))
    {
        if (explorerFileActionCommandForEvent(ed, event)) |command| {
            try executeExplorerFileActionCommand(ed, command);
            return;
        }
    }

    if (ed.state.explorer_focused and ed.state.explorer_visible and ed.state.tree != null) {
        if (ed.state.mode == .Normal or ed.state.mode == .Insert) {
            if (ed.state.tree.?.search_active) {
                if (explorerSearchActionCommandForEvent(ed, event)) |command| {
                    try executeExplorerSearchActionCommand(ed, command);
                    return;
                } else if (event.key == .Char and !event.ctrl and !event.alt) {
                    try ed.state.tree.?.appendSearchChar(event.char);
                    return;
                }
            } else if (explorerActionCommandForEvent(ed, event)) |command| {
                try executeExplorerActionCommand(ed, command);
                return;
            }
        }
    }

    if (registryCommandMatches(ed, .global, event, .app_next_tab)) {
        clearPendingNormalSequence(ed);
        ed.nextTab();
        return;
    }

    if (registryCommandMatches(ed, .global, event, .app_previous_tab)) {
        clearPendingNormalSequence(ed);
        ed.prevTab();
        return;
    }

    // --- Global Actions (Normal & Insert) ---
    if (ed.state.mode == .Normal or ed.state.mode == .Insert) {
        if (normalSharedActionCommandForEvent(ed, event)) |command| {
            try executeSharedActionCommand(ed, command);
            return;
        }
    }

    switch (ed.state.mode) {
        .Dashboard => {
            if (dashboardActionCommandForEvent(ed, event)) |command| {
                try executeDashboardActionCommand(ed, command);
            }
        },
        .Normal => {
            if (resolveNormalJumpCommand(ed, event)) |jump_command| {
                clearPendingNormalSequence(ed);
                switch (jump_command) {
                    .navigation_jump_back => _ = try navigation.jumpBack(ed),
                    .navigation_jump_forward => _ = try navigation.jumpForward(ed),
                    else => unreachable,
                }
            } else if (try handleNormalSequence(ed, event)) {
                // Handled
            } else if (try handleMovement(ed, event)) {
                // Handled
            } else if (normalModeActionCommandForEvent(ed, event)) |command| {
                try executeNormalModeActionCommand(ed, command);
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
            } else if (insertActionCommandForEvent(ed, event)) |command| {
                try executeInsertActionCommand(ed, command);
            } else if (event.key == .Char and !event.ctrl and !event.alt) {
                if (ed.currentTab()) |tab| {
                    if (tab.multi_cursor.active) {
                        const text = [_]u8{event.char};
                        const pos = if (tab.multi_cursor.hasSelections())
                            try multi_cursor.replaceSelectionsWithText(ed.allocator, &tab.multi_cursor, &tab.buf, &text)
                        else
                            try multi_cursor.insertTextAtCursors(&tab.multi_cursor, &tab.buf, &text);
                        if (pos) |cursor_pos| {
                            applyPrimaryCursorPosition(tab, cursor_pos);
                        }
                        return;
                    }
                    const mc = tab.mainCursor();
                    clampCursorToBuffer(tab, mc);
                    try tab.buf.insertChar(mc.row, mc.col, event.char);
                    mc.col += 1;
                    mc.preferred_col = null;
                }
            }
        },
        .Command => {
            if (commandLineActionCommandForEvent(ed, event)) |command| {
                try executeCommandLineActionCommand(ed, command);
            } else if (event.key == .Char and !event.ctrl and !event.alt) {
                try ed.state.command_popup.appendChar(ed.allocator, event.char);
            }
        },
        .OpenFilePrompt => {
            if (openFilePromptActionCommandForEvent(ed, event)) |command| {
                try executeOpenFilePromptActionCommand(ed, command);
            } else if (event.key == .Char and !event.ctrl and !event.alt) {
                try ed.state.command_buffer.append(ed.allocator, event.char);
            }
        },
        .FilesystemPicker => {
            if (pickerActionCommandForEvent(ed, event)) |command| {
                try executePickerActionCommand(ed, command);
            } else if (ed.state.filesystem_picker.mode == .new_file_location and
                ed.state.filesystem_picker.phase == .browsing)
            {
                if (pickerNewFileActionCommandForEvent(ed, event)) |command| {
                    try executePickerActionCommand(ed, command);
                }
            } else if (ed.state.filesystem_picker.mode == .open_folder) {
                if (pickerOpenFolderActionCommandForEvent(ed, event)) |command| {
                    try executePickerActionCommand(ed, command);
                }
            } else if (event.key == .Char and !event.ctrl and !event.alt) {
                try ed.state.filesystem_picker.appendChar(ed.allocator, event.char);
                ed.markDirty(.full);
            }
        },
        .Prompt => {
            if (promptActionCommandForEvent(ed, event)) |command| {
                try executePromptActionCommand(ed, command);
            } else if (event.key == .Char and !event.ctrl and !event.alt and
                ed.state.prompt_popup.kind != .explorer_delete_confirm and
                ed.state.prompt_popup.kind != .todo_delete_confirm and
                ed.state.prompt_popup.kind != .comment_delete_confirm)
            {
                try ed.state.prompt_popup.appendChar(ed.allocator, event.char);
                ed.markDirty(.full);
            }
        },
        .Search => {
            if (searchActionCommandForEvent(ed, event)) |command| {
                try executeSearchActionCommand(ed, command);
            } else if (event.key == .Char and !event.ctrl and !event.alt) {
                try ed.state.search_buffer.append(ed.allocator, event.char);
                try refreshSearchFromBuffer(ed);
                ed.markDirty(.full);
            }
        },
        .GlobalSearch => {
            if (globalSearchActionCommandForEvent(ed, event)) |command| {
                try executeGlobalSearchActionCommand(ed, command);
            } else if (event.key == .Char and !event.ctrl and !event.alt) {
                try ed.state.global_search.input.append(ed.allocator, event.char);
                try refreshGlobalSearchOrReport(ed);
                ed.markDirty(.full);
            }
        },
        .Help => {
            handleHelpInput(ed, event);
        },
        .GitGraph => {
            try handleGitGraphInput(ed, event);
        },
        .GitDiff => {
            try handleGitDiffInput(ed, event);
        },
        .TaskPanel => {
            try handleTaskPanelInput(ed, event);
        },
        .Agent => {
            try handleAgentInput(ed, event);
        },
        .Proposals => {
            try handleProposalsInput(ed, event);
        },
        .SaveConfirmation => {
            if (saveConfirmationActionCommandForEvent(ed, event)) |command| {
                executeSaveConfirmationActionCommand(ed, command);
            }
        },
        .Terminal => {
            try handleTerminalInput(ed, event);
        },
    }
}

pub fn handleMovement(ed: *editor.Editor, event: terminal.KeyEvent) !bool {
    const tab = ed.currentTab() orelse return false;
    const movement_command = movementCommandForEvent(ed, event) orelse return false;
    const page_rows = @max(ed.editorVisibleRows(), 1);
    if (tab.buf.lines.items.len == 0) return false;

    if (ed.state.mode == .Insert and tab.multi_cursor.active) {
        return try handleActiveMultiCursorMovement(ed, tab, movement_command, page_rows);
    }

    // Multi-cursor support: apply movement to all cursors
    var handled = false;
    for (tab.cursors.items) |*cursor| {
        clampCursorToBuffer(tab, cursor);

        if (event.shift) {
            if (cursor.selection_start == null) {
                cursor.selection_start = .{ .row = cursor.row, .col = cursor.col };
            }
        } else if (!event.ctrl and !event.alt) {
            // Only clear selection on plain arrows (no modifiers, except shift which extends)
            cursor.selection_start = null;
        }

        if (movement_command == .navigation_line_end) {
            cursor.col = tab.buf.lines.items[cursor.row].len();
            cursor.preferred_col = null;
            handled = true;
        } else if (movement_command == .navigation_line_start) {
            cursor.col = 0;
            cursor.preferred_col = null;
            handled = true;
        } else if (movement_command == .navigation_word_left) {
            try tab.buf.jumpWordLeft(&cursor.row, &cursor.col);
            cursor.preferred_col = null;
            handled = true;
        } else if (movement_command == .navigation_word_right) {
            try tab.buf.jumpWordRight(&cursor.row, &cursor.col);
            cursor.preferred_col = null;
            handled = true;
        } else if (movement_command == .navigation_move_up) {
            const preferred_col = cursor.preferred_col orelse cursor.col;
            cursor.preferred_col = preferred_col;
            cursor.row = tab.buf.prevVisibleLine(cursor.row);
            const new_line_len = tab.buf.lines.items[cursor.row].len();
            cursor.col = @min(preferred_col, new_line_len);
            handled = true;
        } else if (movement_command == .navigation_move_down) {
            const preferred_col = cursor.preferred_col orelse cursor.col;
            cursor.preferred_col = preferred_col;
            cursor.row = tab.buf.nextVisibleLine(cursor.row);
            const new_line_len = tab.buf.lines.items[cursor.row].len();
            cursor.col = @min(preferred_col, new_line_len);
            handled = true;
        } else if (movement_command == .navigation_page_up) {
            const preferred_col = cursor.preferred_col orelse cursor.col;
            cursor.preferred_col = preferred_col;
            for (0..page_rows) |_| {
                const next = tab.buf.prevVisibleLine(cursor.row);
                if (next == cursor.row) break;
                cursor.row = next;
            }
            const new_line_len = tab.buf.lines.items[cursor.row].len();
            cursor.col = @min(preferred_col, new_line_len);
            handled = true;
        } else if (movement_command == .navigation_page_down) {
            const preferred_col = cursor.preferred_col orelse cursor.col;
            cursor.preferred_col = preferred_col;
            for (0..page_rows) |_| {
                const next = tab.buf.nextVisibleLine(cursor.row);
                if (next == cursor.row) break;
                cursor.row = next;
            }
            const new_line_len = tab.buf.lines.items[cursor.row].len();
            cursor.col = @min(preferred_col, new_line_len);
            handled = true;
        } else if (movement_command == .navigation_move_left) {
            if (cursor.col > 0) cursor.col -= 1;
            cursor.preferred_col = null;
            handled = true;
        } else if (movement_command == .navigation_move_right) {
            const line = tab.buf.lines.items[cursor.row];
            if (cursor.col < line.len()) cursor.col += 1;
            cursor.preferred_col = null;
            handled = true;
        }

        if (handled) clampCursorToBuffer(tab, cursor);
    }

    ed.noteKeypressMovementHandled(handled);
    if (handled) {
        if (!event.shift) tab.multi_cursor.clear(ed.allocator);
        ed.clampScroll();
    }
    return handled;
}

fn clampCursorToBuffer(tab: *editor.Tab, cursor: *editor.Cursor) void {
    if (tab.buf.lines.items.len == 0) {
        cursor.row = 0;
        cursor.col = 0;
        cursor.preferred_col = null;
        cursor.selection_start = null;
        return;
    }

    cursor.row = @min(cursor.row, tab.buf.lines.items.len - 1);
    cursor.row = tab.buf.clampToVisibleLine(cursor.row);
    cursor.col = @min(cursor.col, tab.buf.lines.items[cursor.row].len());
    if (cursor.selection_start) |selection_start| {
        const row = tab.buf.clampToVisibleLine(@min(selection_start.row, tab.buf.lines.items.len - 1));
        cursor.selection_start = .{
            .row = row,
            .col = @min(selection_start.col, tab.buf.lines.items[row].len()),
        };
    }
}
