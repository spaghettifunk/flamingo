const std = @import("std");
const editor = @import("editor.zig");

pub const UndoStack = struct {
    // TODO: implement undo/redo logic
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) UndoStack {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *UndoStack) void {
        _ = self;
    }
};
