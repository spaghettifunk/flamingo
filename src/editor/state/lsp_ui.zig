const std = @import("std");

pub const LspUiState = struct {
    allocator: std.mem.Allocator,
    completion_items: ?std.json.Value = null,
    completion_active: bool = false,
    completion_selected: usize = 0,
    diagnostics: std.StringHashMap(std.json.Value),

    pub fn init(allocator: std.mem.Allocator) LspUiState {
        return .{
            .allocator = allocator,
            .diagnostics = std.StringHashMap(std.json.Value).init(allocator),
        };
    }

    pub fn deinit(self: *LspUiState) void {
        self.clearCompletion();

        var it = self.diagnostics.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            freeJsonValue(self.allocator, entry.value_ptr.*);
        }
        self.diagnostics.deinit();
        self.* = init(self.allocator);
    }

    pub fn replaceCompletion(self: *LspUiState, items: std.json.Value) void {
        self.clearCompletion();
        self.completion_items = items;
        self.completion_active = true;
        self.completion_selected = 0;
    }

    pub fn clearCompletion(self: *LspUiState) void {
        if (self.completion_items) |items| {
            freeJsonValue(self.allocator, items);
            self.completion_items = null;
        }
        self.completion_active = false;
        self.completion_selected = 0;
    }

    pub fn replaceDiagnostics(self: *LspUiState, filename: []const u8, value: std.json.Value) !void {
        const fname_copy = try self.allocator.dupe(u8, filename);
        var key_owned = true;
        errdefer if (key_owned) self.allocator.free(fname_copy);

        const entry = try self.diagnostics.getOrPut(fname_copy);
        if (entry.found_existing) {
            freeJsonValue(self.allocator, entry.value_ptr.*);
            self.allocator.free(fname_copy);
            key_owned = false;
        } else {
            key_owned = false;
        }

        entry.value_ptr.* = value;
    }

    pub fn diagnosticCountForFile(self: *const LspUiState, filename: []const u8) usize {
        const value = self.diagnostics.get(filename) orelse return 0;
        if (value != .object) return 0;
        const diagnostics = value.object.get("diagnostics") orelse return 0;
        if (diagnostics != .array) return 0;
        return diagnostics.array.items.len;
    }

    pub fn completionItems(self: *const LspUiState) []std.json.Value {
        const items_val = self.completion_items orelse return &.{};
        if (items_val == .array) return items_val.array.items;
        if (items_val == .object) {
            if (items_val.object.get("items")) |v| {
                if (v == .array) return v.array.items;
            }
        }
        return &.{};
    }
};

fn freeJsonValue(allocator: std.mem.Allocator, v: std.json.Value) void {
    switch (v) {
        .number_string => |s| allocator.free(s),
        .string => |s| allocator.free(s),
        .array => |arr| {
            for (arr.items) |item| {
                freeJsonValue(allocator, item);
            }
            var mutable_arr = arr;
            mutable_arr.deinit();
        },
        .object => |obj| {
            var it = obj.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                freeJsonValue(allocator, entry.value_ptr.*);
            }
            var mutable_obj = obj;
            mutable_obj.deinit(allocator);
        },
        else => {},
    }
}

test "LspUiState replaces completion and diagnostics" {
    const allocator = std.testing.allocator;
    var state = LspUiState.init(allocator);
    defer state.deinit();

    const first = std.json.Value{ .string = try allocator.dupe(u8, "first") };
    state.replaceCompletion(first);
    try std.testing.expect(state.completion_active);

    const second = std.json.Value{ .string = try allocator.dupe(u8, "second") };
    state.replaceCompletion(second);
    try std.testing.expectEqual(@as(usize, 0), state.completion_selected);

    var diagnostics = std.json.Array.init(allocator);
    try diagnostics.append(.null);
    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, try allocator.dupe(u8, "diagnostics"), .{ .array = diagnostics });
    try state.replaceDiagnostics("main.zig", .{ .object = obj });
    try std.testing.expectEqual(@as(usize, 1), state.diagnosticCountForFile("main.zig"));
}
