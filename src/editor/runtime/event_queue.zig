const std = @import("std");
const syntax = @import("../syntax.zig");
const git_status = @import("../git_status.zig");
const git_diff = @import("../git/diff_service.zig");
const task_mod = @import("../tasks/task.zig");
const agent_mod = @import("../agent/session.zig");

pub const QueueError = error{
    QueueClosed,
};

pub const Event = union(enum) {
    /// LSP messages are non-coalescible and are delivered FIFO.
    lsp_message: struct {
        /// Owned plugin/client name.
        plugin_name: []u8,
        /// Owned JSON payload. Whoever consumes or discards this event must free it.
        message: []u8,
    },

    /// Owned parse result. Pushing this event transfers ownership to the queue
    /// unless push returns an error, in which case the caller still owns it.
    syntax_parse_result: syntax.ParseResult,

    /// Owned git status snapshot. Whoever consumes or discards this event must deinit it.
    git_status_snapshot: git_status.Snapshot,

    /// Owned git diff refresh result. Whoever consumes or discards this event must deinit it.
    git_diff_result: git_diff.RefreshResult,

    /// Owned PTY output bytes. Whoever consumes or discards this event must free them.
    terminal_output: struct {
        bytes: []u8,
    },

    terminal_exit: struct {
        code: ?i32,
    },

    task_started: struct {
        id: u64,
        started_at_ms: i64,
    },

    /// Owned task output bytes. Whoever consumes or discards this event must free them.
    task_output: struct {
        id: u64,
        kind: task_mod.TaskOutputKind,
        bytes: []u8,
    },

    task_finished: struct {
        id: u64,
        status: task_mod.TaskStatus,
        exit_code: ?i32,
        finished_at_ms: i64,
    },

    /// Owned failure message. Whoever consumes or discards this event must free it.
    task_failed_to_start: struct {
        id: u64,
        message: []u8,
        finished_at_ms: i64,
    },

    /// Owned agent event text. Whoever consumes or discards this event must free it.
    agent_event: struct {
        id: u64,
        kind: agent_mod.AgentEventKind,
        text: []u8,
        timestamp_ms: i64,
    },

    agent_session_finished: struct {
        id: u64,
        status: agent_mod.AgentSessionStatus,
        finished_at_ms: i64,
    },
};

pub const EventQueue = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex,
    cond: std.Io.Condition,
    fifo: RingBuffer = .{},
    latest_syntax_results: std.AutoHashMap(u64, syntax.ParseResult),
    closed: bool = false,
    stats: Stats = .{},

    pub const Stats = struct {
        fifo_events_queued: usize = 0,
        syntax_results_coalesced: usize = 0,
        syntax_results_drained: usize = 0,
        fifo_events_processed: usize = 0,
        max_fifo_depth: usize = 0,
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io) EventQueue {
        return .{
            .allocator = allocator,
            .io = io,
            .mutex = .init,
            .cond = .init,
            .latest_syntax_results = std.AutoHashMap(u64, syntax.ParseResult).init(allocator),
        };
    }

    /// Lifecycle:
    /// - producers may call push until close/shutdown is called;
    /// - close wakes blocking consumers and makes future push calls fail with
    ///   error.QueueClosed, leaving ownership with the caller;
    /// - deinit should run only after producer threads have stopped, and it
    ///   frees any queued FIFO events or coalesced syntax results still owned
    ///   by the queue.
    pub fn deinit(self: *EventQueue) void {
        self.close();

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        while (self.fifo.pop()) |ev| {
            var owned = ev;
            self.deinitEvent(&owned);
        }
        self.fifo.deinit(self.allocator);

        var it = self.latest_syntax_results.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.latest_syntax_results.deinit();
    }

    pub fn push(self: *EventQueue, event: Event) !void {
        switch (event) {
            .lsp_message,
            .git_status_snapshot,
            .git_diff_result,
            .terminal_output,
            .terminal_exit,
            .task_started,
            .task_output,
            .task_finished,
            .task_failed_to_start,
            .agent_event,
            .agent_session_finished,
            => try self.pushFifo(event),
            .syntax_parse_result => |result| try self.pushSyntaxResult(result),
        }
    }

    fn pushFifo(self: *EventQueue, event: Event) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        if (self.closed) return QueueError.QueueClosed;

        try self.fifo.push(self.allocator, event);
        self.stats.fifo_events_queued += 1;
        self.stats.max_fifo_depth = @max(self.stats.max_fifo_depth, self.fifo.len);
        self.cond.signal(self.io);
    }

    fn pushSyntaxResult(self: *EventQueue, result: syntax.ParseResult) !void {
        var old: ?syntax.ParseResult = null;

        try self.mutex.lock(self.io);
        if (self.closed) {
            self.mutex.unlock(self.io);
            return QueueError.QueueClosed;
        }

        const entry = self.latest_syntax_results.getOrPut(result.buffer_id) catch |err| {
            self.mutex.unlock(self.io);
            return err;
        };
        if (entry.found_existing) {
            old = entry.value_ptr.*;
            self.stats.syntax_results_coalesced += 1;
        }
        entry.value_ptr.* = result;
        self.cond.signal(self.io);
        self.mutex.unlock(self.io);

        if (old) |*owned| {
            owned.deinit(self.allocator);
        }
    }

    /// Non-blocking pop. Returns null if empty.
    pub fn tryPop(self: *EventQueue) ?Event {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const event = self.fifo.pop() orelse return null;
        self.stats.fifo_events_processed += 1;
        return event;
    }

    /// Blocking pop for FIFO events. Returns null once the queue is closed and
    /// all FIFO events have been drained.
    pub fn pop(self: *EventQueue) ?Event {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        while (self.fifo.len == 0 and !self.closed) {
            self.cond.waitUncancelable(self.io, &self.mutex);
        }

        const event = self.fifo.pop() orelse return null;
        self.stats.fifo_events_processed += 1;
        return event;
    }

    /// Moves the latest pending syntax result for each buffer into `out`.
    /// The caller owns the returned ParseResults and must install or deinit
    /// them. No editor state should be touched while the queue lock is held.
    pub fn drainSyntaxResults(self: *EventQueue, out: *std.ArrayList(syntax.ParseResult)) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const count = self.latest_syntax_results.count();
        if (count == 0) return;

        try out.ensureUnusedCapacity(self.allocator, count);
        var it = self.latest_syntax_results.iterator();
        while (it.next()) |entry| {
            out.appendAssumeCapacity(entry.value_ptr.*);
        }
        self.stats.syntax_results_drained += count;
        self.latest_syntax_results.clearRetainingCapacity();
    }

    pub fn close(self: *EventQueue) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.closed) return;
        self.closed = true;
        self.cond.broadcast(self.io);
    }

    pub fn isClosed(self: *EventQueue) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.closed;
    }

    pub fn fifoLen(self: *EventQueue) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.fifo.len;
    }

    pub fn pendingSyntaxCount(self: *EventQueue) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.latest_syntax_results.count();
    }

    pub fn snapshotStats(self: *EventQueue) Stats {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.stats;
    }

    fn deinitEvent(self: *EventQueue, ev: *Event) void {
        switch (ev.*) {
            .lsp_message => |msg| {
                self.allocator.free(msg.plugin_name);
                self.allocator.free(msg.message);
            },
            .syntax_parse_result => |*result| {
                result.deinit(self.allocator);
            },
            .git_status_snapshot => |*snapshot| {
                snapshot.deinit();
            },
            .git_diff_result => |*result| {
                result.deinit(self.allocator);
            },
            .terminal_output => |output| {
                self.allocator.free(output.bytes);
            },
            .terminal_exit => {},
            .task_started => {},
            .task_output => |output| {
                self.allocator.free(output.bytes);
            },
            .task_finished => {},
            .task_failed_to_start => |failure| {
                self.allocator.free(failure.message);
            },
            .agent_event => |event| {
                self.allocator.free(event.text);
            },
            .agent_session_finished => {},
        }
    }
};

const RingBuffer = struct {
    storage: []Event = &.{},
    head: usize = 0,
    len: usize = 0,

    fn deinit(self: *RingBuffer, allocator: std.mem.Allocator) void {
        if (self.storage.len > 0) {
            allocator.free(self.storage);
        }
        self.* = .{};
    }

    fn push(self: *RingBuffer, allocator: std.mem.Allocator, event: Event) !void {
        if (self.len == self.storage.len) {
            try self.grow(allocator);
        }

        const index = (self.head + self.len) % self.storage.len;
        self.storage[index] = event;
        self.len += 1;
    }

    fn pop(self: *RingBuffer) ?Event {
        if (self.len == 0) return null;

        const event = self.storage[self.head];
        self.head = (self.head + 1) % self.storage.len;
        self.len -= 1;
        if (self.len == 0) self.head = 0;
        return event;
    }

    fn grow(self: *RingBuffer, allocator: std.mem.Allocator) !void {
        const old_capacity = self.storage.len;
        const new_capacity = if (old_capacity == 0) 8 else old_capacity * 2;
        const new_storage = try allocator.alloc(Event, new_capacity);

        for (0..self.len) |i| {
            new_storage[i] = self.storage[(self.head + i) % old_capacity];
        }

        if (old_capacity > 0) {
            allocator.free(self.storage);
        }
        self.storage = new_storage;
        self.head = 0;
    }
};

fn makeTestResult(allocator: std.mem.Allocator, buffer_id: u64, revision: u64) !syntax.ParseResult {
    const source = try std.fmt.allocPrint(allocator, "buffer {d} revision {d}", .{ buffer_id, revision });
    return .{
        .buffer_id = buffer_id,
        .revision = revision,
        .language = .zig,
        .source = source,
        .tree = null,
    };
}

fn makeTestLspEvent(allocator: std.mem.Allocator, message: []const u8) !Event {
    const plugin_name = try allocator.dupe(u8, "zig");
    errdefer allocator.free(plugin_name);

    return .{ .lsp_message = .{
        .plugin_name = plugin_name,
        .message = try allocator.dupe(u8, message),
    } };
}

test "EventQueue preserves FIFO order for LSP messages" {
    const allocator = std.testing.allocator;
    var queue = EventQueue.init(allocator, std.testing.io);
    defer queue.deinit();

    try queue.push(try makeTestLspEvent(allocator, "one"));
    try queue.push(try makeTestLspEvent(allocator, "two"));
    try queue.push(try makeTestLspEvent(allocator, "three"));

    var first = queue.tryPop().?;
    defer queue.deinitEvent(&first);
    try std.testing.expectEqualStrings("one", first.lsp_message.message);

    var second = queue.tryPop().?;
    defer queue.deinitEvent(&second);
    try std.testing.expectEqualStrings("two", second.lsp_message.message);

    var third = queue.tryPop().?;
    defer queue.deinitEvent(&third);
    try std.testing.expectEqualStrings("three", third.lsp_message.message);

    try std.testing.expect(queue.tryPop() == null);
}

test "EventQueue ring buffer pops without shifting remaining events" {
    const allocator = std.testing.allocator;
    var queue = EventQueue.init(allocator, std.testing.io);
    defer queue.deinit();

    for (0..10) |i| {
        const message = try std.fmt.allocPrint(allocator, "{d}", .{i});
        try queue.push(.{ .lsp_message = .{ .plugin_name = try allocator.dupe(u8, "zig"), .message = message } });
    }

    for (0..5) |i| {
        var event = queue.tryPop().?;
        defer queue.deinitEvent(&event);
        const expected = try std.fmt.allocPrint(allocator, "{d}", .{i});
        defer allocator.free(expected);
        try std.testing.expectEqualStrings(expected, event.lsp_message.message);
    }

    for (10..16) |i| {
        const message = try std.fmt.allocPrint(allocator, "{d}", .{i});
        try queue.push(.{ .lsp_message = .{ .plugin_name = try allocator.dupe(u8, "zig"), .message = message } });
    }

    for (5..16) |i| {
        var event = queue.tryPop().?;
        defer queue.deinitEvent(&event);
        const expected = try std.fmt.allocPrint(allocator, "{d}", .{i});
        defer allocator.free(expected);
        try std.testing.expectEqualStrings(expected, event.lsp_message.message);
    }
}

test "EventQueue coalesces syntax results by buffer id" {
    const allocator = std.testing.allocator;
    var queue = EventQueue.init(allocator, std.testing.io);
    defer queue.deinit();

    try queue.push(.{ .syntax_parse_result = try makeTestResult(allocator, 1, 1) });
    try queue.push(.{ .syntax_parse_result = try makeTestResult(allocator, 1, 2) });
    try queue.push(.{ .syntax_parse_result = try makeTestResult(allocator, 2, 1) });

    try std.testing.expectEqual(@as(usize, 0), queue.fifoLen());
    try std.testing.expectEqual(@as(usize, 2), queue.pendingSyntaxCount());

    var results = std.ArrayList(syntax.ParseResult).empty;
    defer results.deinit(allocator);
    try queue.drainSyntaxResults(&results);
    defer for (results.items) |*result| result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), results.items.len);
    var saw_buffer_1_latest = false;
    var saw_buffer_2 = false;
    for (results.items) |result| {
        if (result.buffer_id == 1 and result.revision == 2) saw_buffer_1_latest = true;
        if (result.buffer_id == 2 and result.revision == 1) saw_buffer_2 = true;
        try std.testing.expect(result.buffer_id != 1 or result.revision != 1);
    }
    try std.testing.expect(saw_buffer_1_latest);
    try std.testing.expect(saw_buffer_2);

    const stats = queue.snapshotStats();
    try std.testing.expectEqual(@as(usize, 1), stats.syntax_results_coalesced);
}

test "EventQueue close wakes waiters and rejects later pushes" {
    const allocator = std.testing.allocator;
    var queue = EventQueue.init(allocator, std.testing.io);
    defer queue.deinit();

    const thread = try std.Thread.spawn(.{}, struct {
        fn run(q: *EventQueue) void {
            const event = q.pop();
            std.testing.expect(event == null) catch unreachable;
        }
    }.run, .{&queue});

    queue.close();
    thread.join();

    var late_event = try makeTestLspEvent(allocator, "late");
    errdefer queue.deinitEvent(&late_event);
    try std.testing.expectError(QueueError.QueueClosed, queue.push(late_event));
    queue.deinitEvent(&late_event);
}

test "EventQueue deinit frees queued and coalesced events" {
    const allocator = std.testing.allocator;
    var queue = EventQueue.init(allocator, std.testing.io);

    try queue.push(try makeTestLspEvent(allocator, "queued"));
    try queue.push(.{ .syntax_parse_result = try makeTestResult(allocator, 1, 1) });
    try queue.push(.{ .syntax_parse_result = try makeTestResult(allocator, 1, 2) });

    queue.deinit();
}

test "stale syntax result helper discards old revisions" {
    const current_revision: u64 = 3;
    const result = try makeTestResult(std.testing.allocator, 1, 2);
    var owned = result;
    defer owned.deinit(std.testing.allocator);

    try std.testing.expect(owned.revision != current_revision);
}
