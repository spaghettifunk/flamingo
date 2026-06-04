const std = @import("std");

pub const CommandId = enum {
    app_quit,
    app_quit_all,
    app_force_quit_tab,
    app_quit_flamingo,
    app_close_tab,
    app_next_tab,
    app_previous_tab,
    app_cycle_panel_focus,
    file_write,
    file_write_all,
    file_write_quit,
    command_search_open,
    command_execute,
    command_cancel,
    command_backspace,
    command_suggestion_accept,
    command_suggestion_next,
    command_suggestion_previous,
    help_open,
    font_info_open,
    help_close,
    help_scroll_up,
    help_scroll_down,
    help_page_up,
    help_page_down,
    todos_open,
    comment_create,
    comments_open,
    comments_refresh,
    git_diff_open,
    agent_open,
    agent_context_open,
    proposals_open,
    task_run,
    tasks_open,
    task_stop,
    git_diff_close,
    git_diff_move_up,
    git_diff_move_down,
    git_diff_page_up,
    git_diff_page_down,
    git_diff_refresh_panel,
    git_diff_open_selected,
    task_panel_close,
    task_panel_scroll_up,
    task_panel_scroll_down,
    task_panel_page_up,
    task_panel_page_down,
    task_panel_previous_task,
    task_panel_next_task,
    task_panel_rerun,
    task_panel_cancel,
    agent_close,
    agent_submit,
    agent_backspace,
    agent_insert_newline,
    agent_toggle_mode,
    agent_cancel,
    agent_approval_approve,
    agent_approval_deny,
    agent_scroll_up,
    agent_scroll_down,
    agent_page_up,
    agent_page_down,
    proposals_close,
    proposals_move_up,
    proposals_move_down,
    proposals_page_up,
    proposals_page_down,
    proposals_previous,
    proposals_next,
    proposals_approve_apply,
    proposals_reject,
    proposals_open_file,
    git_graph_open,
    git_graph_close,
    git_graph_move_up,
    git_graph_move_down,
    git_graph_page_up,
    git_graph_page_down,
    git_graph_first,
    git_graph_last,
    git_graph_refresh,
    git_graph_toggle_details,
    git_diff_refresh,
    comments_panel_close,
    comments_panel_move_up,
    comments_panel_move_down,
    comments_panel_refresh,
    comments_panel_reply,
    comments_panel_edit,
    comments_panel_delete,
    comments_panel_new,
    comments_panel_open_selected,
    todo_panel_close,
    todo_panel_move_up,
    todo_panel_move_down,
    todo_panel_refresh,
    todo_panel_new,
    todo_panel_edit,
    todo_panel_delete,
    todo_panel_toggle,
    todo_panel_open_selected,
    file_rename,
    file_delete,
    file_new,
    file_new_folder,
    mode_normal,
    mode_insert,
    mode_command,
    mode_search,
    navigation_goto_line,
    navigation_goto_file_start,
    navigation_goto_file_end,
    navigation_matching_bracket,
    navigation_goto_definition,
    navigation_jump_back,
    navigation_jump_forward,
    navigation_next_comment,
    navigation_previous_comment,
    navigation_move_up,
    navigation_move_down,
    navigation_move_left,
    navigation_move_right,
    navigation_page_up,
    navigation_page_down,
    navigation_line_start,
    navigation_line_end,
    navigation_word_left,
    navigation_word_right,
    navigation_scroll_left,
    navigation_scroll_right,
    navigation_scroll_left_half_page,
    navigation_scroll_right_half_page,
    navigation_scroll_cursor_start,
    navigation_scroll_cursor_end,
    fold_close,
    fold_open,
    fold_toggle,
    fold_close_all,
    fold_open_all,
    fold_toggle_all,
    editing_insert_newline,
    editing_delete_back,
    editing_delete_word_back,
    editing_indent,
    editing_undo,
    editing_redo,
    editing_select_all,
    editing_copy,
    editing_cut,
    editing_paste,
    editing_duplicate_line,
    editing_delete_line,
    editing_add_cursor_above,
    editing_add_cursor_below,
    editing_select_next_occurrence,
    search_next_match,
    search_previous_match,
    search_cancel,
    search_accept,
    search_backspace,
    global_search_select_next,
    global_search_select_previous,
    global_search_accept,
    global_search_cancel,
    global_search_backspace,
    explorer_toggle,
    explorer_move_up,
    explorer_move_down,
    explorer_open_selected,
    explorer_search_open,
    explorer_search_cancel,
    explorer_search_backspace,
    explorer_new_file,
    explorer_new_folder,
    explorer_rename,
    explorer_delete,
    dashboard_new_file,
    dashboard_open_file,
    dashboard_open_folder,
    dashboard_create_workspace,
    dashboard_settings,
    dashboard_move_up,
    dashboard_move_down,
    dashboard_select,
    completion_auto_trigger,
    completion_trigger,
    completion_next,
    completion_previous,
    completion_accept,
    completion_cancel,
    terminal_toggle,
    terminal_unfocus,
    terminal_scroll_page_up,
    terminal_scroll_page_down,
    terminal_scroll_bottom,
    picker_cancel,
    picker_back,
    picker_move_up,
    picker_move_down,
    picker_accept,
    picker_begin_name_input,
    picker_select_folder,
    picker_select_current_folder,
    prompt_submit,
    prompt_cancel,
    prompt_backspace,
    prompt_confirm,
    open_file_prompt_submit,
    open_file_prompt_cancel,
    open_file_prompt_backspace,
    save_confirmation_save,
    save_confirmation_discard,
    save_confirmation_cancel,
};

pub const CommandCategory = enum {
    mode,
    app,
    file,
    tab,
    navigation,
    search,
    global_search,
    git,
    help,
    todos,
    comments,
    lsp,
    folding,
    editing,
    explorer,
    dashboard,
    terminal,
    agent,
    proposals,
    tasks,
    completion,
    picker,
    prompt,
    debug,
};

pub const CommandContext = enum {
    command_line,
    normal,
    insert,
    dashboard,
    explorer,
    explorer_search,
    search,
    global_search,
    agent,
    proposals,
    git_diff,
    task_panel,
    git_graph,
    help,
    todo_panel,
    comments_panel,
    terminal,
    picker,
    picker_new_file,
    picker_open_folder,
    prompt,
    open_file_prompt,
    completion,
    save_confirmation,
    global,
};

pub const CommandMeta = struct {
    id: CommandId,
    canonical_name: []const u8,
    command_names: []const []const u8 = &.{},
    aliases: []const []const u8 = &.{},
    short_description: []const u8,
    long_description: ?[]const u8 = null,
    category: CommandCategory,
    contexts: []const CommandContext,
    show_in_help: bool = true,
    show_in_command_popup: bool = false,
};

const command_popup_visible_count = 25;
const command_line_visible_count = 26;

const command_metadata = [_]CommandMeta{
    .{
        .id = .app_quit,
        .canonical_name = "app.quit",
        .command_names = &.{"q"},
        .short_description = "Quit current tab or dashboard",
        .category = .app,
        .contexts = &.{.command_line},
        .show_in_command_popup = true,
    },
    .{
        .id = .app_quit_all,
        .canonical_name = "app.quit_all",
        .command_names = &.{"qall"},
        .aliases = &.{"qa"},
        .short_description = "Quit all open tabs",
        .category = .app,
        .contexts = &.{.command_line},
        .show_in_command_popup = true,
    },
    .{
        .id = .app_force_quit_tab,
        .canonical_name = "app.force_quit_tab",
        .command_names = &.{"q!"},
        .short_description = "Force quit current tab",
        .category = .app,
        .contexts = &.{.command_line},
        .show_in_command_popup = true,
    },
    .{
        .id = .file_write,
        .canonical_name = "file.write",
        .command_names = &.{"w"},
        .short_description = "Write current buffer",
        .long_description = "Writes the current buffer to its existing filename or to the provided path.",
        .category = .file,
        .contexts = &.{ .command_line, .normal, .insert },
        .show_in_command_popup = true,
    },
    .{
        .id = .file_write_all,
        .canonical_name = "file.write_all",
        .command_names = &.{"wall"},
        .aliases = &.{"wa"},
        .short_description = "Write all modified buffers",
        .category = .file,
        .contexts = &.{.command_line},
        .show_in_command_popup = true,
    },
    .{
        .id = .file_write_quit,
        .canonical_name = "file.write_quit",
        .command_names = &.{"wq"},
        .short_description = "Write current buffer and quit tab",
        .long_description = "Writes the current buffer, optionally to a provided path, then closes the tab.",
        .category = .file,
        .contexts = &.{.command_line},
        .show_in_command_popup = true,
    },
    .{
        .id = .command_search_open,
        .canonical_name = "search.open",
        .command_names = &.{"search"},
        .short_description = "Open project search",
        .category = .search,
        .contexts = &.{.command_line},
        .show_in_command_popup = true,
    },
    .{
        .id = .help_open,
        .canonical_name = "help.open",
        .command_names = &.{"help"},
        .short_description = "Open help",
        .category = .help,
        .contexts = &.{.command_line},
        .show_in_command_popup = true,
    },
    .{
        .id = .font_info_open,
        .canonical_name = "font_info.open",
        .command_names = &.{"font-info"},
        .short_description = "Show icon and font configuration",
        .long_description = "Shows the active icon mode and how to configure Nerd Font support.",
        .category = .help,
        .contexts = &.{.command_line},
        .show_in_command_popup = true,
    },
    .{
        .id = .todos_open,
        .canonical_name = "todos.open",
        .command_names = &.{"todos"},
        .short_description = "Open workspace TODO panel",
        .category = .todos,
        .contexts = &.{.command_line},
        .show_in_command_popup = true,
    },
    .{
        .id = .file_rename,
        .canonical_name = "file.rename",
        .command_names = &.{"renameFile"},
        .aliases = &.{"rf"},
        .short_description = "Rename a file",
        .category = .file,
        .contexts = &.{.command_line},
        .show_in_command_popup = true,
    },
    .{
        .id = .file_delete,
        .canonical_name = "file.delete",
        .command_names = &.{"deleteFile"},
        .aliases = &.{"df"},
        .short_description = "Delete a file",
        .category = .file,
        .contexts = &.{.command_line},
        .show_in_command_popup = true,
    },
    .{
        .id = .file_new,
        .canonical_name = "file.new",
        .command_names = &.{"newFile"},
        .aliases = &.{"nf"},
        .short_description = "Create and open a file",
        .category = .file,
        .contexts = &.{.command_line},
        .show_in_command_popup = true,
    },
    .{
        .id = .file_new_folder,
        .canonical_name = "file.new_folder",
        .command_names = &.{"newFolder"},
        .short_description = "Create a folder",
        .category = .file,
        .contexts = &.{.command_line},
        .show_in_command_popup = true,
    },
    .{
        .id = .comment_create,
        .canonical_name = "comments.create",
        .command_names = &.{"comment"},
        .short_description = "Comment on selected prose text",
        .category = .comments,
        .contexts = &.{.command_line},
        .show_in_command_popup = true,
    },
    .{
        .id = .comments_open,
        .canonical_name = "comments.open",
        .command_names = &.{"comments"},
        .short_description = "Open comments panel",
        .category = .comments,
        .contexts = &.{.command_line},
        .show_in_command_popup = true,
    },
    .{
        .id = .git_diff_open,
        .canonical_name = "git_diff.open",
        .command_names = &.{"gitdiff"},
        .short_description = "Open workspace Git diff",
        .category = .git,
        .contexts = &.{.command_line},
        .show_in_command_popup = true,
    },
    .{
        .id = .agent_open,
        .canonical_name = "agent.open",
        .command_names = &.{"agent"},
        .short_description = "Open mock Agent panel",
        .category = .agent,
        .contexts = &.{.command_line},
        .show_in_command_popup = true,
    },
    .{
        .id = .agent_context_open,
        .canonical_name = "agent.context",
        .command_names = &.{"agentcontext"},
        .short_description = "Open Agent context details",
        .category = .agent,
        .contexts = &.{.command_line},
        .show_in_command_popup = true,
    },
    .{
        .id = .task_run,
        .canonical_name = "tasks.run",
        .command_names = &.{"run"},
        .short_description = "Run a workspace command",
        .category = .tasks,
        .contexts = &.{.command_line},
        .show_in_command_popup = true,
    },
    .{
        .id = .tasks_open,
        .canonical_name = "tasks.open",
        .command_names = &.{"tasks"},
        .short_description = "Open task output panel",
        .category = .tasks,
        .contexts = &.{.command_line},
        .show_in_command_popup = true,
    },
    .{
        .id = .task_stop,
        .canonical_name = "tasks.stop",
        .command_names = &.{"taskstop"},
        .short_description = "Cancel the running task",
        .category = .tasks,
        .contexts = &.{.command_line},
        .show_in_command_popup = true,
    },
    .{
        .id = .git_graph_open,
        .canonical_name = "git_graph.open",
        .command_names = &.{"git-graph"},
        .aliases = &.{"ggraph"},
        .short_description = "Open read-only Git commit graph",
        .category = .git,
        .contexts = &.{.command_line},
        .show_in_command_popup = true,
    },
    .{
        .id = .git_diff_refresh,
        .canonical_name = "git_diff.refresh",
        .command_names = &.{"gitdiff-refresh"},
        .aliases = &.{ "diff-refresh", "git-refresh" },
        .short_description = "Refresh current file Git diff markers",
        .category = .git,
        .contexts = &.{.command_line},
        .show_in_command_popup = true,
    },
    .{
        .id = .proposals_open,
        .canonical_name = "proposals.open",
        .command_names = &.{"proposals"},
        .short_description = "Open Agent proposals",
        .category = .proposals,
        .contexts = &.{.command_line},
        .show_in_command_popup = true,
    },
    .{
        .id = .navigation_goto_line,
        .canonical_name = "navigation.goto_line",
        .command_names = &.{ "<number>", "goto", "line" },
        .short_description = "Jump to line",
        .long_description = "Command-line forms are :<number>, :goto <number>, and :line <number>.",
        .category = .navigation,
        .contexts = &.{.command_line},
        .show_in_command_popup = false,
    },
    .{
        .id = .comments_refresh,
        .canonical_name = "comments.refresh",
        .short_description = "Reload workspace comments",
        .category = .comments,
        .contexts = &.{.command_line},
    },
    .{
        .id = .navigation_goto_file_start,
        .canonical_name = "navigation.goto_file_start",
        .short_description = "Go to file start",
        .category = .navigation,
        .contexts = &.{.normal},
    },
    .{
        .id = .navigation_next_comment,
        .canonical_name = "comments.next_anchor",
        .short_description = "Jump to next comment anchor",
        .category = .comments,
        .contexts = &.{.normal},
    },
    .{
        .id = .navigation_previous_comment,
        .canonical_name = "comments.previous_anchor",
        .short_description = "Jump to previous comment anchor",
        .category = .comments,
        .contexts = &.{.normal},
    },
    .{
        .id = .navigation_goto_file_end,
        .canonical_name = "navigation.goto_file_end",
        .short_description = "Go to file end",
        .category = .navigation,
        .contexts = &.{.normal},
    },
    .{
        .id = .navigation_matching_bracket,
        .canonical_name = "navigation.matching_bracket",
        .short_description = "Jump to matching bracket",
        .category = .navigation,
        .contexts = &.{.normal},
    },
    .{
        .id = .navigation_goto_definition,
        .canonical_name = "lsp.goto_definition",
        .short_description = "Go to definition",
        .category = .lsp,
        .contexts = &.{.normal},
    },
    .{
        .id = .navigation_scroll_left,
        .canonical_name = "navigation.scroll_left",
        .short_description = "Scroll left",
        .category = .navigation,
        .contexts = &.{.normal},
    },
    .{
        .id = .navigation_scroll_right,
        .canonical_name = "navigation.scroll_right",
        .short_description = "Scroll right",
        .category = .navigation,
        .contexts = &.{.normal},
    },
    .{
        .id = .navigation_scroll_left_half_page,
        .canonical_name = "navigation.scroll_left_half_page",
        .short_description = "Scroll left by half page",
        .category = .navigation,
        .contexts = &.{.normal},
    },
    .{
        .id = .navigation_scroll_right_half_page,
        .canonical_name = "navigation.scroll_right_half_page",
        .short_description = "Scroll right by half page",
        .category = .navigation,
        .contexts = &.{.normal},
    },
    .{
        .id = .navigation_scroll_cursor_start,
        .canonical_name = "navigation.scroll_cursor_start",
        .short_description = "Align cursor to view start",
        .category = .navigation,
        .contexts = &.{.normal},
    },
    .{
        .id = .navigation_scroll_cursor_end,
        .canonical_name = "navigation.scroll_cursor_end",
        .short_description = "Align cursor to view end",
        .category = .navigation,
        .contexts = &.{.normal},
    },
    .{
        .id = .fold_close,
        .canonical_name = "fold.close",
        .short_description = "Fold current brace block",
        .category = .folding,
        .contexts = &.{.normal},
    },
    .{
        .id = .fold_open,
        .canonical_name = "fold.open",
        .short_description = "Unfold current brace block",
        .category = .folding,
        .contexts = &.{.normal},
    },
    .{
        .id = .fold_toggle,
        .canonical_name = "fold.toggle",
        .short_description = "Toggle current brace block",
        .category = .folding,
        .contexts = &.{.normal},
    },
    .{
        .id = .fold_close_all,
        .canonical_name = "fold.close_all",
        .short_description = "Fold all brace blocks",
        .category = .folding,
        .contexts = &.{.normal},
    },
    .{
        .id = .fold_open_all,
        .canonical_name = "fold.open_all",
        .short_description = "Unfold all brace blocks",
        .category = .folding,
        .contexts = &.{.normal},
    },
    .{
        .id = .fold_toggle_all,
        .canonical_name = "fold.toggle_all",
        .short_description = "Toggle all brace blocks",
        .category = .folding,
        .contexts = &.{.normal},
    },
    .{
        .id = .app_quit_flamingo,
        .canonical_name = "app.quit_flamingo",
        .short_description = "Quit Flamingo",
        .category = .app,
        .contexts = &.{ .global, .dashboard },
    },
    .{
        .id = .app_close_tab,
        .canonical_name = "app.close_tab",
        .short_description = "Close current tab",
        .category = .tab,
        .contexts = &.{.global},
    },
    .{
        .id = .app_next_tab,
        .canonical_name = "app.next_tab",
        .short_description = "Switch to next tab",
        .category = .tab,
        .contexts = &.{.global},
    },
    .{
        .id = .app_previous_tab,
        .canonical_name = "app.previous_tab",
        .short_description = "Switch to previous tab",
        .category = .tab,
        .contexts = &.{.global},
    },
    .{
        .id = .app_cycle_panel_focus,
        .canonical_name = "app.cycle_panel_focus",
        .short_description = "Cycle focus between editor, explorer, and terminal",
        .category = .app,
        .contexts = &.{.global},
    },
    .{
        .id = .command_execute,
        .canonical_name = "command.execute",
        .short_description = "Execute command prompt input",
        .category = .prompt,
        .contexts = &.{.command_line},
    },
    .{
        .id = .command_cancel,
        .canonical_name = "command.cancel",
        .short_description = "Close command prompt",
        .category = .prompt,
        .contexts = &.{.command_line},
    },
    .{
        .id = .command_backspace,
        .canonical_name = "command.backspace",
        .short_description = "Delete previous command prompt character",
        .category = .prompt,
        .contexts = &.{.command_line},
    },
    .{
        .id = .command_suggestion_accept,
        .canonical_name = "command.suggestion_accept",
        .short_description = "Accept selected command suggestion",
        .category = .prompt,
        .contexts = &.{.command_line},
    },
    .{
        .id = .command_suggestion_next,
        .canonical_name = "command.suggestion_next",
        .short_description = "Select next command suggestion",
        .category = .prompt,
        .contexts = &.{.command_line},
    },
    .{
        .id = .command_suggestion_previous,
        .canonical_name = "command.suggestion_previous",
        .short_description = "Select previous command suggestion",
        .category = .prompt,
        .contexts = &.{.command_line},
    },
    .{
        .id = .help_close,
        .canonical_name = "help.close",
        .short_description = "Close help",
        .category = .help,
        .contexts = &.{.help},
    },
    .{
        .id = .help_scroll_up,
        .canonical_name = "help.scroll_up",
        .short_description = "Scroll help up",
        .category = .help,
        .contexts = &.{.help},
    },
    .{
        .id = .help_scroll_down,
        .canonical_name = "help.scroll_down",
        .short_description = "Scroll help down",
        .category = .help,
        .contexts = &.{.help},
    },
    .{
        .id = .help_page_up,
        .canonical_name = "help.page_up",
        .short_description = "Page help up",
        .category = .help,
        .contexts = &.{.help},
    },
    .{
        .id = .help_page_down,
        .canonical_name = "help.page_down",
        .short_description = "Page help down",
        .category = .help,
        .contexts = &.{.help},
    },
    .{
        .id = .todo_panel_close,
        .canonical_name = "todo_panel.close",
        .short_description = "Close TODO panel",
        .category = .todos,
        .contexts = &.{.todo_panel},
    },
    .{
        .id = .todo_panel_move_up,
        .canonical_name = "todo_panel.move_up",
        .short_description = "Move TODO selection up",
        .category = .todos,
        .contexts = &.{.todo_panel},
    },
    .{
        .id = .todo_panel_move_down,
        .canonical_name = "todo_panel.move_down",
        .short_description = "Move TODO selection down",
        .category = .todos,
        .contexts = &.{.todo_panel},
    },
    .{
        .id = .todo_panel_refresh,
        .canonical_name = "todo_panel.refresh",
        .short_description = "Refresh code TODOs",
        .category = .todos,
        .contexts = &.{.todo_panel},
    },
    .{
        .id = .todo_panel_new,
        .canonical_name = "todo_panel.new",
        .short_description = "Create manual TODO",
        .category = .todos,
        .contexts = &.{.todo_panel},
    },
    .{
        .id = .todo_panel_edit,
        .canonical_name = "todo_panel.edit",
        .short_description = "Edit selected manual TODO",
        .category = .todos,
        .contexts = &.{.todo_panel},
    },
    .{
        .id = .todo_panel_delete,
        .canonical_name = "todo_panel.delete",
        .short_description = "Delete selected manual TODO",
        .category = .todos,
        .contexts = &.{.todo_panel},
    },
    .{
        .id = .todo_panel_toggle,
        .canonical_name = "todo_panel.toggle",
        .short_description = "Toggle selected manual TODO",
        .category = .todos,
        .contexts = &.{.todo_panel},
    },
    .{
        .id = .todo_panel_open_selected,
        .canonical_name = "todo_panel.open_selected",
        .short_description = "Open selected code TODO",
        .category = .todos,
        .contexts = &.{.todo_panel},
    },
    .{
        .id = .comments_panel_close,
        .canonical_name = "comments_panel.close",
        .short_description = "Close comments panel",
        .category = .comments,
        .contexts = &.{.comments_panel},
    },
    .{
        .id = .comments_panel_move_up,
        .canonical_name = "comments_panel.move_up",
        .short_description = "Move comments selection up",
        .category = .comments,
        .contexts = &.{.comments_panel},
    },
    .{
        .id = .comments_panel_move_down,
        .canonical_name = "comments_panel.move_down",
        .short_description = "Move comments selection down",
        .category = .comments,
        .contexts = &.{.comments_panel},
    },
    .{
        .id = .comments_panel_refresh,
        .canonical_name = "comments_panel.refresh",
        .short_description = "Reload comments",
        .category = .comments,
        .contexts = &.{.comments_panel},
    },
    .{
        .id = .comments_panel_reply,
        .canonical_name = "comments_panel.reply",
        .short_description = "Reply to selected comment thread",
        .category = .comments,
        .contexts = &.{.comments_panel},
    },
    .{
        .id = .comments_panel_edit,
        .canonical_name = "comments_panel.edit",
        .short_description = "Edit selected comment",
        .category = .comments,
        .contexts = &.{.comments_panel},
    },
    .{
        .id = .comments_panel_delete,
        .canonical_name = "comments_panel.delete",
        .short_description = "Delete selected comment",
        .category = .comments,
        .contexts = &.{.comments_panel},
    },
    .{
        .id = .comments_panel_new,
        .canonical_name = "comments_panel.new",
        .short_description = "Create comment from editor selection",
        .category = .comments,
        .contexts = &.{.comments_panel},
    },
    .{
        .id = .comments_panel_open_selected,
        .canonical_name = "comments_panel.open_selected",
        .short_description = "Jump to selected comment anchor",
        .category = .comments,
        .contexts = &.{.comments_panel},
    },
    .{
        .id = .git_diff_close,
        .canonical_name = "git_diff.close",
        .short_description = "Close Git Diff",
        .category = .git,
        .contexts = &.{.git_diff},
    },
    .{
        .id = .git_diff_move_up,
        .canonical_name = "git_diff.move_up",
        .short_description = "Move Git Diff selection up",
        .category = .git,
        .contexts = &.{.git_diff},
    },
    .{
        .id = .git_diff_move_down,
        .canonical_name = "git_diff.move_down",
        .short_description = "Move Git Diff selection down",
        .category = .git,
        .contexts = &.{.git_diff},
    },
    .{
        .id = .git_diff_page_up,
        .canonical_name = "git_diff.page_up",
        .short_description = "Page Git Diff up",
        .category = .git,
        .contexts = &.{.git_diff},
    },
    .{
        .id = .git_diff_page_down,
        .canonical_name = "git_diff.page_down",
        .short_description = "Page Git Diff down",
        .category = .git,
        .contexts = &.{.git_diff},
    },
    .{
        .id = .git_diff_refresh_panel,
        .canonical_name = "git_diff.refresh_panel",
        .short_description = "Refresh Git Diff",
        .category = .git,
        .contexts = &.{.git_diff},
    },
    .{
        .id = .git_diff_open_selected,
        .canonical_name = "git_diff.open_selected",
        .short_description = "Open selected Git Diff file",
        .category = .git,
        .contexts = &.{.git_diff},
    },
    .{
        .id = .task_panel_close,
        .canonical_name = "task_panel.close",
        .short_description = "Close Tasks",
        .category = .tasks,
        .contexts = &.{.task_panel},
    },
    .{
        .id = .task_panel_scroll_up,
        .canonical_name = "task_panel.scroll_up",
        .short_description = "Scroll task output up",
        .category = .tasks,
        .contexts = &.{.task_panel},
    },
    .{
        .id = .task_panel_scroll_down,
        .canonical_name = "task_panel.scroll_down",
        .short_description = "Scroll task output down",
        .category = .tasks,
        .contexts = &.{.task_panel},
    },
    .{
        .id = .task_panel_page_up,
        .canonical_name = "task_panel.page_up",
        .short_description = "Page task output up",
        .category = .tasks,
        .contexts = &.{.task_panel},
    },
    .{
        .id = .task_panel_page_down,
        .canonical_name = "task_panel.page_down",
        .short_description = "Page task output down",
        .category = .tasks,
        .contexts = &.{.task_panel},
    },
    .{
        .id = .task_panel_previous_task,
        .canonical_name = "task_panel.previous_task",
        .short_description = "Select previous task",
        .category = .tasks,
        .contexts = &.{.task_panel},
    },
    .{
        .id = .task_panel_next_task,
        .canonical_name = "task_panel.next_task",
        .short_description = "Select next task",
        .category = .tasks,
        .contexts = &.{.task_panel},
    },
    .{
        .id = .task_panel_rerun,
        .canonical_name = "task_panel.rerun",
        .short_description = "Rerun selected task",
        .category = .tasks,
        .contexts = &.{.task_panel},
    },
    .{
        .id = .task_panel_cancel,
        .canonical_name = "task_panel.cancel",
        .short_description = "Cancel running task",
        .category = .tasks,
        .contexts = &.{.task_panel},
    },
    .{
        .id = .agent_close,
        .canonical_name = "agent.close",
        .short_description = "Close Agent",
        .category = .agent,
        .contexts = &.{.agent},
    },
    .{
        .id = .agent_submit,
        .canonical_name = "agent.submit",
        .short_description = "Start Agent session",
        .category = .agent,
        .contexts = &.{.agent},
    },
    .{
        .id = .agent_backspace,
        .canonical_name = "agent.backspace",
        .short_description = "Delete prompt character",
        .category = .agent,
        .contexts = &.{.agent},
    },
    .{
        .id = .agent_insert_newline,
        .canonical_name = "agent.insert_newline",
        .short_description = "Insert prompt newline",
        .category = .agent,
        .contexts = &.{.agent},
    },
    .{
        .id = .agent_toggle_mode,
        .canonical_name = "agent.toggle_mode",
        .short_description = "Toggle Agent mode",
        .category = .agent,
        .contexts = &.{.agent},
    },
    .{
        .id = .agent_cancel,
        .canonical_name = "agent.cancel",
        .short_description = "Cancel running Agent session",
        .category = .agent,
        .contexts = &.{.agent},
    },
    .{
        .id = .agent_approval_approve,
        .canonical_name = "agent.approval_approve",
        .short_description = "Approve pending Agent request",
        .category = .agent,
        .contexts = &.{.agent},
    },
    .{
        .id = .agent_approval_deny,
        .canonical_name = "agent.approval_deny",
        .short_description = "Deny pending Agent request",
        .category = .agent,
        .contexts = &.{.agent},
    },
    .{
        .id = .agent_scroll_up,
        .canonical_name = "agent.scroll_up",
        .short_description = "Scroll Agent events up",
        .category = .agent,
        .contexts = &.{.agent},
    },
    .{
        .id = .agent_scroll_down,
        .canonical_name = "agent.scroll_down",
        .short_description = "Scroll Agent events down",
        .category = .agent,
        .contexts = &.{.agent},
    },
    .{
        .id = .agent_page_up,
        .canonical_name = "agent.page_up",
        .short_description = "Page Agent events up",
        .category = .agent,
        .contexts = &.{.agent},
    },
    .{
        .id = .agent_page_down,
        .canonical_name = "agent.page_down",
        .short_description = "Page Agent events down",
        .category = .agent,
        .contexts = &.{.agent},
    },
    .{
        .id = .proposals_close,
        .canonical_name = "proposals.close",
        .short_description = "Close Proposals",
        .category = .proposals,
        .contexts = &.{.proposals},
    },
    .{
        .id = .proposals_move_up,
        .canonical_name = "proposals.move_up",
        .short_description = "Scroll proposal diff up",
        .category = .proposals,
        .contexts = &.{.proposals},
    },
    .{
        .id = .proposals_move_down,
        .canonical_name = "proposals.move_down",
        .short_description = "Scroll proposal diff down",
        .category = .proposals,
        .contexts = &.{.proposals},
    },
    .{
        .id = .proposals_page_up,
        .canonical_name = "proposals.page_up",
        .short_description = "Page proposal diff up",
        .category = .proposals,
        .contexts = &.{.proposals},
    },
    .{
        .id = .proposals_page_down,
        .canonical_name = "proposals.page_down",
        .short_description = "Page proposal diff down",
        .category = .proposals,
        .contexts = &.{.proposals},
    },
    .{
        .id = .proposals_previous,
        .canonical_name = "proposals.previous",
        .short_description = "Select previous proposal",
        .category = .proposals,
        .contexts = &.{.proposals},
    },
    .{
        .id = .proposals_next,
        .canonical_name = "proposals.next",
        .short_description = "Select next proposal",
        .category = .proposals,
        .contexts = &.{.proposals},
    },
    .{
        .id = .proposals_approve_apply,
        .canonical_name = "proposals.approve_apply",
        .short_description = "Approve and apply selected proposal",
        .category = .proposals,
        .contexts = &.{.proposals},
    },
    .{
        .id = .proposals_reject,
        .canonical_name = "proposals.reject",
        .short_description = "Reject selected proposal",
        .category = .proposals,
        .contexts = &.{.proposals},
    },
    .{
        .id = .proposals_open_file,
        .canonical_name = "proposals.open_file",
        .short_description = "Open selected proposal file",
        .category = .proposals,
        .contexts = &.{.proposals},
    },
    .{
        .id = .git_graph_close,
        .canonical_name = "git_graph.close",
        .short_description = "Close Git Graph",
        .category = .git,
        .contexts = &.{.git_graph},
    },
    .{
        .id = .git_graph_move_up,
        .canonical_name = "git_graph.move_up",
        .short_description = "Move Git Graph selection up",
        .category = .git,
        .contexts = &.{.git_graph},
    },
    .{
        .id = .git_graph_move_down,
        .canonical_name = "git_graph.move_down",
        .short_description = "Move Git Graph selection down",
        .category = .git,
        .contexts = &.{.git_graph},
    },
    .{
        .id = .git_graph_page_up,
        .canonical_name = "git_graph.page_up",
        .short_description = "Page Git Graph up",
        .category = .git,
        .contexts = &.{.git_graph},
    },
    .{
        .id = .git_graph_page_down,
        .canonical_name = "git_graph.page_down",
        .short_description = "Page Git Graph down",
        .category = .git,
        .contexts = &.{.git_graph},
    },
    .{
        .id = .git_graph_first,
        .canonical_name = "git_graph.first",
        .short_description = "Move to first Git commit",
        .category = .git,
        .contexts = &.{.git_graph},
    },
    .{
        .id = .git_graph_last,
        .canonical_name = "git_graph.last",
        .short_description = "Move to last loaded Git commit",
        .category = .git,
        .contexts = &.{.git_graph},
    },
    .{
        .id = .git_graph_refresh,
        .canonical_name = "git_graph.refresh",
        .short_description = "Refresh Git Graph",
        .category = .git,
        .contexts = &.{.git_graph},
    },
    .{
        .id = .git_graph_toggle_details,
        .canonical_name = "git_graph.toggle_details",
        .short_description = "Toggle selected commit details",
        .category = .git,
        .contexts = &.{.git_graph},
    },
    .{
        .id = .mode_normal,
        .canonical_name = "mode.normal",
        .short_description = "Return to normal mode",
        .category = .mode,
        .contexts = &.{ .normal, .insert, .terminal },
    },
    .{
        .id = .mode_insert,
        .canonical_name = "mode.insert",
        .short_description = "Enter insert mode",
        .category = .mode,
        .contexts = &.{.normal},
    },
    .{
        .id = .mode_command,
        .canonical_name = "mode.command",
        .short_description = "Open command prompt",
        .category = .mode,
        .contexts = &.{ .normal, .dashboard },
    },
    .{
        .id = .mode_search,
        .canonical_name = "mode.search",
        .short_description = "Search current buffer",
        .category = .search,
        .contexts = &.{.normal},
    },
    .{
        .id = .navigation_jump_back,
        .canonical_name = "navigation.jump_back",
        .short_description = "Jump back in history",
        .category = .navigation,
        .contexts = &.{.normal},
    },
    .{
        .id = .navigation_jump_forward,
        .canonical_name = "navigation.jump_forward",
        .short_description = "Jump forward in history",
        .category = .navigation,
        .contexts = &.{.normal},
    },
    .{
        .id = .navigation_move_up,
        .canonical_name = "navigation.move_up",
        .short_description = "Move cursor up",
        .category = .navigation,
        .contexts = &.{ .normal, .insert },
    },
    .{
        .id = .navigation_move_down,
        .canonical_name = "navigation.move_down",
        .short_description = "Move cursor down",
        .category = .navigation,
        .contexts = &.{ .normal, .insert },
    },
    .{
        .id = .navigation_move_left,
        .canonical_name = "navigation.move_left",
        .short_description = "Move cursor left",
        .category = .navigation,
        .contexts = &.{ .normal, .insert },
    },
    .{
        .id = .navigation_move_right,
        .canonical_name = "navigation.move_right",
        .short_description = "Move cursor right",
        .category = .navigation,
        .contexts = &.{ .normal, .insert },
    },
    .{
        .id = .navigation_page_up,
        .canonical_name = "navigation.page_up",
        .short_description = "Move cursor up by one page",
        .category = .navigation,
        .contexts = &.{ .normal, .insert },
    },
    .{
        .id = .navigation_page_down,
        .canonical_name = "navigation.page_down",
        .short_description = "Move cursor down by one page",
        .category = .navigation,
        .contexts = &.{ .normal, .insert },
    },
    .{
        .id = .navigation_line_start,
        .canonical_name = "navigation.line_start",
        .short_description = "Move cursor to line start",
        .category = .navigation,
        .contexts = &.{ .normal, .insert },
    },
    .{
        .id = .navigation_line_end,
        .canonical_name = "navigation.line_end",
        .short_description = "Move cursor to line end",
        .category = .navigation,
        .contexts = &.{ .normal, .insert },
    },
    .{
        .id = .navigation_word_left,
        .canonical_name = "navigation.word_left",
        .short_description = "Move cursor one word left",
        .category = .navigation,
        .contexts = &.{ .normal, .insert },
    },
    .{
        .id = .navigation_word_right,
        .canonical_name = "navigation.word_right",
        .short_description = "Move cursor one word right",
        .category = .navigation,
        .contexts = &.{ .normal, .insert },
    },
    .{
        .id = .editing_insert_newline,
        .canonical_name = "editing.insert_newline",
        .short_description = "Insert newline",
        .category = .editing,
        .contexts = &.{.insert},
    },
    .{
        .id = .editing_delete_back,
        .canonical_name = "editing.delete_back",
        .short_description = "Delete character backward",
        .category = .editing,
        .contexts = &.{.insert},
    },
    .{
        .id = .editing_delete_word_back,
        .canonical_name = "editing.delete_word_back",
        .short_description = "Delete word backward",
        .category = .editing,
        .contexts = &.{ .normal, .insert },
    },
    .{
        .id = .editing_indent,
        .canonical_name = "editing.indent",
        .short_description = "Insert indentation",
        .category = .editing,
        .contexts = &.{.insert},
    },
    .{
        .id = .editing_undo,
        .canonical_name = "editing.undo",
        .short_description = "Undo",
        .category = .editing,
        .contexts = &.{ .normal, .insert },
    },
    .{
        .id = .editing_redo,
        .canonical_name = "editing.redo",
        .short_description = "Redo",
        .category = .editing,
        .contexts = &.{ .normal, .insert },
    },
    .{
        .id = .editing_select_all,
        .canonical_name = "editing.select_all",
        .short_description = "Select all text",
        .category = .editing,
        .contexts = &.{ .normal, .insert },
    },
    .{
        .id = .editing_copy,
        .canonical_name = "editing.copy",
        .short_description = "Copy selection or current line",
        .category = .editing,
        .contexts = &.{ .normal, .insert },
    },
    .{
        .id = .editing_cut,
        .canonical_name = "editing.cut",
        .short_description = "Cut selection or current line",
        .category = .editing,
        .contexts = &.{ .normal, .insert },
    },
    .{
        .id = .editing_paste,
        .canonical_name = "editing.paste",
        .short_description = "Paste clipboard",
        .category = .editing,
        .contexts = &.{ .normal, .insert },
    },
    .{
        .id = .editing_duplicate_line,
        .canonical_name = "editing.duplicate_line",
        .short_description = "Duplicate current line",
        .category = .editing,
        .contexts = &.{ .normal, .insert },
    },
    .{
        .id = .editing_delete_line,
        .canonical_name = "editing.delete_line",
        .short_description = "Delete current line",
        .category = .editing,
        .contexts = &.{ .normal, .insert },
    },
    .{
        .id = .editing_add_cursor_above,
        .canonical_name = "editing.add_cursor_above",
        .short_description = "Add cursor above",
        .category = .editing,
        .contexts = &.{ .normal, .insert },
    },
    .{
        .id = .editing_add_cursor_below,
        .canonical_name = "editing.add_cursor_below",
        .short_description = "Add cursor below",
        .category = .editing,
        .contexts = &.{ .normal, .insert },
    },
    .{
        .id = .editing_select_next_occurrence,
        .canonical_name = "editing.select_next_occurrence",
        .short_description = "Add next occurrence of selected word",
        .category = .editing,
        .contexts = &.{.normal},
    },
    .{
        .id = .search_next_match,
        .canonical_name = "search.next_match",
        .short_description = "Select next buffer search match",
        .category = .search,
        .contexts = &.{.search},
    },
    .{
        .id = .search_previous_match,
        .canonical_name = "search.previous_match",
        .short_description = "Select previous buffer search match",
        .category = .search,
        .contexts = &.{.search},
    },
    .{
        .id = .search_cancel,
        .canonical_name = "search.cancel",
        .short_description = "Cancel buffer search",
        .category = .search,
        .contexts = &.{.search},
    },
    .{
        .id = .search_accept,
        .canonical_name = "search.accept",
        .short_description = "Accept buffer search",
        .category = .search,
        .contexts = &.{.search},
    },
    .{
        .id = .search_backspace,
        .canonical_name = "search.backspace",
        .short_description = "Delete previous buffer search character",
        .category = .search,
        .contexts = &.{.search},
    },
    .{
        .id = .global_search_select_next,
        .canonical_name = "global_search.select_next",
        .short_description = "Select next project search result",
        .category = .global_search,
        .contexts = &.{.global_search},
    },
    .{
        .id = .global_search_select_previous,
        .canonical_name = "global_search.select_previous",
        .short_description = "Select previous project search result",
        .category = .global_search,
        .contexts = &.{.global_search},
    },
    .{
        .id = .global_search_accept,
        .canonical_name = "global_search.accept",
        .short_description = "Open selected project search result",
        .category = .global_search,
        .contexts = &.{.global_search},
    },
    .{
        .id = .global_search_cancel,
        .canonical_name = "global_search.cancel",
        .short_description = "Close project search",
        .category = .global_search,
        .contexts = &.{.global_search},
    },
    .{
        .id = .global_search_backspace,
        .canonical_name = "global_search.backspace",
        .short_description = "Delete previous project search character",
        .category = .global_search,
        .contexts = &.{.global_search},
    },
    .{
        .id = .explorer_toggle,
        .canonical_name = "explorer.toggle",
        .short_description = "Toggle explorer",
        .category = .explorer,
        .contexts = &.{.global},
    },
    .{
        .id = .explorer_move_up,
        .canonical_name = "explorer.move_up",
        .short_description = "Move explorer selection up",
        .category = .explorer,
        .contexts = &.{ .explorer, .explorer_search },
    },
    .{
        .id = .explorer_move_down,
        .canonical_name = "explorer.move_down",
        .short_description = "Move explorer selection down",
        .category = .explorer,
        .contexts = &.{ .explorer, .explorer_search },
    },
    .{
        .id = .explorer_open_selected,
        .canonical_name = "explorer.open_selected",
        .short_description = "Open selected explorer item",
        .category = .explorer,
        .contexts = &.{ .explorer, .explorer_search },
    },
    .{
        .id = .explorer_search_open,
        .canonical_name = "explorer.search_open",
        .short_description = "Search explorer",
        .category = .explorer,
        .contexts = &.{.explorer},
    },
    .{
        .id = .explorer_search_cancel,
        .canonical_name = "explorer.search_cancel",
        .short_description = "Cancel explorer search",
        .category = .explorer,
        .contexts = &.{.explorer_search},
    },
    .{
        .id = .explorer_search_backspace,
        .canonical_name = "explorer.search_backspace",
        .short_description = "Delete previous explorer search character",
        .category = .explorer,
        .contexts = &.{.explorer_search},
    },
    .{
        .id = .explorer_new_file,
        .canonical_name = "explorer.new_file",
        .short_description = "Create file from explorer",
        .category = .explorer,
        .contexts = &.{.explorer},
    },
    .{
        .id = .explorer_new_folder,
        .canonical_name = "explorer.new_folder",
        .short_description = "Create folder from explorer",
        .category = .explorer,
        .contexts = &.{.explorer},
    },
    .{
        .id = .explorer_rename,
        .canonical_name = "explorer.rename",
        .short_description = "Rename selected explorer file",
        .category = .explorer,
        .contexts = &.{.explorer},
    },
    .{
        .id = .explorer_delete,
        .canonical_name = "explorer.delete",
        .short_description = "Delete selected explorer file",
        .category = .explorer,
        .contexts = &.{.explorer},
    },
    .{
        .id = .dashboard_new_file,
        .canonical_name = "dashboard.new_file",
        .short_description = "Start a new file from the dashboard",
        .category = .dashboard,
        .contexts = &.{.dashboard},
    },
    .{
        .id = .dashboard_open_file,
        .canonical_name = "dashboard.open_file",
        .short_description = "Open a file from the dashboard",
        .category = .dashboard,
        .contexts = &.{.dashboard},
    },
    .{
        .id = .dashboard_open_folder,
        .canonical_name = "dashboard.open_folder",
        .short_description = "Open a folder from the dashboard",
        .category = .dashboard,
        .contexts = &.{.dashboard},
    },
    .{
        .id = .dashboard_create_workspace,
        .canonical_name = "dashboard.create_workspace",
        .short_description = "Create a workspace from the dashboard",
        .category = .dashboard,
        .contexts = &.{.dashboard},
    },
    .{
        .id = .dashboard_settings,
        .canonical_name = "dashboard.settings",
        .short_description = "Open the active config file",
        .long_description = "Open the active Flamingo config.toml in a normal editor buffer.",
        .category = .dashboard,
        .contexts = &.{.dashboard},
    },
    .{
        .id = .dashboard_move_up,
        .canonical_name = "dashboard.move_up",
        .short_description = "Move dashboard selection up",
        .category = .dashboard,
        .contexts = &.{.dashboard},
    },
    .{
        .id = .dashboard_move_down,
        .canonical_name = "dashboard.move_down",
        .short_description = "Move dashboard selection down",
        .category = .dashboard,
        .contexts = &.{.dashboard},
    },
    .{
        .id = .dashboard_select,
        .canonical_name = "dashboard.select",
        .short_description = "Activate selected dashboard action",
        .category = .dashboard,
        .contexts = &.{.dashboard},
    },
    .{
        .id = .completion_auto_trigger,
        .canonical_name = "completion.auto_trigger",
        .short_description = "Auto-trigger completion",
        .category = .completion,
        .contexts = &.{ .normal, .insert },
    },
    .{
        .id = .completion_trigger,
        .canonical_name = "completion.trigger",
        .short_description = "Trigger completion",
        .category = .completion,
        .contexts = &.{ .normal, .insert },
    },
    .{
        .id = .completion_next,
        .canonical_name = "completion.next",
        .short_description = "Select next completion item",
        .category = .completion,
        .contexts = &.{.completion},
    },
    .{
        .id = .completion_previous,
        .canonical_name = "completion.previous",
        .short_description = "Select previous completion item",
        .category = .completion,
        .contexts = &.{.completion},
    },
    .{
        .id = .completion_accept,
        .canonical_name = "completion.accept",
        .short_description = "Accept selected completion",
        .category = .completion,
        .contexts = &.{.completion},
    },
    .{
        .id = .completion_cancel,
        .canonical_name = "completion.cancel",
        .short_description = "Cancel completion",
        .category = .completion,
        .contexts = &.{.completion},
    },
    .{
        .id = .terminal_toggle,
        .canonical_name = "terminal.toggle",
        .short_description = "Toggle integrated terminal",
        .category = .terminal,
        .contexts = &.{.global},
    },
    .{
        .id = .terminal_unfocus,
        .canonical_name = "terminal.unfocus",
        .short_description = "Return focus from terminal to editor",
        .category = .terminal,
        .contexts = &.{.terminal},
    },
    .{
        .id = .terminal_scroll_page_up,
        .canonical_name = "terminal.scroll_page_up",
        .short_description = "Scroll terminal output up by a page",
        .category = .terminal,
        .contexts = &.{.terminal},
    },
    .{
        .id = .terminal_scroll_page_down,
        .canonical_name = "terminal.scroll_page_down",
        .short_description = "Scroll terminal output down by a page",
        .category = .terminal,
        .contexts = &.{.terminal},
    },
    .{
        .id = .terminal_scroll_bottom,
        .canonical_name = "terminal.scroll_bottom",
        .short_description = "Scroll terminal output to bottom",
        .category = .terminal,
        .contexts = &.{.terminal},
    },
    .{
        .id = .picker_cancel,
        .canonical_name = "picker.cancel",
        .short_description = "Close filesystem picker",
        .category = .picker,
        .contexts = &.{.picker},
    },
    .{
        .id = .picker_back,
        .canonical_name = "picker.back",
        .short_description = "Move filesystem picker to parent or edit name",
        .category = .picker,
        .contexts = &.{.picker},
    },
    .{
        .id = .picker_move_up,
        .canonical_name = "picker.move_up",
        .short_description = "Move filesystem picker selection up",
        .category = .picker,
        .contexts = &.{.picker},
    },
    .{
        .id = .picker_move_down,
        .canonical_name = "picker.move_down",
        .short_description = "Move filesystem picker selection down",
        .category = .picker,
        .contexts = &.{.picker},
    },
    .{
        .id = .picker_accept,
        .canonical_name = "picker.accept",
        .short_description = "Accept filesystem picker selection",
        .category = .picker,
        .contexts = &.{.picker},
    },
    .{
        .id = .picker_begin_name_input,
        .canonical_name = "picker.begin_name_input",
        .short_description = "Begin entering a new file name",
        .category = .picker,
        .contexts = &.{.picker_new_file},
    },
    .{
        .id = .picker_select_folder,
        .canonical_name = "picker.select_folder",
        .short_description = "Select highlighted folder",
        .category = .picker,
        .contexts = &.{.picker_open_folder},
    },
    .{
        .id = .picker_select_current_folder,
        .canonical_name = "picker.select_current_folder",
        .short_description = "Select current folder",
        .category = .picker,
        .contexts = &.{.picker_open_folder},
    },
    .{
        .id = .prompt_submit,
        .canonical_name = "prompt.submit",
        .short_description = "Submit prompt",
        .category = .prompt,
        .contexts = &.{.prompt},
    },
    .{
        .id = .prompt_cancel,
        .canonical_name = "prompt.cancel",
        .short_description = "Cancel prompt",
        .category = .prompt,
        .contexts = &.{.prompt},
    },
    .{
        .id = .prompt_backspace,
        .canonical_name = "prompt.backspace",
        .short_description = "Delete previous prompt character",
        .category = .prompt,
        .contexts = &.{.prompt},
    },
    .{
        .id = .prompt_confirm,
        .canonical_name = "prompt.confirm",
        .short_description = "Confirm prompt action",
        .category = .prompt,
        .contexts = &.{.prompt},
    },
    .{
        .id = .open_file_prompt_submit,
        .canonical_name = "open_file_prompt.submit",
        .short_description = "Submit open-file prompt",
        .category = .prompt,
        .contexts = &.{.open_file_prompt},
    },
    .{
        .id = .open_file_prompt_cancel,
        .canonical_name = "open_file_prompt.cancel",
        .short_description = "Cancel open-file prompt",
        .category = .prompt,
        .contexts = &.{.open_file_prompt},
    },
    .{
        .id = .open_file_prompt_backspace,
        .canonical_name = "open_file_prompt.backspace",
        .short_description = "Delete previous open-file prompt character",
        .category = .prompt,
        .contexts = &.{.open_file_prompt},
    },
    .{
        .id = .save_confirmation_save,
        .canonical_name = "save_confirmation.save",
        .short_description = "Save changes and close tab",
        .category = .prompt,
        .contexts = &.{.save_confirmation},
    },
    .{
        .id = .save_confirmation_discard,
        .canonical_name = "save_confirmation.discard",
        .short_description = "Discard changes and close tab",
        .category = .prompt,
        .contexts = &.{.save_confirmation},
    },
    .{
        .id = .save_confirmation_cancel,
        .canonical_name = "save_confirmation.cancel",
        .short_description = "Cancel close and keep editing",
        .category = .prompt,
        .contexts = &.{.save_confirmation},
    },
};

comptime {
    if (command_popup_visible_count > command_line_visible_count) {
        @compileError("command popup visible count exceeds command line visible count");
    }
    if (command_line_visible_count > command_metadata.len) {
        @compileError("command line visible count exceeds metadata table length");
    }
}

pub fn all() []const CommandMeta {
    return &command_metadata;
}

pub fn commandLineVisible() []const CommandMeta {
    return command_metadata[0..command_line_visible_count];
}

pub fn commandPopupVisible() []const CommandMeta {
    return command_metadata[0..command_popup_visible_count];
}

pub fn metadata(id: CommandId) *const CommandMeta {
    return metadataById(id) orelse unreachable;
}

fn metadataById(id: CommandId) ?*const CommandMeta {
    for (&command_metadata) |*meta| {
        if (meta.id == id) return meta;
    }
    return null;
}

pub fn commandByCanonicalName(name: []const u8) ?CommandId {
    for (command_metadata) |meta| {
        if (std.mem.eql(u8, meta.canonical_name, name)) return meta.id;
    }
    return null;
}

pub fn commandByCommandLineName(name_or_alias: []const u8) ?CommandId {
    for (command_metadata) |meta| {
        for (meta.command_names) |name| {
            if (std.mem.eql(u8, name, name_or_alias)) return meta.id;
        }
        for (meta.aliases) |alias| {
            if (std.mem.eql(u8, alias, name_or_alias)) return meta.id;
        }
    }
    return null;
}

pub fn displayName(meta: *const CommandMeta) []const u8 {
    if (meta.command_names.len > 0) return meta.command_names[0];
    return meta.canonical_name;
}

pub fn isContextAllowed(id: CommandId, context: CommandContext) bool {
    const meta = metadata(id);
    for (meta.contexts) |allowed| {
        if (allowed == context) return true;
        if (allowed == .global) return true;
    }
    return false;
}

fn commandLineNameCount(name: []const u8) usize {
    var count: usize = 0;
    for (command_metadata) |meta| {
        for (meta.command_names) |candidate| {
            if (std.mem.eql(u8, candidate, name)) count += 1;
        }
        for (meta.aliases) |candidate| {
            if (std.mem.eql(u8, candidate, name)) count += 1;
        }
    }
    return count;
}

test "command metadata covers every command id once" {
    const fields = std.meta.fields(CommandId);
    try std.testing.expectEqual(fields.len, command_metadata.len);

    inline for (fields) |field| {
        const id: CommandId = @enumFromInt(field.value);
        try std.testing.expect(metadataById(id) != null);
    }

    for (command_metadata, 0..) |left, left_idx| {
        for (command_metadata[left_idx + 1 ..]) |right| {
            try std.testing.expect(left.id != right.id);
        }
    }
}

test "command metadata has unique canonical names and descriptions" {
    for (command_metadata, 0..) |left, left_idx| {
        try std.testing.expect(left.canonical_name.len > 0);
        try std.testing.expect(left.short_description.len > 0);
        if (left.show_in_help or left.show_in_command_popup) {
            try std.testing.expect(left.contexts.len > 0);
        }

        for (command_metadata[left_idx + 1 ..]) |right| {
            try std.testing.expect(!std.mem.eql(u8, left.canonical_name, right.canonical_name));
        }
    }
}

test "command line names and aliases are unique" {
    for (command_metadata) |meta| {
        for (meta.command_names) |name| {
            try std.testing.expect(name.len > 0);
            try std.testing.expectEqual(@as(usize, 1), commandLineNameCount(name));
        }
        for (meta.aliases) |alias| {
            try std.testing.expect(alias.len > 0);
            try std.testing.expectEqual(@as(usize, 1), commandLineNameCount(alias));
        }
    }
}

test "command lookup resolves canonical names" {
    try std.testing.expectEqual(CommandId.app_quit, commandByCanonicalName("app.quit").?);
    try std.testing.expectEqual(CommandId.file_write, commandByCanonicalName("file.write").?);
    try std.testing.expectEqual(CommandId.command_search_open, commandByCanonicalName("search.open").?);
    try std.testing.expectEqual(CommandId.help_open, commandByCanonicalName("help.open").?);
    try std.testing.expectEqual(CommandId.navigation_goto_line, commandByCanonicalName("navigation.goto_line").?);
    try std.testing.expectEqual(CommandId.navigation_goto_file_start, commandByCanonicalName("navigation.goto_file_start").?);
    try std.testing.expectEqual(CommandId.navigation_goto_definition, commandByCanonicalName("lsp.goto_definition").?);
    try std.testing.expectEqual(CommandId.fold_toggle_all, commandByCanonicalName("fold.toggle_all").?);
    try std.testing.expectEqual(CommandId.git_diff_open, commandByCanonicalName("git_diff.open").?);
    try std.testing.expectEqual(CommandId.git_diff_refresh, commandByCanonicalName("git_diff.refresh").?);
    try std.testing.expectEqual(CommandId.agent_open, commandByCanonicalName("agent.open").?);
    try std.testing.expectEqual(CommandId.task_run, commandByCanonicalName("tasks.run").?);
    try std.testing.expectEqual(CommandId.file_new_folder, commandByCanonicalName("file.new_folder").?);
    try std.testing.expect(commandByCanonicalName("nope") == null);
}

test "command lookup resolves command line names and aliases" {
    const cases = [_]struct {
        name: []const u8,
        id: CommandId,
    }{
        .{ .name = "q", .id = .app_quit },
        .{ .name = "qall", .id = .app_quit_all },
        .{ .name = "qa", .id = .app_quit_all },
        .{ .name = "q!", .id = .app_force_quit_tab },
        .{ .name = "w", .id = .file_write },
        .{ .name = "wall", .id = .file_write_all },
        .{ .name = "wa", .id = .file_write_all },
        .{ .name = "wq", .id = .file_write_quit },
        .{ .name = "search", .id = .command_search_open },
        .{ .name = "help", .id = .help_open },
        .{ .name = "todos", .id = .todos_open },
        .{ .name = "comment", .id = .comment_create },
        .{ .name = "comments", .id = .comments_open },
        .{ .name = "gitdiff", .id = .git_diff_open },
        .{ .name = "agent", .id = .agent_open },
        .{ .name = "agentcontext", .id = .agent_context_open },
        .{ .name = "proposals", .id = .proposals_open },
        .{ .name = "run", .id = .task_run },
        .{ .name = "tasks", .id = .tasks_open },
        .{ .name = "taskstop", .id = .task_stop },
        .{ .name = "git-graph", .id = .git_graph_open },
        .{ .name = "ggraph", .id = .git_graph_open },
        .{ .name = "gitdiff-refresh", .id = .git_diff_refresh },
        .{ .name = "diff-refresh", .id = .git_diff_refresh },
        .{ .name = "git-refresh", .id = .git_diff_refresh },
        .{ .name = "newFile", .id = .file_new },
        .{ .name = "nf", .id = .file_new },
        .{ .name = "newFolder", .id = .file_new_folder },
        .{ .name = "renameFile", .id = .file_rename },
        .{ .name = "rf", .id = .file_rename },
        .{ .name = "deleteFile", .id = .file_delete },
        .{ .name = "df", .id = .file_delete },
        .{ .name = "goto", .id = .navigation_goto_line },
        .{ .name = "line", .id = .navigation_goto_line },
        .{ .name = "<number>", .id = .navigation_goto_line },
    };

    for (cases) |case| {
        try std.testing.expectEqual(case.id, commandByCommandLineName(case.name).?);
    }
    try std.testing.expect(commandByCommandLineName("nope") == null);
}

test "command line visible commands preserve current popup order" {
    const visible = commandPopupVisible();
    try std.testing.expectEqual(@as(usize, command_popup_visible_count), visible.len);

    const expected = [_]CommandId{
        .app_quit,
        .app_quit_all,
        .app_force_quit_tab,
        .file_write,
        .file_write_all,
        .file_write_quit,
        .command_search_open,
        .help_open,
        .font_info_open,
        .todos_open,
        .file_rename,
        .file_delete,
        .file_new,
        .file_new_folder,
        .comment_create,
        .comments_open,
        .git_diff_open,
        .agent_open,
        .agent_context_open,
        .task_run,
        .tasks_open,
        .task_stop,
        .git_graph_open,
        .git_diff_refresh,
        .proposals_open,
    };

    for (expected, 0..) |id, idx| {
        try std.testing.expectEqual(id, visible[idx].id);
        try std.testing.expect(visible[idx].show_in_command_popup);
    }

    const command_line_visible = commandLineVisible();
    try std.testing.expectEqual(CommandId.navigation_goto_line, command_line_visible[command_line_visible.len - 1].id);
}

test "command popup visible commands have command-line spellings" {
    for (commandPopupVisible()) |meta| {
        try std.testing.expect(meta.show_in_command_popup);
        try std.testing.expect(meta.command_names.len > 0);

        for (meta.command_names) |name| {
            try std.testing.expectEqual(meta.id, commandByCommandLineName(name).?);
        }
        for (meta.aliases) |alias| {
            try std.testing.expectEqual(meta.id, commandByCommandLineName(alias).?);
        }
    }
}

test "goto line metadata documents command line forms" {
    const meta = metadata(.navigation_goto_line);
    try std.testing.expectEqual(CommandCategory.navigation, meta.category);
    try std.testing.expect(meta.long_description != null);
    try std.testing.expect(commandByCommandLineName("<number>") == .navigation_goto_line);
    try std.testing.expect(commandByCommandLineName("goto") == .navigation_goto_line);
    try std.testing.expect(commandByCommandLineName("line") == .navigation_goto_line);
}

test "normal sequence commands have metadata" {
    const expected = [_]CommandId{
        .navigation_goto_file_start,
        .navigation_goto_file_end,
        .navigation_matching_bracket,
        .navigation_goto_definition,
        .navigation_scroll_left,
        .navigation_scroll_right,
        .navigation_scroll_left_half_page,
        .navigation_scroll_right_half_page,
        .navigation_scroll_cursor_start,
        .navigation_scroll_cursor_end,
        .fold_close,
        .fold_open,
        .fold_toggle,
        .fold_close_all,
        .fold_open_all,
        .fold_toggle_all,
        .navigation_next_comment,
        .navigation_previous_comment,
    };

    for (expected) |id| {
        const meta = metadata(id);
        try std.testing.expect(meta.contexts.len > 0);
        try std.testing.expect(meta.contexts[0] == .normal);
        try std.testing.expect(meta.command_names.len == 0);
    }
}
