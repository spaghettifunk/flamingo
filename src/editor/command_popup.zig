const std = @import("std");
const commands = @import("commands.zig");

pub const CommandSuggestion = struct {
    meta: *const commands.CommandMeta,
    command_name: []const u8,
    is_alias: bool = false,

    pub fn name(self: CommandSuggestion) []const u8 {
        return self.command_name;
    }

    pub fn description(self: CommandSuggestion) []const u8 {
        return self.meta.short_description;
    }

    pub fn commandId(self: CommandSuggestion) commands.CommandId {
        return self.meta.id;
    }

    pub fn displayText(self: CommandSuggestion, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "{s:<12} {s}", .{ self.command_name, self.description() }) catch self.command_name;
    }
};

pub const CommandPopup = struct {
    input: std.ArrayListUnmanaged(u8) = .empty,
    suggestions: std.ArrayListUnmanaged(CommandSuggestion) = .empty,
    selected_index: ?usize = null,
    visible: bool = false,

    pub fn deinit(self: *CommandPopup, allocator: std.mem.Allocator) void {
        self.input.deinit(allocator);
        self.input = .empty;
        self.suggestions.deinit(allocator);
        self.suggestions = .empty;
        self.selected_index = null;
        self.visible = false;
    }

    pub fn open(self: *CommandPopup, allocator: std.mem.Allocator) !void {
        self.visible = true;
        self.input.clearRetainingCapacity();
        try self.updateSuggestions(allocator);
    }

    pub fn close(self: *CommandPopup) void {
        self.visible = false;
        self.input.clearRetainingCapacity();
        self.suggestions.clearRetainingCapacity();
        self.selected_index = null;
    }

    pub fn appendChar(self: *CommandPopup, allocator: std.mem.Allocator, ch: u8) !void {
        try self.input.append(allocator, ch);
        try self.updateSuggestions(allocator);
    }

    pub fn backspace(self: *CommandPopup, allocator: std.mem.Allocator) !void {
        if (self.input.items.len > 0) {
            self.input.shrinkRetainingCapacity(self.input.items.len - 1);
        }
        try self.updateSuggestions(allocator);
    }

    pub fn updateSuggestions(self: *CommandPopup, allocator: std.mem.Allocator) !void {
        self.suggestions.clearRetainingCapacity();
        const prefix = commandSearchPrefix(self.commandPrefix());
        if (prefix.len == 0) {
            self.selected_index = null;
            return;
        }

        for (commands.commandPopupVisible()) |*meta| {
            for (meta.command_names) |name| {
                if (std.mem.startsWith(u8, name, prefix)) {
                    try self.suggestions.append(allocator, .{ .meta = meta, .command_name = name });
                }
            }
            for (meta.aliases) |alias| {
                if (std.mem.startsWith(u8, alias, prefix)) {
                    try self.suggestions.append(allocator, .{ .meta = meta, .command_name = alias, .is_alias = true });
                }
            }
        }
        self.selected_index = if (self.suggestions.items.len > 0) 0 else null;
    }

    pub fn selectNext(self: *CommandPopup) void {
        if (self.suggestions.items.len == 0) return;
        const current = self.selected_index orelse 0;
        self.selected_index = (current + 1) % self.suggestions.items.len;
    }

    pub fn selectPrevious(self: *CommandPopup) void {
        if (self.suggestions.items.len == 0) return;
        const current = self.selected_index orelse 0;
        self.selected_index = if (current == 0) self.suggestions.items.len - 1 else current - 1;
    }

    pub fn acceptSelected(self: *CommandPopup, allocator: std.mem.Allocator) !void {
        const index = self.selected_index orelse return;
        if (index >= self.suggestions.items.len) return;
        const suggestion = self.suggestions.items[index].name();
        const suffix_start = self.commandPrefix().len;
        const suffix = self.input.items[suffix_start..];
        var replacement = std.ArrayListUnmanaged(u8).empty;
        errdefer replacement.deinit(allocator);
        try replacement.appendSlice(allocator, suggestion);
        try replacement.appendSlice(allocator, suffix);
        self.input.clearRetainingCapacity();
        try self.input.appendSlice(allocator, replacement.items);
        replacement.deinit(allocator);
        try self.updateSuggestions(allocator);
    }

    pub fn tabComplete(self: *CommandPopup) void {
        self.selectNext();
    }

    fn commandPrefix(self: *const CommandPopup) []const u8 {
        const input = self.input.items;
        const end = std.mem.indexOfScalar(u8, input, ' ') orelse input.len;
        return input[0..end];
    }
};

fn commandSearchPrefix(prefix: []const u8) []const u8 {
    if (prefix.len > 0 and prefix[0] == ':') return prefix[1..];
    return prefix;
}

fn expectSuggestionNames(actual: []const CommandSuggestion, expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, 0..) |name, idx| {
        try std.testing.expectEqualStrings(name, actual[idx].name());
    }
}

test "CommandPopup prefix suggestions" {
    const allocator = std.testing.allocator;
    var popup = CommandPopup{};
    defer popup.deinit(allocator);

    try popup.open(allocator);
    try popup.appendChar(allocator, 'w');

    try expectSuggestionNames(popup.suggestions.items, &.{ "w", "wall", "wa", "wq" });

    popup.close();
    try popup.open(allocator);
    try popup.appendChar(allocator, 's');
    try expectSuggestionNames(popup.suggestions.items, &.{"search"});

    popup.close();
    try popup.open(allocator);
    try popup.appendChar(allocator, 'h');
    try expectSuggestionNames(popup.suggestions.items, &.{"help"});

    popup.close();
    try popup.open(allocator);
    try popup.appendChar(allocator, 'p');
    try expectSuggestionNames(popup.suggestions.items, &.{"proposals"});

    popup.close();
    try popup.open(allocator);
    try popup.appendChar(allocator, 'n');
    try expectSuggestionNames(popup.suggestions.items, &.{ "newFile", "nf" });

    popup.close();
    try popup.open(allocator);
    try popup.appendChar(allocator, 'r');
    try expectSuggestionNames(popup.suggestions.items, &.{ "renameFile", "rf", "run" });

    popup.close();
    try popup.open(allocator);
    try popup.appendChar(allocator, 'd');
    try expectSuggestionNames(popup.suggestions.items, &.{ "deleteFile", "df", "diff-refresh" });
}

test "CommandPopup suggestions include aliases and metadata descriptions" {
    const allocator = std.testing.allocator;
    var popup = CommandPopup{};
    defer popup.deinit(allocator);

    try popup.open(allocator);
    try popup.appendChar(allocator, 'q');
    try expectSuggestionNames(popup.suggestions.items, &.{ "q", "qall", "qa", "q!" });

    const qall = popup.suggestions.items[1];
    try std.testing.expectEqual(commands.CommandId.app_quit_all, qall.commandId());
    try std.testing.expect(!qall.is_alias);
    try std.testing.expectEqualStrings(commands.metadata(.app_quit_all).short_description, qall.description());
    try std.testing.expect(popup.suggestions.items[2].is_alias);

    popup.close();
    try popup.open(allocator);
    try popup.appendChar(allocator, 'q');
    try popup.appendChar(allocator, 'a');
    try expectSuggestionNames(popup.suggestions.items, &.{ "qall", "qa" });

    popup.close();
    try popup.open(allocator);
    try popup.appendChar(allocator, 'n');
    try popup.appendChar(allocator, 'f');
    try expectSuggestionNames(popup.suggestions.items, &.{"nf"});
}

test "CommandPopup suggestions are metadata-backed and hide non-popup commands" {
    const allocator = std.testing.allocator;
    var popup = CommandPopup{};
    defer popup.deinit(allocator);

    try popup.open(allocator);
    try popup.appendChar(allocator, 'g');
    try expectSuggestionNames(popup.suggestions.items, &.{ "gitdiff", "git-graph", "ggraph", "gitdiff-refresh", "git-refresh" });

    popup.close();
    try popup.open(allocator);
    try popup.appendChar(allocator, 'g');
    try popup.appendChar(allocator, 'o');
    try std.testing.expectEqual(@as(usize, 0), popup.suggestions.items.len);
    try std.testing.expect(commands.metadata(.navigation_goto_line).show_in_command_popup == false);

    popup.close();
    try popup.open(allocator);
    try popup.appendChar(allocator, ':');
    try popup.appendChar(allocator, 'h');
    try expectSuggestionNames(popup.suggestions.items, &.{"help"});

    popup.close();
    try popup.open(allocator);
    try popup.appendChar(allocator, 'q');
    try expectSuggestionNames(popup.suggestions.items, &.{ "q", "qall", "qa", "q!" });
}

test "CommandPopup tab moves selection without changing input" {
    const allocator = std.testing.allocator;
    var popup = CommandPopup{};
    defer popup.deinit(allocator);

    try popup.open(allocator);
    try popup.appendChar(allocator, 'w');
    popup.tabComplete();
    try std.testing.expectEqualStrings("w", popup.input.items);
    try std.testing.expectEqual(@as(?usize, 1), popup.selected_index);
    popup.tabComplete();
    try std.testing.expectEqual(@as(?usize, 2), popup.selected_index);
    popup.tabComplete();
    try std.testing.expectEqual(@as(?usize, 3), popup.selected_index);
    popup.tabComplete();
    try std.testing.expectEqual(@as(?usize, 0), popup.selected_index);
    try popup.appendChar(allocator, '!');
    try std.testing.expectEqualStrings("w!", popup.input.items);
}

test "CommandPopup backspace recomputes suggestions" {
    const allocator = std.testing.allocator;
    var popup = CommandPopup{};
    defer popup.deinit(allocator);

    try popup.open(allocator);
    try popup.appendChar(allocator, 'w');
    try popup.appendChar(allocator, 'q');
    try std.testing.expectEqual(@as(usize, 1), popup.suggestions.items.len);

    try popup.backspace(allocator);
    try std.testing.expectEqual(@as(usize, 4), popup.suggestions.items.len);
}

test "CommandPopup accepts canonical and alias suggestions" {
    const allocator = std.testing.allocator;
    var popup = CommandPopup{};
    defer popup.deinit(allocator);

    try popup.open(allocator);
    try popup.appendChar(allocator, 'h');
    try popup.acceptSelected(allocator);
    try std.testing.expectEqualStrings("help", popup.input.items);

    popup.close();
    try popup.open(allocator);
    try popup.appendChar(allocator, 'n');
    popup.selectNext();
    try popup.acceptSelected(allocator);
    try std.testing.expectEqualStrings("nf", popup.input.items);
}

test "CommandPopup close clears state" {
    const allocator = std.testing.allocator;
    var popup = CommandPopup{};
    defer popup.deinit(allocator);

    try popup.open(allocator);
    try popup.appendChar(allocator, 'q');
    popup.close();

    try std.testing.expect(!popup.visible);
    try std.testing.expectEqual(@as(usize, 0), popup.input.items.len);
    try std.testing.expectEqual(@as(usize, 0), popup.suggestions.items.len);
    try std.testing.expect(popup.selected_index == null);
}
