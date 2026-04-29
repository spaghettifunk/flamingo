const std = @import("std");

pub const Event = union(enum) {
    lsp_message: struct {
        plugin_name: []const u8,
        message: []const u8, // JSON payload, owned by event
    },
};

pub const EventQueue = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,
    cond: std.Thread.Condition,
    items: std.ArrayList(Event),
    quit: bool = false,

    pub fn init(allocator: std.mem.Allocator) EventQueue {
        return .{
            .allocator = allocator,
            .mutex = .{},
            .cond = .{},
            .items = std.ArrayList(Event).empty,
        };
    }

    pub fn deinit(self: *EventQueue) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.items.items) |ev| {
            switch (ev) {
                .lsp_message => |msg| {
                    self.allocator.free(msg.message);
                },
            }
        }
        self.items.deinit(self.allocator);
    }

    pub fn push(self: *EventQueue, event: Event) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.items.append(self.allocator, event);
        self.cond.signal();
    }

    /// Non-blocking pop. Returns null if empty.
    pub fn tryPop(self: *EventQueue) ?Event {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.items.items.len == 0) return null;
        return self.items.orderedRemove(0);
    }
};
