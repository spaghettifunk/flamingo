const std = @import("std");

pub const PromptKind = enum {
    explorer_new_file,
    explorer_rename,
    explorer_delete_confirm,
};

pub const PromptPopup = struct {
    visible: bool = false,
    kind: PromptKind = .explorer_new_file,
    title: []const u8 = "",
    context_path: []u8 = &.{},
    input: std.ArrayListUnmanaged(u8) = .empty,
    error_message: ?[]const u8 = null,

    pub fn deinit(self: *PromptPopup, allocator: std.mem.Allocator) void {
        self.input.deinit(allocator);
        if (self.context_path.len > 0) allocator.free(self.context_path);
        self.* = .{};
    }

    pub fn open(
        self: *PromptPopup,
        allocator: std.mem.Allocator,
        kind: PromptKind,
        title: []const u8,
        context_path: []const u8,
        initial_input: []const u8,
    ) !void {
        self.close(allocator);
        const owned_context = try allocator.dupe(u8, context_path);
        errdefer allocator.free(owned_context);
        try self.input.appendSlice(allocator, initial_input);
        self.visible = true;
        self.kind = kind;
        self.title = title;
        self.context_path = owned_context;
    }

    pub fn close(self: *PromptPopup, allocator: std.mem.Allocator) void {
        self.visible = false;
        self.kind = .explorer_new_file;
        self.title = "";
        self.input.clearRetainingCapacity();
        self.error_message = null;
        if (self.context_path.len > 0) {
            allocator.free(self.context_path);
            self.context_path = &.{};
        }
    }

    pub fn appendChar(self: *PromptPopup, allocator: std.mem.Allocator, ch: u8) !void {
        if (!self.visible) return;
        try self.input.append(allocator, ch);
        self.error_message = null;
    }

    pub fn backspace(self: *PromptPopup) void {
        if (self.input.items.len > 0) self.input.shrinkRetainingCapacity(self.input.items.len - 1);
        self.error_message = null;
    }
};
