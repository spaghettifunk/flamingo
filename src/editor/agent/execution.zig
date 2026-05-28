const std = @import("std");
const task_mod = @import("../tasks/task.zig");

pub const AgentExecutionStatus = enum {
    waiting_for_approval,
    applying,
    validating,
    completed,
    failed,
    cancelled,

    pub fn label(self: AgentExecutionStatus) []const u8 {
        return switch (self) {
            .waiting_for_approval => "waiting",
            .applying => "applying",
            .validating => "validating",
            .completed => "completed",
            .failed => "failed",
            .cancelled => "cancelled",
        };
    }

    pub fn isTerminal(self: AgentExecutionStatus) bool {
        return switch (self) {
            .completed, .failed, .cancelled => true,
            else => false,
        };
    }
};

pub const ValidationTaskRecord = struct {
    task_id: u64,
    command: []u8,
    status: task_mod.TaskStatus = .queued,
    exit_code: ?i32 = null,
    started_at_ms: ?i64 = null,
    finished_at_ms: ?i64 = null,

    pub fn deinit(self: *ValidationTaskRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.command);
        self.* = undefined;
    }
};

pub const AgentExecution = struct {
    id: u64,
    session_id: u64,
    proposal_id: u64,
    status: AgentExecutionStatus,
    started_at_ms: i64,
    finished_at_ms: ?i64 = null,
    validation_tasks: std.ArrayListUnmanaged(ValidationTaskRecord) = .empty,
    next_validation_index: usize = 0,
    summary: ?[]u8 = null,
    error_message: ?[]u8 = null,
    cancel_requested: bool = false,

    pub fn deinit(self: *AgentExecution, allocator: std.mem.Allocator) void {
        for (self.validation_tasks.items) |*record| record.deinit(allocator);
        self.validation_tasks.deinit(allocator);
        if (self.summary) |summary| allocator.free(summary);
        if (self.error_message) |message| allocator.free(message);
        self.* = undefined;
    }

    pub fn setSummary(self: *AgentExecution, allocator: std.mem.Allocator, text: []const u8) !void {
        if (self.summary) |old| allocator.free(old);
        self.summary = try allocator.dupe(u8, text);
    }

    pub fn setError(self: *AgentExecution, allocator: std.mem.Allocator, text: []const u8) !void {
        if (self.error_message) |old| allocator.free(old);
        self.error_message = try allocator.dupe(u8, text);
    }

    pub fn runningTaskId(self: *const AgentExecution) ?u64 {
        for (self.validation_tasks.items) |record| {
            if (record.status == .running or record.status == .queued) return record.task_id;
        }
        return null;
    }
};
