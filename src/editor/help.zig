const std = @import("std");
const commands = @import("commands.zig");
const keybindings = @import("keybindings.zig");

pub const HelpBinding = struct {
    context: commands.CommandContext,
    sequence: keybindings.KeySequence,
};

pub const HelpCommand = struct {
    meta: *const commands.CommandMeta,
};

pub const HelpRow = union(enum) {
    category: commands.CommandCategory,
    command: HelpCommand,
};

pub const HelpModel = struct {
    registry: *const keybindings.Registry,

    pub fn totalRows(self: *const HelpModel) usize {
        return registryTotalRows(self.registry);
    }

    pub fn rowAt(self: *const HelpModel, index: usize) ?HelpRow {
        return registryRowAt(self.registry, index);
    }
};

const category_order = [_]commands.CommandCategory{
    .mode,
    .app,
    .file,
    .tab,
    .navigation,
    .search,
    .global_search,
    .agent,
    .git,
    .todos,
    .comments,
    .help,
    .lsp,
    .folding,
    .editing,
    .explorer,
    .dashboard,
    .terminal,
    .tasks,
    .completion,
    .picker,
    .prompt,
    .debug,
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

    pub fn totalRows(self: *const HelpPopup, registry: *const keybindings.Registry) usize {
        _ = self;
        return registryTotalRows(registry);
    }

    pub fn rowAt(self: *const HelpPopup, registry: *const keybindings.Registry, index: usize) ?HelpRow {
        _ = self;
        return registryRowAt(registry, index);
    }

    pub fn scrollUp(self: *HelpPopup, lines: usize) void {
        self.scroll_offset -|= lines;
    }

    pub fn scrollDown(self: *HelpPopup, registry: *const keybindings.Registry, lines: usize, view_height: usize) void {
        const total = self.totalRows(registry);
        if (view_height == 0 or total <= view_height) {
            self.scroll_offset = 0;
            return;
        }
        self.scroll_offset = @min(self.scroll_offset + lines, total - view_height);
    }

    pub fn clampScroll(self: *HelpPopup, registry: *const keybindings.Registry, view_height: usize) void {
        const total = self.totalRows(registry);
        if (view_height == 0 or total <= view_height) {
            self.scroll_offset = 0;
            return;
        }
        self.scroll_offset = @min(self.scroll_offset, total - view_height);
    }
};

pub fn categoryTitle(category: commands.CommandCategory) []const u8 {
    return switch (category) {
        .mode => "Modes",
        .app => "App",
        .file => "Files",
        .tab => "Tabs",
        .navigation => "Navigation",
        .search => "Search",
        .global_search => "Global Search",
        .agent => "Agent",
        .proposals => "Proposals",
        .git => "Git",
        .help => "Help",
        .todos => "TODOs",
        .comments => "Comments",
        .lsp => "LSP",
        .folding => "Folding",
        .editing => "Editing",
        .explorer => "Explorer",
        .dashboard => "Dashboard",
        .terminal => "Terminal",
        .tasks => "Tasks",
        .completion => "Completion",
        .picker => "Picker",
        .prompt => "Prompts",
        .debug => "Debug",
    };
}

pub fn contextLabel(context: commands.CommandContext) []const u8 {
    return switch (context) {
        .command_line => "command",
        .normal => "normal",
        .insert => "insert",
        .dashboard => "dashboard",
        .explorer => "explorer",
        .explorer_search => "explorer search",
        .search => "search",
        .global_search => "global search",
        .agent => "agent",
        .proposals => "proposals",
        .git_diff => "git diff",
        .task_panel => "tasks",
        .git_graph => "git graph",
        .todo_panel => "todo panel",
        .comments_panel => "comments panel",
        .help => "help",
        .terminal => "terminal",
        .picker => "picker",
        .picker_new_file => "new file picker",
        .picker_open_folder => "folder picker",
        .prompt => "prompt",
        .open_file_prompt => "open file prompt",
        .completion => "completion",
        .save_confirmation => "save confirmation",
        .global => "global",
    };
}

fn append(buf: []u8, index: *usize, text: []const u8) void {
    if (index.* >= buf.len) return;
    const len = @min(text.len, buf.len - index.*);
    @memcpy(buf[index.* .. index.* + len], text[0..len]);
    index.* += len;
}

fn appendFmt(buf: []u8, index: *usize, comptime fmt: []const u8, args: anytype) void {
    if (index.* >= buf.len) return;
    const written = std.fmt.bufPrint(buf[index.*..], fmt, args) catch return;
    index.* += written.len;
}

fn appendCommandLineName(buf: []u8, index: *usize, name: []const u8) void {
    append(buf, index, ":");
    append(buf, index, name);
}

fn commandCountForCategory(category: commands.CommandCategory) usize {
    var count: usize = 0;
    for (commands.all()) |meta| {
        if (meta.show_in_help and meta.category == category) count += 1;
    }
    return count;
}

pub fn registryTotalRows(registry: *const keybindings.Registry) usize {
    _ = registry;
    var count: usize = 0;
    for (category_order) |category| {
        const command_count = commandCountForCategory(category);
        if (command_count == 0) continue;
        count += 1 + command_count;
    }
    return count;
}

pub fn registryRowAt(registry: *const keybindings.Registry, index: usize) ?HelpRow {
    _ = registry;
    var row: usize = 0;
    for (category_order) |category| {
        const command_count = commandCountForCategory(category);
        if (command_count == 0) continue;

        if (row == index) return .{ .category = category };
        row += 1;

        for (commands.all()) |*meta| {
            if (!meta.show_in_help or meta.category != category) continue;
            if (row == index) return .{ .command = .{ .meta = meta } };
            row += 1;
        }
    }
    return null;
}

pub fn countBindingsForCommand(registry: *const keybindings.Registry, id: commands.CommandId) usize {
    return registry.countBindingsForCommand(id);
}

pub fn formatCommandKeys(meta: *const commands.CommandMeta, registry: *const keybindings.Registry, buf: []u8) []const u8 {
    var index: usize = 0;
    var wrote_any = false;

    for (meta.command_names) |name| {
        if (wrote_any) append(buf, &index, ", ");
        appendCommandLineName(buf, &index, name);
        wrote_any = true;
    }
    for (meta.aliases) |alias| {
        if (wrote_any) append(buf, &index, ", ");
        appendCommandLineName(buf, &index, alias);
        wrote_any = true;
    }

    inline for (std.meta.fields(commands.CommandContext)) |field| {
        const context: commands.CommandContext = @enumFromInt(field.value);
        for (registry.bindings) |binding| {
            if (binding.command != meta.id or binding.context != context) continue;
            if (wrote_any) append(buf, &index, ", ");
            appendFmt(buf, &index, "{s}: ", .{contextLabel(binding.context)});
            var key_buf: [48]u8 = undefined;
            append(buf, &index, keybindings.formatKeySequence(binding.sequence, &key_buf));
            wrote_any = true;
        }
    }

    if (!wrote_any) append(buf, &index, "-");
    return buf[0..index];
}

pub fn formatCommandDescription(meta: *const commands.CommandMeta, buf: []u8) []const u8 {
    var index: usize = 0;
    append(buf, &index, meta.canonical_name);
    append(buf, &index, " - ");
    append(buf, &index, meta.short_description);
    if (meta.long_description) |long| {
        append(buf, &index, "; ");
        append(buf, &index, long);
    }
    return buf[0..index];
}

test "help registry has rows and includes help command" {
    const registry = keybindings.defaultRegistry();
    try std.testing.expect(registryTotalRows(&registry) > 0);

    var found = false;
    for (0..registryTotalRows(&registry)) |i| {
        switch (registryRowAt(&registry, i).?) {
            .command => |command| {
                if (command.meta.id == .help_open) found = true;
            },
            .category => {},
        }
    }
    try std.testing.expect(found);
}

test "help registry starts with modes category" {
    const registry = keybindings.defaultRegistry();
    const first = registryRowAt(&registry, 0) orelse return error.ExpectedRow;
    try std.testing.expectEqual(commands.CommandCategory.mode, first.category);
}

test "help command key formatting includes defaults aliases and unbound commands" {
    const registry = keybindings.defaultRegistry();

    var keys_buf: [256]u8 = undefined;
    const goto_start = commands.metadata(.navigation_goto_file_start);
    try std.testing.expectEqualStrings("normal: gg", formatCommandKeys(goto_start, &registry, &keys_buf));

    const quit_all = commands.metadata(.app_quit_all);
    const quit_keys = formatCommandKeys(quit_all, &registry, &keys_buf);
    try std.testing.expect(std.mem.indexOf(u8, quit_keys, ":qall") != null);
    try std.testing.expect(std.mem.indexOf(u8, quit_keys, ":qa") != null);

    const write_all = commands.metadata(.file_write_all);
    const write_all_keys = formatCommandKeys(write_all, &registry, &keys_buf);
    try std.testing.expect(std.mem.indexOf(u8, write_all_keys, ":wall") != null);
    try std.testing.expect(std.mem.indexOf(u8, write_all_keys, ":wa") != null);

    const settings = commands.metadata(.dashboard_settings);
    try std.testing.expectEqualStrings("dashboard: ctrl+p", formatCommandKeys(settings, &registry, &keys_buf));
}

test "help reflects override and unbinds from resolved registry" {
    var diagnostics = keybindings.BuildDiagnostics{};
    defer diagnostics.deinit(std.testing.allocator);
    const overrides = [_]keybindings.UserBindingOverride{.{
        .context = .normal,
        .sequence = keybindings.keyChar('x'),
        .command = .navigation_goto_file_start,
        .source_key = "x",
        .source_command = "navigation.goto_file_start",
        .replace_default_sequence = keybindings.charSeq("gg"),
    }};
    const unbinds = [_]keybindings.UserUnbind{.{
        .context = .normal,
        .sequence = keybindings.keyChar('G'),
        .source_key = "G",
    }};
    var registry = try keybindings.Registry.fromDefaultsAndConfig(std.testing.allocator, &overrides, &unbinds, &diagnostics);
    defer registry.deinit(std.testing.allocator);

    var keys_buf: [256]u8 = undefined;
    const goto_start = formatCommandKeys(commands.metadata(.navigation_goto_file_start), &registry, &keys_buf);
    try std.testing.expect(std.mem.indexOf(u8, goto_start, "normal: x") != null);
    try std.testing.expect(std.mem.indexOf(u8, goto_start, "normal: gg") == null);

    const goto_end = formatCommandKeys(commands.metadata(.navigation_goto_file_end), &registry, &keys_buf);
    try std.testing.expectEqualStrings("-", goto_end);
}

test "help rows are deterministic" {
    const registry = keybindings.defaultRegistry();
    const total = registryTotalRows(&registry);
    try std.testing.expect(total == registryTotalRows(&registry));

    for (0..total) |i| {
        const left = registryRowAt(&registry, i).?;
        const right = registryRowAt(&registry, i).?;
        try std.testing.expect(std.meta.activeTag(left) == std.meta.activeTag(right));
        switch (left) {
            .category => |category| try std.testing.expectEqual(category, right.category),
            .command => |command| try std.testing.expectEqual(command.meta.id, right.command.meta.id),
        }
    }
}

test "help popup scroll clamps" {
    const registry = keybindings.defaultRegistry();
    var popup = HelpPopup{};
    popup.open();
    popup.scrollDown(&registry, 1000, 8);
    try std.testing.expect(popup.scroll_offset <= popup.totalRows(&registry) - 8);
    popup.scrollUp(1000);
    try std.testing.expectEqual(@as(usize, 0), popup.scroll_offset);
    popup.scrollDown(&registry, 5, 1000);
    try std.testing.expectEqual(@as(usize, 0), popup.scroll_offset);
}
