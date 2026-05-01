const std = @import("std");
const syntax = @import("syntax.zig");

pub const Event = union(enum) {
    lsp_message: struct {
        plugin_name: []const u8,
        message: []const u8, // JSON payload, owned by event
    },
    syntax_parse_result: syntax.ParseResult,
};

pub const EventQueue = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex,
    cond: std.Io.Condition,
    items: std.ArrayList(Event),
    quit: bool = false,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) EventQueue {
        return .{
            .allocator = allocator,
            .io = io,
            .mutex = .init,
            .cond = .init,
            .items = std.ArrayList(Event).empty,
        };
    }

    pub fn deinit(self: *EventQueue) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.items.items) |*ev| {
            self.deinitEvent(ev);
        }
        self.items.deinit(self.allocator);
        self.items = std.ArrayList(Event).empty;
    }

    pub fn push(self: *EventQueue, event: Event) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        if (event == .syntax_parse_result) {
            const buffer_id = event.syntax_parse_result.buffer_id;
            var i: usize = 0;
            while (i < self.items.items.len) {
                if (self.items.items[i] == .syntax_parse_result and
                    self.items.items[i].syntax_parse_result.buffer_id == buffer_id)
                {
                    var old = self.items.orderedRemove(i);
                    self.deinitEvent(&old);
                    continue;
                }
                i += 1;
            }
        }

        try self.items.append(self.allocator, event);
        self.cond.signal(self.io);
    }

    /// Non-blocking pop. Returns null if empty.
    pub fn tryPop(self: *EventQueue) ?Event {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.items.items.len == 0) {
            return null;
        }
        return self.items.orderedRemove(0);
    }

    fn deinitEvent(self: *EventQueue, ev: *Event) void {
        switch (ev.*) {
            .lsp_message => |msg| {
                self.allocator.free(msg.message);
            },
            .syntax_parse_result => |*result| {
                result.deinit(self.allocator);
            },
        }
    }
};
