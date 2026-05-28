const std = @import("std");

pub const max_output_lines = 10_000;

pub const TaskStatus = enum {
    queued,
    running,
    success,
    failed,
    cancelled,

    pub fn label(self: TaskStatus) []const u8 {
        return switch (self) {
            .queued => "queued",
            .running => "running",
            .success => "success",
            .failed => "failed",
            .cancelled => "cancelled",
        };
    }
};

pub const TaskOutputKind = enum {
    stdout,
    stderr,
    system,

    pub fn label(self: TaskOutputKind) []const u8 {
        return switch (self) {
            .stdout => "stdout",
            .stderr => "stderr",
            .system => "system",
        };
    }
};

pub const TaskOutputLine = struct {
    kind: TaskOutputKind,
    text: []u8,

    pub fn deinit(self: *TaskOutputLine, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        self.* = undefined;
    }
};

pub const Task = struct {
    id: u64,
    name: []u8,
    command_display: []u8,
    argv: [][]u8,
    cwd: []u8,
    status: TaskStatus = .queued,
    exit_code: ?i32 = null,
    started_at_ms: i64,
    finished_at_ms: ?i64 = null,
    output: std.ArrayListUnmanaged(TaskOutputLine) = .empty,
    stdout_partial: std.ArrayListUnmanaged(u8) = .empty,
    stderr_partial: std.ArrayListUnmanaged(u8) = .empty,
    truncated: bool = false,

    pub fn deinit(self: *Task, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.command_display);
        for (self.argv) |arg| allocator.free(arg);
        allocator.free(self.argv);
        allocator.free(self.cwd);
        for (self.output.items) |*line| line.deinit(allocator);
        self.output.deinit(allocator);
        self.stdout_partial.deinit(allocator);
        self.stderr_partial.deinit(allocator);
        self.* = undefined;
    }

    pub fn argvConst(self: *const Task) []const []const u8 {
        return @ptrCast(self.argv);
    }

    pub fn appendSystemLine(self: *Task, allocator: std.mem.Allocator, text: []const u8) !void {
        try self.appendOutputLine(allocator, .system, text);
    }

    pub fn appendOutputChunk(
        self: *Task,
        allocator: std.mem.Allocator,
        kind: TaskOutputKind,
        bytes: []const u8,
    ) !void {
        if (bytes.len == 0) return;
        var partial = switch (kind) {
            .stdout => &self.stdout_partial,
            .stderr => &self.stderr_partial,
            .system => null,
        };
        if (partial == null) {
            try self.appendOutputLine(allocator, kind, bytes);
            return;
        }

        var start: usize = 0;
        for (bytes, 0..) |byte, index| {
            if (byte != '\n') continue;
            try partial.?.appendSlice(allocator, bytes[start..index]);
            try self.appendOutputLine(allocator, kind, trimCarriageReturn(partial.?.items));
            partial.?.clearRetainingCapacity();
            start = index + 1;
        }
        if (start < bytes.len) {
            try partial.?.appendSlice(allocator, bytes[start..]);
        }
    }

    pub fn flushPartialOutput(self: *Task, allocator: std.mem.Allocator) !void {
        if (self.stdout_partial.items.len > 0) {
            try self.appendOutputLine(allocator, .stdout, trimCarriageReturn(self.stdout_partial.items));
            self.stdout_partial.clearRetainingCapacity();
        }
        if (self.stderr_partial.items.len > 0) {
            try self.appendOutputLine(allocator, .stderr, trimCarriageReturn(self.stderr_partial.items));
            self.stderr_partial.clearRetainingCapacity();
        }
    }

    fn appendOutputLine(
        self: *Task,
        allocator: std.mem.Allocator,
        kind: TaskOutputKind,
        text: []const u8,
    ) !void {
        if (self.output.items.len >= max_output_lines) {
            if (!self.truncated) {
                self.truncated = true;
                if (self.output.items.len > 0) {
                    var old = self.output.orderedRemove(0);
                    old.deinit(allocator);
                }
                const marker = try allocator.dupe(u8, "Output truncated after 10000 lines.");
                try self.output.append(allocator, .{ .kind = .system, .text = marker });
            }
            return;
        }
        const owned = try allocator.dupe(u8, text);
        try self.output.append(allocator, .{ .kind = kind, .text = owned });
    }
};

fn trimCarriageReturn(text: []const u8) []const u8 {
    if (text.len > 0 and text[text.len - 1] == '\r') return text[0 .. text.len - 1];
    return text;
}

pub fn nowMs(io: std.Io) i64 {
    return @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_ms));
}

test "task output line cap adds a single marker" {
    const allocator = std.testing.allocator;
    var task = Task{
        .id = 1,
        .name = try allocator.dupe(u8, "cmd"),
        .command_display = try allocator.dupe(u8, "cmd"),
        .argv = try allocator.alloc([]u8, 0),
        .cwd = try allocator.dupe(u8, "."),
        .started_at_ms = 0,
    };
    defer task.deinit(allocator);

    for (0..max_output_lines + 2) |_| {
        try task.appendOutputChunk(allocator, .stdout, "x\n");
    }
    try std.testing.expectEqual(@as(usize, max_output_lines), task.output.items.len);
    try std.testing.expect(task.truncated);
    try std.testing.expectEqual(TaskOutputKind.system, task.output.items[task.output.items.len - 1].kind);
}
