const std = @import("std");
const editor = @import("editor.zig");

pub const SearchSystem = struct {
    // TODO: implement search logic
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) SearchSystem {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *SearchSystem) void {
        _ = self;
    }
};
