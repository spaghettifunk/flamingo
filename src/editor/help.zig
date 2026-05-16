const std = @import("std");
const config = @import("../config.zig");

pub const HelpCategory = enum {
    modes,
    files,
    navigation,
    search,
    editing,
    explorer,
    tabs_buffers,
    folding,
    terminal,
    lsp,
    misc,

    pub fn title(self: HelpCategory) []const u8 {
        return switch (self) {
            .modes => "Modes",
            .files => "Files",
            .navigation => "Navigation",
            .search => "Search",
            .editing => "Editing",
            .explorer => "Explorer",
            .tabs_buffers => "Tabs / Buffers",
            .folding => "Folding",
            .terminal => "Terminal",
            .lsp => "LSP",
            .misc => "Miscellaneous",
        };
    }
};

pub const KeyBindingRef = enum {
    insert_mode,
    command_mode,
    search_mode,
    normal_mode,
    save,
    quit,
    close_tab,
    next_tab,
    previous_tab,
    jump_back,
    jump_forward,
    move_up,
    move_down,
    move_left,
    move_right,
    line_start,
    line_end,
    word_left,
    word_right,
    insert_newline,
    delete_back,
    delete_word_back,
    indent,
    undo,
    redo,
    select_all,
    copy,
    cut,
    paste,
    duplicate_line,
    delete_line,
    add_cursor_above,
    add_cursor_below,
    toggle_explorer,
    toggle_terminal,
    switch_focus,
    explorer_up,
    explorer_down,
    explorer_open,
    explorer_new_file,
    explorer_rename,
    explorer_delete,
    prompt_submit,
    prompt_backspace,
    search_next,
    search_previous,
    completion_auto_trigger,
    completion_trigger,
    completion_next,
    completion_previous,
    completion_accept,
    completion_cancel,

    pub fn value(self: KeyBindingRef, keys: config.KeybindingsConfig) []const u8 {
        return switch (self) {
            .insert_mode => keys.insert_mode,
            .command_mode => keys.command_mode,
            .search_mode => keys.search_mode,
            .normal_mode => keys.normal_mode,
            .save => keys.save,
            .quit => keys.quit,
            .close_tab => keys.close_tab,
            .next_tab => keys.next_tab,
            .previous_tab => keys.previous_tab,
            .jump_back => keys.jump_back,
            .jump_forward => keys.jump_forward,
            .move_up => keys.move_up,
            .move_down => keys.move_down,
            .move_left => keys.move_left,
            .move_right => keys.move_right,
            .line_start => keys.line_start,
            .line_end => keys.line_end,
            .word_left => keys.word_left,
            .word_right => keys.word_right,
            .insert_newline => keys.insert_newline,
            .delete_back => keys.delete_back,
            .delete_word_back => keys.delete_word_back,
            .indent => keys.indent,
            .undo => keys.undo,
            .redo => keys.redo,
            .select_all => keys.select_all,
            .copy => keys.copy,
            .cut => keys.cut,
            .paste => keys.paste,
            .duplicate_line => keys.duplicate_line,
            .delete_line => keys.delete_line,
            .add_cursor_above => keys.add_cursor_above,
            .add_cursor_below => keys.add_cursor_below,
            .toggle_explorer => keys.toggle_explorer,
            .toggle_terminal => keys.toggle_terminal,
            .switch_focus => keys.switch_focus,
            .explorer_up => keys.explorer_up,
            .explorer_down => keys.explorer_down,
            .explorer_open => keys.explorer_open,
            .explorer_new_file => keys.explorer_new_file,
            .explorer_rename => keys.explorer_rename,
            .explorer_delete => keys.explorer_delete,
            .prompt_submit => keys.prompt_submit,
            .prompt_backspace => keys.prompt_backspace,
            .search_next => keys.search_next,
            .search_previous => keys.search_previous,
            .completion_auto_trigger => keys.completion_auto_trigger,
            .completion_trigger => keys.completion_trigger,
            .completion_next => keys.completion_next,
            .completion_previous => keys.completion_previous,
            .completion_accept => keys.completion_accept,
            .completion_cancel => keys.completion_cancel,
        };
    }
};

pub const HelpKey = union(enum) {
    literal: []const u8,
    binding: KeyBindingRef,
};

pub const HelpEntry = struct {
    key: HelpKey,
    description: []const u8,
};

pub const HelpSection = struct {
    category: HelpCategory,
    entries: []const HelpEntry,
};

pub const HelpRow = union(enum) {
    category: HelpCategory,
    entry: HelpEntry,
};

const modes_entries = [_]HelpEntry{
    .{ .key = .{ .binding = .insert_mode }, .description = "Enter insert mode" },
    .{ .key = .{ .binding = .normal_mode }, .description = "Return to normal mode" },
    .{ .key = .{ .binding = .command_mode }, .description = "Open command prompt" },
    .{ .key = .{ .binding = .search_mode }, .description = "Search current buffer" },
};

const file_entries = [_]HelpEntry{
    .{ .key = .{ .literal = ":w [path]" }, .description = "Save current buffer" },
    .{ .key = .{ .literal = ":wall / :wa" }, .description = "Save all modified buffers" },
    .{ .key = .{ .literal = ":q" }, .description = "Quit current tab" },
    .{ .key = .{ .literal = ":qall / :qa" }, .description = "Quit all tabs" },
    .{ .key = .{ .literal = ":q!" }, .description = "Force quit current tab" },
    .{ .key = .{ .literal = ":wq [path]" }, .description = "Save and quit" },
    .{ .key = .{ .literal = ":newFile / :nf" }, .description = "Create and open a file" },
    .{ .key = .{ .literal = ":renameFile / :rf" }, .description = "Rename a file" },
    .{ .key = .{ .literal = ":deleteFile / :df" }, .description = "Delete a file" },
};

const navigation_entries = [_]HelpEntry{
    .{ .key = .{ .literal = "arrows" }, .description = "Move cursor" },
    .{ .key = .{ .binding = .word_left }, .description = "Jump word left" },
    .{ .key = .{ .binding = .word_right }, .description = "Jump word right" },
    .{ .key = .{ .binding = .line_start }, .description = "Go to line start" },
    .{ .key = .{ .binding = .line_end }, .description = "Go to line end" },
    .{ .key = .{ .literal = "PageUp/PageDown" }, .description = "Move by page" },
    .{ .key = .{ .literal = "gg / G" }, .description = "Go to file start/end" },
    .{ .key = .{ .literal = "%" }, .description = "Jump to matching bracket" },
    .{ .key = .{ .literal = "f" }, .description = "Go to definition" },
    .{ .key = .{ .binding = .jump_back }, .description = "Jump back" },
    .{ .key = .{ .binding = .jump_forward }, .description = "Jump forward" },
    .{ .key = .{ .literal = ":<number>" }, .description = "Jump to line" },
    .{ .key = .{ .literal = ":goto / :line" }, .description = "Jump to line" },
};

const search_entries = [_]HelpEntry{
    .{ .key = .{ .binding = .search_mode }, .description = "Search current buffer" },
    .{ .key = .{ .binding = .search_next }, .description = "Next search match" },
    .{ .key = .{ .binding = .search_previous }, .description = "Previous search match" },
    .{ .key = .{ .literal = ":search" }, .description = "Open project search" },
    .{ .key = .{ .literal = "Tab/Down" }, .description = "Next project result" },
    .{ .key = .{ .literal = "Up" }, .description = "Previous project result" },
};

const editing_entries = [_]HelpEntry{
    .{ .key = .{ .binding = .save }, .description = "Save current file" },
    .{ .key = .{ .binding = .undo }, .description = "Undo" },
    .{ .key = .{ .binding = .redo }, .description = "Redo" },
    .{ .key = .{ .binding = .select_all }, .description = "Select all" },
    .{ .key = .{ .binding = .copy }, .description = "Copy selection" },
    .{ .key = .{ .binding = .cut }, .description = "Cut selection" },
    .{ .key = .{ .binding = .paste }, .description = "Paste" },
    .{ .key = .{ .binding = .duplicate_line }, .description = "Duplicate line" },
    .{ .key = .{ .binding = .delete_line }, .description = "Delete line" },
    .{ .key = .{ .binding = .delete_word_back }, .description = "Delete word backward" },
    .{ .key = .{ .binding = .indent }, .description = "Insert four spaces" },
    .{ .key = .{ .binding = .add_cursor_above }, .description = "Add cursor above" },
    .{ .key = .{ .binding = .add_cursor_below }, .description = "Add cursor below" },
    .{ .key = .{ .literal = "Shift+movement" }, .description = "Extend selection" },
};

const explorer_entries = [_]HelpEntry{
    .{ .key = .{ .binding = .toggle_explorer }, .description = "Toggle explorer" },
    .{ .key = .{ .binding = .switch_focus }, .description = "Cycle panel focus" },
    .{ .key = .{ .literal = "Up/Down" }, .description = "Move selection" },
    .{ .key = .{ .binding = .explorer_open }, .description = "Open file or folder" },
    .{ .key = .{ .binding = .search_mode }, .description = "Search explorer" },
    .{ .key = .{ .binding = .explorer_new_file }, .description = "Create file in folder" },
    .{ .key = .{ .binding = .explorer_rename }, .description = "Rename file" },
    .{ .key = .{ .binding = .explorer_delete }, .description = "Delete file" },
};

const tabs_entries = [_]HelpEntry{
    .{ .key = .{ .binding = .close_tab }, .description = "Close current tab" },
    .{ .key = .{ .binding = .next_tab }, .description = "Next tab" },
    .{ .key = .{ .binding = .previous_tab }, .description = "Previous tab" },
    .{ .key = .{ .binding = .quit }, .description = "Quit Flamingo" },
};

const folding_entries = [_]HelpEntry{
    .{ .key = .{ .literal = "zh / zl" }, .description = "Scroll horizontally" },
    .{ .key = .{ .literal = "zH / zL" }, .description = "Scroll half page" },
    .{ .key = .{ .literal = "zs / ze" }, .description = "Align cursor horizontally" },
    .{ .key = .{ .literal = "zc / zo" }, .description = "Fold/unfold block" },
    .{ .key = .{ .literal = "za" }, .description = "Toggle fold" },
    .{ .key = .{ .literal = "zM / zR" }, .description = "Fold/unfold all" },
    .{ .key = .{ .literal = "zA" }, .description = "Toggle all folds" },
};

const terminal_entries = [_]HelpEntry{
    .{ .key = .{ .binding = .toggle_terminal }, .description = "Toggle terminal" },
    .{ .key = .{ .binding = .switch_focus }, .description = "Cycle panel focus" },
    .{ .key = .{ .binding = .normal_mode }, .description = "Return to editor" },
    .{ .key = .{ .literal = "PageUp/PageDown" }, .description = "Scroll output" },
    .{ .key = .{ .literal = "Shift+End" }, .description = "Scroll to bottom" },
};

const lsp_entries = [_]HelpEntry{
    .{ .key = .{ .literal = "f" }, .description = "Go to definition" },
    .{ .key = .{ .binding = .completion_auto_trigger }, .description = "Auto trigger completion" },
    .{ .key = .{ .binding = .completion_trigger }, .description = "Trigger completion" },
    .{ .key = .{ .literal = "Up/Down" }, .description = "Select completion" },
    .{ .key = .{ .binding = .completion_accept }, .description = "Accept completion" },
    .{ .key = .{ .binding = .completion_cancel }, .description = "Cancel completion" },
};

const misc_entries = [_]HelpEntry{
    .{ .key = .{ .literal = ":help" }, .description = "Open this help popup" },
    .{ .key = .{ .literal = "q / Esc" }, .description = "Close help" },
    .{ .key = .{ .literal = "Up/Down" }, .description = "Scroll help" },
    .{ .key = .{ .literal = "PgUp/PgDn" }, .description = "Scroll help by page" },
};

pub const sections = [_]HelpSection{
    .{ .category = .modes, .entries = &modes_entries },
    .{ .category = .files, .entries = &file_entries },
    .{ .category = .navigation, .entries = &navigation_entries },
    .{ .category = .search, .entries = &search_entries },
    .{ .category = .editing, .entries = &editing_entries },
    .{ .category = .explorer, .entries = &explorer_entries },
    .{ .category = .tabs_buffers, .entries = &tabs_entries },
    .{ .category = .folding, .entries = &folding_entries },
    .{ .category = .terminal, .entries = &terminal_entries },
    .{ .category = .lsp, .entries = &lsp_entries },
    .{ .category = .misc, .entries = &misc_entries },
};

pub const HelpPopup = struct {
    visible: bool = false,
    scroll_offset: usize = 0,

    pub fn open(self: *HelpPopup) void {
        self.visible = true;
        self.scroll_offset = 0;
    }

    pub fn close(self: *HelpPopup) void {
        self.visible = false;
        self.scroll_offset = 0;
    }

    pub fn totalRows(self: *const HelpPopup) usize {
        _ = self;
        return registryTotalRows();
    }

    pub fn rowAt(self: *const HelpPopup, index: usize) ?HelpRow {
        _ = self;
        return registryRowAt(index);
    }

    pub fn scrollUp(self: *HelpPopup, lines: usize) void {
        self.scroll_offset -|= lines;
    }

    pub fn scrollDown(self: *HelpPopup, lines: usize, view_height: usize) void {
        const total = self.totalRows();
        if (view_height == 0 or total <= view_height) {
            self.scroll_offset = 0;
            return;
        }
        self.scroll_offset = @min(self.scroll_offset + lines, total - view_height);
    }

    pub fn clampScroll(self: *HelpPopup, view_height: usize) void {
        const total = self.totalRows();
        if (view_height == 0 or total <= view_height) {
            self.scroll_offset = 0;
            return;
        }
        self.scroll_offset = @min(self.scroll_offset, total - view_height);
    }
};

pub fn registryTotalRows() usize {
    var count: usize = 0;
    for (sections) |section| {
        count += 1 + section.entries.len;
    }
    return count;
}

pub fn registryRowAt(index: usize) ?HelpRow {
    var row: usize = 0;
    for (sections) |section| {
        if (row == index) return .{ .category = section.category };
        row += 1;
        if (index < row + section.entries.len) {
            return .{ .entry = section.entries[index - row] };
        }
        row += section.entries.len;
    }
    return null;
}

pub fn keyText(entry: HelpEntry, keys: config.KeybindingsConfig) []const u8 {
    return switch (entry.key) {
        .literal => |text| text,
        .binding => |binding| binding.value(keys),
    };
}

test "help registry has rows and includes help command" {
    try std.testing.expect(registryTotalRows() > 0);
    var found = false;
    for (0..registryTotalRows()) |i| {
        switch (registryRowAt(i).?) {
            .entry => |entry| {
                const text = keyText(entry, .{});
                if (std.mem.eql(u8, text, ":help")) found = true;
            },
            .category => {},
        }
    }
    try std.testing.expect(found);
}

test "help registry starts with modes category" {
    const first = registryRowAt(0) orelse return error.ExpectedRow;
    try std.testing.expectEqual(HelpCategory.modes, first.category);
}

test "help popup scroll clamps" {
    var popup = HelpPopup{};
    popup.open();
    popup.scrollDown(1000, 8);
    try std.testing.expect(popup.scroll_offset <= popup.totalRows() - 8);
    popup.scrollUp(1000);
    try std.testing.expectEqual(@as(usize, 0), popup.scroll_offset);
    popup.scrollDown(5, 1000);
    try std.testing.expectEqual(@as(usize, 0), popup.scroll_offset);
}
