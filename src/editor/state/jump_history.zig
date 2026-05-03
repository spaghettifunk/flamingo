const std = @import("std");

pub const max_jump_history = 128;

pub const JumpLocation = struct {
    buffer_id: u64,
    row: usize,
    col: usize,

    pub fn eql(self: JumpLocation, other: JumpLocation) bool {
        return self.buffer_id == other.buffer_id and
            self.row == other.row and
            self.col == other.col;
    }
};

pub const JumpHistory = struct {
    back_stack: std.ArrayListUnmanaged(JumpLocation) = .empty,
    forward_stack: std.ArrayListUnmanaged(JumpLocation) = .empty,

    pub fn deinit(self: *JumpHistory, allocator: std.mem.Allocator) void {
        self.back_stack.deinit(allocator);
        self.back_stack = .empty;
        self.forward_stack.deinit(allocator);
        self.forward_stack = .empty;
    }

    pub fn recordJump(self: *JumpHistory, allocator: std.mem.Allocator, from: JumpLocation) !void {
        self.forward_stack.clearRetainingCapacity();
        try self.pushBack(allocator, from);
    }

    pub fn popBack(self: *JumpHistory) ?JumpLocation {
        return self.back_stack.pop();
    }

    pub fn popForward(self: *JumpHistory) ?JumpLocation {
        return self.forward_stack.pop();
    }

    pub fn pushBack(self: *JumpHistory, allocator: std.mem.Allocator, location: JumpLocation) !void {
        try pushBounded(allocator, &self.back_stack, location);
    }

    pub fn pushForward(self: *JumpHistory, allocator: std.mem.Allocator, location: JumpLocation) !void {
        try pushBounded(allocator, &self.forward_stack, location);
    }
};

fn pushBounded(
    allocator: std.mem.Allocator,
    stack: *std.ArrayListUnmanaged(JumpLocation),
    location: JumpLocation,
) !void {
    if (stack.items.len > 0 and stack.items[stack.items.len - 1].eql(location)) return;
    try stack.append(allocator, location);
    if (stack.items.len > max_jump_history) {
        _ = stack.orderedRemove(0);
    }
}
