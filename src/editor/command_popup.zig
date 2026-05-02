const std = @import("std");
const cmd = @import("command.zig");

pub const CommandSuggestion = struct {
    command: cmd.Command,

    pub fn name(self: CommandSuggestion) []const u8 {
        return self.command.name();
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
        const prefix = self.commandPrefix();
        if (prefix.len == 0) {
            self.selected_index = null;
            return;
        }

        for (cmd.all) |command| {
            if (std.mem.startsWith(u8, command.name(), prefix)) {
                try self.suggestions.append(allocator, .{ .command = command });
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

test "CommandPopup prefix suggestions" {
    const allocator = std.testing.allocator;
    var popup = CommandPopup{};
    defer popup.deinit(allocator);

    try popup.open(allocator);
    try popup.appendChar(allocator, 'w');

    try std.testing.expectEqual(@as(usize, 2), popup.suggestions.items.len);
    try std.testing.expectEqual(cmd.Command.write, popup.suggestions.items[0].command);
    try std.testing.expectEqual(cmd.Command.write_quit, popup.suggestions.items[1].command);
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
    try std.testing.expectEqual(@as(usize, 2), popup.suggestions.items.len);
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
