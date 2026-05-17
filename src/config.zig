const std = @import("std");
const toml = @import("toml");
const commands = @import("editor/commands.zig");
const command_keybindings = @import("editor/keybindings.zig");

pub const KeybindingsConfig = struct {
    new_file: []const u8 = "ctrl+n",
    open_file: []const u8 = "ctrl+o",
    open_folder: []const u8 = "ctrl+f",
    settings: []const u8 = "ctrl+p",
    quit: []const u8 = "ctrl+q",

    toggle_explorer: []const u8 = "ctrl+b",
    toggle_terminal: []const u8 = "ctrl+t",
    switch_focus: []const u8 = "ctrl+e",
    close_tab: []const u8 = "ctrl+w",
    next_tab: []const u8 = "alt+]",
    previous_tab: []const u8 = "alt+[",
    jump_back: []const u8 = "alt+o",
    jump_forward: []const u8 = "alt+p",

    dashboard_up: []const u8 = "up",
    dashboard_down: []const u8 = "down",
    dashboard_select: []const u8 = "enter",

    explorer_up: []const u8 = "up",
    explorer_down: []const u8 = "down",
    explorer_open: []const u8 = "enter",
    explorer_new_file: []const u8 = "alt+n",
    explorer_rename: []const u8 = "alt+r",
    explorer_delete: []const u8 = "alt+delete",

    insert_mode: []const u8 = "i",
    command_mode: []const u8 = ":",
    search_mode: []const u8 = "/",
    normal_mode: []const u8 = "esc",

    insert_newline: []const u8 = "enter",
    delete_back: []const u8 = "backspace",
    delete_word_back: []const u8 = "alt+delete",
    indent: []const u8 = "tab",

    prompt_submit: []const u8 = "enter",
    prompt_backspace: []const u8 = "backspace",

    save: []const u8 = "ctrl+s",
    undo: []const u8 = "ctrl+z",
    redo: []const u8 = "ctrl+y",
    select_all: []const u8 = "ctrl+a",
    copy: []const u8 = "ctrl+c",
    cut: []const u8 = "ctrl+x",
    paste: []const u8 = "ctrl+v",
    duplicate_line: []const u8 = "ctrl+d",
    delete_line: []const u8 = "ctrl+shift+k",
    add_cursor_above: []const u8 = "ctrl+alt+up",
    add_cursor_below: []const u8 = "ctrl+alt+down",

    move_up: []const u8 = "up",
    move_down: []const u8 = "down",
    move_left: []const u8 = "left",
    move_right: []const u8 = "right",
    line_start: []const u8 = "alt+down",
    line_end: []const u8 = "alt+up",
    word_left: []const u8 = "alt+left",
    word_right: []const u8 = "alt+right",

    search_next: []const u8 = "down",
    search_previous: []const u8 = "up",

    completion_auto_trigger: []const u8 = ".",
    completion_trigger: []const u8 = "ctrl+space",
    completion_next: []const u8 = "down",
    completion_previous: []const u8 = "up",
    completion_accept: []const u8 = "enter",
    completion_cancel: []const u8 = "esc",

    global: ?toml.Table = null,
    normal: ?toml.Table = null,
    insert: ?toml.Table = null,
    command_line: ?toml.Table = null,
    dashboard: ?toml.Table = null,
    explorer: ?toml.Table = null,
    explorer_search: ?toml.Table = null,
    search: ?toml.Table = null,
    global_search: ?toml.Table = null,
    help: ?toml.Table = null,
    terminal: ?toml.Table = null,
    picker: ?toml.Table = null,
    picker_new_file: ?toml.Table = null,
    picker_open_folder: ?toml.Table = null,
    prompt: ?toml.Table = null,
    open_file_prompt: ?toml.Table = null,
    completion: ?toml.Table = null,
    save_confirmation: ?toml.Table = null,
    unknown_contexts: []const []const u8 = &.{},

    pub fn tomlIntoStruct(ctx: anytype, table: *toml.Table) !KeybindingsConfig {
        var cfg = KeybindingsConfig{};
        var unknown = std.ArrayListUnmanaged([]const u8).empty;
        errdefer unknown.deinit(ctx.alloc);

        var it = table.iterator();
        while (it.next()) |entry| {
            var consumed = false;

            inline for (@typeInfo(KeybindingsConfig).@"struct".fields) |field| {
                if (comptime field.type == []const u8) {
                    if (std.mem.eql(u8, entry.key_ptr.*, field.name)) {
                        switch (entry.value_ptr.*) {
                            .string => |value| @field(cfg, field.name) = value,
                            else => return error.InvalidValueType,
                        }
                        consumed = true;
                    }
                } else if (comptime field.type == ?toml.Table) {
                    if (std.mem.eql(u8, entry.key_ptr.*, field.name)) {
                        switch (entry.value_ptr.*) {
                            .table => |value| @field(cfg, field.name) = value.*,
                            else => return error.InvalidValueType,
                        }
                        consumed = true;
                    }
                }
            }

            if (!consumed) try unknown.append(ctx.alloc, entry.key_ptr.*);
        }

        cfg.unknown_contexts = try unknown.toOwnedSlice(ctx.alloc);
        return cfg;
    }
};

pub const ExplorerConfig = struct {
    width_percentage: u8 = 20,
};

// ── Root config ──────────────────────────────────────────────────────────────

pub const Config = struct {
    debug: bool = false,
    keybindings: KeybindingsConfig = .{},
    explorer: ExplorerConfig = .{},
};

// ── Validation ───────────────────────────────────────────────────────────────

pub const ConfigError = error{InvalidKeybinding};

fn validateKeybinding(chord: []const u8) ConfigError!void {
    _ = command_keybindings.parseKeySequence(chord) catch return error.InvalidKeybinding;
}

pub fn validate(cfg: *const Config) ConfigError!void {
    inline for (@typeInfo(KeybindingsConfig).@"struct".fields) |field| {
        if (comptime field.type == []const u8) {
            try validateKeybinding(@field(cfg.keybindings, field.name));
        }
    }
}

fn contextTable(cfg: *const KeybindingsConfig, context: command_keybindings.BindingContext) ?toml.Table {
    return switch (context) {
        .global => cfg.global,
        .normal => cfg.normal,
        .insert => cfg.insert,
        .command_line => cfg.command_line,
        .dashboard => cfg.dashboard,
        .explorer => cfg.explorer,
        .explorer_search => cfg.explorer_search,
        .search => cfg.search,
        .global_search => cfg.global_search,
        .help => cfg.help,
        .terminal => cfg.terminal,
        .picker => cfg.picker,
        .picker_new_file => cfg.picker_new_file,
        .picker_open_folder => cfg.picker_open_folder,
        .prompt => cfg.prompt,
        .open_file_prompt => cfg.open_file_prompt,
        .completion => cfg.completion,
        .save_confirmation => cfg.save_confirmation,
    };
}

fn parseKeyForContext(
    allocator: std.mem.Allocator,
    diagnostics: *command_keybindings.BuildDiagnostics,
    context: command_keybindings.BindingContext,
    key_text: []const u8,
) !?command_keybindings.KeySequence {
    return command_keybindings.parseKeySequence(key_text) catch |err| {
        try diagnostics.addError(
            allocator,
            "[{s}] \"{s}\" is not a supported key sequence: {s}",
            .{ @tagName(context), key_text, @errorName(err) },
        );
        return null;
    };
}

fn appendNewBindingTable(
    allocator: std.mem.Allocator,
    diagnostics: *command_keybindings.BuildDiagnostics,
    context: command_keybindings.BindingContext,
    table: *const toml.Table,
    overrides: *std.ArrayListUnmanaged(command_keybindings.UserBindingOverride),
    unbinds: *std.ArrayListUnmanaged(command_keybindings.UserUnbind),
) !void {
    var it = table.iterator();
    while (it.next()) |entry| {
        const key_text = entry.key_ptr.*;
        if (std.mem.eql(u8, key_text, "unbind")) {
            switch (entry.value_ptr.*) {
                .table => |unbind_table| {
                    const keys_value = unbind_table.get("keys") orelse {
                        try diagnostics.addError(allocator, "[{s}.unbind] is missing keys array", .{@tagName(context)});
                        continue;
                    };
                    switch (keys_value) {
                        .array => |items| {
                            for (items.items) |item| {
                                switch (item) {
                                    .string => |unbind_key| {
                                        const sequence = (try parseKeyForContext(allocator, diagnostics, context, unbind_key)) orelse continue;
                                        try unbinds.append(allocator, .{
                                            .context = context,
                                            .sequence = sequence,
                                            .source_key = unbind_key,
                                        });
                                    },
                                    else => try diagnostics.addError(allocator, "[{s}.unbind] keys must be strings", .{@tagName(context)}),
                                }
                            }
                        },
                        else => try diagnostics.addError(allocator, "[{s}.unbind] keys must be an array", .{@tagName(context)}),
                    }
                },
                else => try diagnostics.addError(allocator, "[{s}] unbind must be a table", .{@tagName(context)}),
            }
            continue;
        }

        const command_name = switch (entry.value_ptr.*) {
            .string => |value| value,
            .table => {
                try diagnostics.addError(
                    allocator,
                    "[{s}] \"{s}\" uses inline command args, which are not supported yet",
                    .{ @tagName(context), key_text },
                );
                continue;
            },
            else => {
                try diagnostics.addError(
                    allocator,
                    "[{s}] \"{s}\" must map to a command name string",
                    .{ @tagName(context), key_text },
                );
                continue;
            },
        };
        const sequence = (try parseKeyForContext(allocator, diagnostics, context, key_text)) orelse continue;
        const command = commands.commandByCanonicalName(command_name) orelse {
            try diagnostics.addError(
                allocator,
                "[{s}] \"{s}\" maps to unknown command \"{s}\"",
                .{ @tagName(context), key_text, command_name },
            );
            continue;
        };
        var existing_index: usize = 0;
        while (existing_index < overrides.items.len) {
            const existing = overrides.items[existing_index];
            if (existing.context == context and existing.sequence.eql(sequence)) {
                try diagnostics.addWarning(
                    allocator,
                    "[{s}] \"{s}\" overrides an earlier legacy keybinding",
                    .{ @tagName(context), key_text },
                );
                _ = overrides.orderedRemove(existing_index);
                continue;
            }
            existing_index += 1;
        }
        try overrides.append(allocator, .{
            .context = context,
            .sequence = sequence,
            .command = command,
            .source_key = key_text,
            .source_command = command_name,
        });
    }
}

fn addLegacyOverride(
    allocator: std.mem.Allocator,
    diagnostics: *command_keybindings.BuildDiagnostics,
    overrides: *std.ArrayListUnmanaged(command_keybindings.UserBindingOverride),
    context: command_keybindings.BindingContext,
    command: commands.CommandId,
    key_text: []const u8,
    default_text: []const u8,
    legacy_name: []const u8,
) !void {
    if (std.mem.eql(u8, key_text, default_text)) return;
    const sequence = command_keybindings.parseKeySequence(key_text) catch |err| {
        try diagnostics.addError(
            allocator,
            "legacy [keybindings] {s} = \"{s}\" is invalid: {s}",
            .{ legacy_name, key_text, @errorName(err) },
        );
        return;
    };
    const default_sequence = command_keybindings.parseKeySequence(default_text) catch null;
    try overrides.append(allocator, .{
        .context = context,
        .sequence = sequence,
        .command = command,
        .source_key = key_text,
        .source_command = commands.metadata(command).canonical_name,
        .replace_default_sequence = default_sequence,
    });
}

fn addLegacyInContexts(
    allocator: std.mem.Allocator,
    diagnostics: *command_keybindings.BuildDiagnostics,
    overrides: *std.ArrayListUnmanaged(command_keybindings.UserBindingOverride),
    contexts: []const command_keybindings.BindingContext,
    command: commands.CommandId,
    key_text: []const u8,
    default_text: []const u8,
    legacy_name: []const u8,
) !void {
    for (contexts) |context| {
        try addLegacyOverride(allocator, diagnostics, overrides, context, command, key_text, default_text, legacy_name);
    }
}

fn appendLegacyOverrides(
    allocator: std.mem.Allocator,
    diagnostics: *command_keybindings.BuildDiagnostics,
    cfg: *const KeybindingsConfig,
    overrides: *std.ArrayListUnmanaged(command_keybindings.UserBindingOverride),
) !void {
    const defaults = KeybindingsConfig{};

    try addLegacyOverride(allocator, diagnostics, overrides, .dashboard, .dashboard_new_file, cfg.new_file, defaults.new_file, "new_file");
    try addLegacyOverride(allocator, diagnostics, overrides, .dashboard, .dashboard_open_file, cfg.open_file, defaults.open_file, "open_file");
    try addLegacyOverride(allocator, diagnostics, overrides, .dashboard, .dashboard_open_folder, cfg.open_folder, defaults.open_folder, "open_folder");
    try addLegacyOverride(allocator, diagnostics, overrides, .dashboard, .dashboard_settings, cfg.settings, defaults.settings, "settings");
    try addLegacyOverride(allocator, diagnostics, overrides, .global, .app_quit_flamingo, cfg.quit, defaults.quit, "quit");
    try addLegacyOverride(allocator, diagnostics, overrides, .dashboard, .app_quit_flamingo, cfg.quit, defaults.quit, "quit");
    try addLegacyOverride(allocator, diagnostics, overrides, .global, .explorer_toggle, cfg.toggle_explorer, defaults.toggle_explorer, "toggle_explorer");
    try addLegacyOverride(allocator, diagnostics, overrides, .global, .terminal_toggle, cfg.toggle_terminal, defaults.toggle_terminal, "toggle_terminal");
    try addLegacyOverride(allocator, diagnostics, overrides, .global, .app_cycle_panel_focus, cfg.switch_focus, defaults.switch_focus, "switch_focus");
    try addLegacyOverride(allocator, diagnostics, overrides, .global, .app_close_tab, cfg.close_tab, defaults.close_tab, "close_tab");
    try addLegacyOverride(allocator, diagnostics, overrides, .global, .app_next_tab, cfg.next_tab, defaults.next_tab, "next_tab");
    try addLegacyOverride(allocator, diagnostics, overrides, .global, .app_previous_tab, cfg.previous_tab, defaults.previous_tab, "previous_tab");
    try addLegacyOverride(allocator, diagnostics, overrides, .normal, .navigation_jump_back, cfg.jump_back, defaults.jump_back, "jump_back");
    try addLegacyOverride(allocator, diagnostics, overrides, .normal, .navigation_jump_forward, cfg.jump_forward, defaults.jump_forward, "jump_forward");

    try addLegacyOverride(allocator, diagnostics, overrides, .dashboard, .dashboard_move_up, cfg.dashboard_up, defaults.dashboard_up, "dashboard_up");
    try addLegacyOverride(allocator, diagnostics, overrides, .dashboard, .dashboard_move_down, cfg.dashboard_down, defaults.dashboard_down, "dashboard_down");
    try addLegacyOverride(allocator, diagnostics, overrides, .dashboard, .dashboard_select, cfg.dashboard_select, defaults.dashboard_select, "dashboard_select");
    try addLegacyInContexts(allocator, diagnostics, overrides, &.{ .explorer, .explorer_search }, .explorer_move_up, cfg.explorer_up, defaults.explorer_up, "explorer_up");
    try addLegacyInContexts(allocator, diagnostics, overrides, &.{ .explorer, .explorer_search }, .explorer_move_down, cfg.explorer_down, defaults.explorer_down, "explorer_down");
    try addLegacyInContexts(allocator, diagnostics, overrides, &.{ .explorer, .explorer_search }, .explorer_open_selected, cfg.explorer_open, defaults.explorer_open, "explorer_open");
    try addLegacyOverride(allocator, diagnostics, overrides, .explorer, .explorer_new_file, cfg.explorer_new_file, defaults.explorer_new_file, "explorer_new_file");
    try addLegacyOverride(allocator, diagnostics, overrides, .explorer, .explorer_rename, cfg.explorer_rename, defaults.explorer_rename, "explorer_rename");
    try addLegacyOverride(allocator, diagnostics, overrides, .explorer, .explorer_delete, cfg.explorer_delete, defaults.explorer_delete, "explorer_delete");

    try addLegacyOverride(allocator, diagnostics, overrides, .normal, .mode_insert, cfg.insert_mode, defaults.insert_mode, "insert_mode");
    try addLegacyInContexts(allocator, diagnostics, overrides, &.{ .normal, .dashboard }, .mode_command, cfg.command_mode, defaults.command_mode, "command_mode");
    try addLegacyOverride(allocator, diagnostics, overrides, .normal, .mode_search, cfg.search_mode, defaults.search_mode, "search_mode");
    try addLegacyOverride(allocator, diagnostics, overrides, .explorer, .explorer_search_open, cfg.search_mode, defaults.search_mode, "search_mode");
    try addLegacyOverride(allocator, diagnostics, overrides, .insert, .mode_normal, cfg.normal_mode, defaults.normal_mode, "normal_mode");
    try addLegacyOverride(allocator, diagnostics, overrides, .terminal, .mode_normal, cfg.normal_mode, defaults.normal_mode, "normal_mode");
    try addLegacyOverride(allocator, diagnostics, overrides, .command_line, .command_cancel, cfg.normal_mode, defaults.normal_mode, "normal_mode");
    try addLegacyOverride(allocator, diagnostics, overrides, .search, .search_cancel, cfg.normal_mode, defaults.normal_mode, "normal_mode");
    try addLegacyOverride(allocator, diagnostics, overrides, .global_search, .global_search_cancel, cfg.normal_mode, defaults.normal_mode, "normal_mode");
    try addLegacyOverride(allocator, diagnostics, overrides, .explorer_search, .explorer_search_cancel, cfg.normal_mode, defaults.normal_mode, "normal_mode");
    try addLegacyOverride(allocator, diagnostics, overrides, .picker, .picker_cancel, cfg.normal_mode, defaults.normal_mode, "normal_mode");
    try addLegacyOverride(allocator, diagnostics, overrides, .open_file_prompt, .open_file_prompt_cancel, cfg.normal_mode, defaults.normal_mode, "normal_mode");
    try addLegacyOverride(allocator, diagnostics, overrides, .help, .help_close, cfg.normal_mode, defaults.normal_mode, "normal_mode");
    try addLegacyOverride(allocator, diagnostics, overrides, .prompt, .prompt_cancel, cfg.normal_mode, defaults.normal_mode, "normal_mode");
    try addLegacyOverride(allocator, diagnostics, overrides, .save_confirmation, .save_confirmation_cancel, cfg.normal_mode, defaults.normal_mode, "normal_mode");

    try addLegacyOverride(allocator, diagnostics, overrides, .insert, .editing_insert_newline, cfg.insert_newline, defaults.insert_newline, "insert_newline");
    try addLegacyOverride(allocator, diagnostics, overrides, .insert, .editing_delete_back, cfg.delete_back, defaults.delete_back, "delete_back");
    try addLegacyInContexts(allocator, diagnostics, overrides, &.{ .normal, .insert }, .editing_delete_word_back, cfg.delete_word_back, defaults.delete_word_back, "delete_word_back");
    try addLegacyOverride(allocator, diagnostics, overrides, .insert, .editing_indent, cfg.indent, defaults.indent, "indent");
    try addLegacyOverride(allocator, diagnostics, overrides, .command_line, .command_suggestion_next, cfg.indent, defaults.indent, "indent");
    try addLegacyOverride(allocator, diagnostics, overrides, .global_search, .global_search_select_next, cfg.indent, defaults.indent, "indent");
    try addLegacyOverride(allocator, diagnostics, overrides, .prompt, .prompt_submit, cfg.prompt_submit, defaults.prompt_submit, "prompt_submit");
    try addLegacyOverride(allocator, diagnostics, overrides, .command_line, .command_execute, cfg.prompt_submit, defaults.prompt_submit, "prompt_submit");
    try addLegacyOverride(allocator, diagnostics, overrides, .search, .search_accept, cfg.prompt_submit, defaults.prompt_submit, "prompt_submit");
    try addLegacyOverride(allocator, diagnostics, overrides, .global_search, .global_search_accept, cfg.prompt_submit, defaults.prompt_submit, "prompt_submit");
    try addLegacyOverride(allocator, diagnostics, overrides, .picker, .picker_accept, cfg.prompt_submit, defaults.prompt_submit, "prompt_submit");
    try addLegacyOverride(allocator, diagnostics, overrides, .open_file_prompt, .open_file_prompt_submit, cfg.prompt_submit, defaults.prompt_submit, "prompt_submit");
    try addLegacyOverride(allocator, diagnostics, overrides, .save_confirmation, .save_confirmation_discard, cfg.prompt_submit, defaults.prompt_submit, "prompt_submit");
    try addLegacyOverride(allocator, diagnostics, overrides, .prompt, .prompt_backspace, cfg.prompt_backspace, defaults.prompt_backspace, "prompt_backspace");
    try addLegacyOverride(allocator, diagnostics, overrides, .command_line, .command_backspace, cfg.prompt_backspace, defaults.prompt_backspace, "prompt_backspace");
    try addLegacyOverride(allocator, diagnostics, overrides, .search, .search_backspace, cfg.prompt_backspace, defaults.prompt_backspace, "prompt_backspace");
    try addLegacyOverride(allocator, diagnostics, overrides, .global_search, .global_search_backspace, cfg.prompt_backspace, defaults.prompt_backspace, "prompt_backspace");
    try addLegacyOverride(allocator, diagnostics, overrides, .picker, .picker_back, cfg.prompt_backspace, defaults.prompt_backspace, "prompt_backspace");
    try addLegacyOverride(allocator, diagnostics, overrides, .explorer_search, .explorer_search_backspace, cfg.prompt_backspace, defaults.prompt_backspace, "prompt_backspace");
    try addLegacyOverride(allocator, diagnostics, overrides, .open_file_prompt, .open_file_prompt_backspace, cfg.prompt_backspace, defaults.prompt_backspace, "prompt_backspace");

    try addLegacyInContexts(allocator, diagnostics, overrides, &.{ .normal, .insert }, .file_write, cfg.save, defaults.save, "save");
    try addLegacyInContexts(allocator, diagnostics, overrides, &.{ .normal, .insert }, .editing_undo, cfg.undo, defaults.undo, "undo");
    try addLegacyInContexts(allocator, diagnostics, overrides, &.{ .normal, .insert }, .editing_redo, cfg.redo, defaults.redo, "redo");
    try addLegacyInContexts(allocator, diagnostics, overrides, &.{ .normal, .insert }, .editing_select_all, cfg.select_all, defaults.select_all, "select_all");
    try addLegacyInContexts(allocator, diagnostics, overrides, &.{ .normal, .insert }, .editing_copy, cfg.copy, defaults.copy, "copy");
    try addLegacyInContexts(allocator, diagnostics, overrides, &.{ .normal, .insert }, .editing_cut, cfg.cut, defaults.cut, "cut");
    try addLegacyInContexts(allocator, diagnostics, overrides, &.{ .normal, .insert }, .editing_paste, cfg.paste, defaults.paste, "paste");
    try addLegacyInContexts(allocator, diagnostics, overrides, &.{ .normal, .insert }, .editing_duplicate_line, cfg.duplicate_line, defaults.duplicate_line, "duplicate_line");
    try addLegacyInContexts(allocator, diagnostics, overrides, &.{ .normal, .insert }, .editing_delete_line, cfg.delete_line, defaults.delete_line, "delete_line");
    try addLegacyInContexts(allocator, diagnostics, overrides, &.{ .normal, .insert }, .editing_add_cursor_above, cfg.add_cursor_above, defaults.add_cursor_above, "add_cursor_above");
    try addLegacyInContexts(allocator, diagnostics, overrides, &.{ .normal, .insert }, .editing_add_cursor_below, cfg.add_cursor_below, defaults.add_cursor_below, "add_cursor_below");

    try addLegacyInContexts(allocator, diagnostics, overrides, &.{ .normal, .insert }, .navigation_move_up, cfg.move_up, defaults.move_up, "move_up");
    try addLegacyInContexts(allocator, diagnostics, overrides, &.{ .normal, .insert }, .navigation_move_down, cfg.move_down, defaults.move_down, "move_down");
    try addLegacyInContexts(allocator, diagnostics, overrides, &.{ .normal, .insert }, .navigation_move_left, cfg.move_left, defaults.move_left, "move_left");
    try addLegacyInContexts(allocator, diagnostics, overrides, &.{ .normal, .insert }, .navigation_move_right, cfg.move_right, defaults.move_right, "move_right");
    try addLegacyInContexts(allocator, diagnostics, overrides, &.{ .normal, .insert }, .navigation_line_start, cfg.line_start, defaults.line_start, "line_start");
    try addLegacyInContexts(allocator, diagnostics, overrides, &.{ .normal, .insert }, .navigation_line_end, cfg.line_end, defaults.line_end, "line_end");
    try addLegacyInContexts(allocator, diagnostics, overrides, &.{ .normal, .insert }, .navigation_word_left, cfg.word_left, defaults.word_left, "word_left");
    try addLegacyInContexts(allocator, diagnostics, overrides, &.{ .normal, .insert }, .navigation_word_right, cfg.word_right, defaults.word_right, "word_right");
    try addLegacyOverride(allocator, diagnostics, overrides, .search, .search_next_match, cfg.search_next, defaults.search_next, "search_next");
    try addLegacyOverride(allocator, diagnostics, overrides, .search, .search_previous_match, cfg.search_previous, defaults.search_previous, "search_previous");
    try addLegacyInContexts(allocator, diagnostics, overrides, &.{ .normal, .insert }, .completion_auto_trigger, cfg.completion_auto_trigger, defaults.completion_auto_trigger, "completion_auto_trigger");
    try addLegacyInContexts(allocator, diagnostics, overrides, &.{ .normal, .insert }, .completion_trigger, cfg.completion_trigger, defaults.completion_trigger, "completion_trigger");
    try addLegacyOverride(allocator, diagnostics, overrides, .completion, .completion_next, cfg.completion_next, defaults.completion_next, "completion_next");
    try addLegacyOverride(allocator, diagnostics, overrides, .completion, .completion_previous, cfg.completion_previous, defaults.completion_previous, "completion_previous");
    try addLegacyOverride(allocator, diagnostics, overrides, .completion, .completion_accept, cfg.completion_accept, defaults.completion_accept, "completion_accept");
    try addLegacyOverride(allocator, diagnostics, overrides, .completion, .completion_cancel, cfg.completion_cancel, defaults.completion_cancel, "completion_cancel");
}

pub fn buildKeybindingRegistry(
    allocator: std.mem.Allocator,
    cfg: *const Config,
    diagnostics: *command_keybindings.BuildDiagnostics,
) !command_keybindings.Registry {
    for (cfg.keybindings.unknown_contexts) |name| {
        try diagnostics.addError(allocator, "[keybindings.{s}] is not a supported keybinding context", .{name});
    }

    var overrides = std.ArrayListUnmanaged(command_keybindings.UserBindingOverride).empty;
    defer overrides.deinit(allocator);
    var unbinds = std.ArrayListUnmanaged(command_keybindings.UserUnbind).empty;
    defer unbinds.deinit(allocator);

    try appendLegacyOverrides(allocator, diagnostics, &cfg.keybindings, &overrides);

    inline for (std.meta.fields(command_keybindings.BindingContext)) |field| {
        const context: command_keybindings.BindingContext = @enumFromInt(field.value);
        if (contextTable(&cfg.keybindings, context)) |table| {
            try appendNewBindingTable(allocator, diagnostics, context, &table, &overrides, &unbinds);
        }
    }

    return command_keybindings.Registry.fromDefaultsAndConfig(allocator, overrides.items, unbinds.items, diagnostics);
}

// ── Loading ──────────────────────────────────────────────────────────────────

pub fn loadFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
) !toml.Parsed(Config) {
    // Read the whole file into a slice — caller's allocator owns it.
    const source = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, std.Io.Limit.limited(4 * 1024 * 1024));
    defer allocator.free(source);

    var parser = toml.Parser(Config).init(allocator);
    defer parser.deinit();

    return parser.parseString(source);
}
