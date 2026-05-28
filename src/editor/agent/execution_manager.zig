const std = @import("std");
const execution = @import("execution.zig");
const task_mod = @import("../tasks/task.zig");

pub const ExecutionError = error{
    ExecutionNotFound,
    ExecutionNotActive,
    ExecutionAlreadyActive,
    ExecutionNotValidating,
    TaskNotFound,
} || std.mem.Allocator.Error;

pub const AgentExecutionManager = struct {
    allocator: std.mem.Allocator,
    executions: std.ArrayListUnmanaged(execution.AgentExecution) = .empty,
    next_id: u64 = 1,
    active_execution_id: ?u64 = null,

    pub fn init(allocator: std.mem.Allocator) AgentExecutionManager {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *AgentExecutionManager) void {
        for (self.executions.items) |*item| item.deinit(self.allocator);
        self.executions.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn createForProposal(self: *AgentExecutionManager, session_id: u64, proposal_id: u64, now_ms: i64) ExecutionError!u64 {
        if (self.activeExecution()) |active| {
            if (!active.status.isTerminal()) return error.ExecutionAlreadyActive;
        }

        const id = self.next_id;
        self.next_id +%= 1;
        try self.executions.append(self.allocator, .{
            .id = id,
            .session_id = session_id,
            .proposal_id = proposal_id,
            .status = .waiting_for_approval,
            .started_at_ms = now_ms,
        });
        self.active_execution_id = id;
        return id;
    }

    pub fn getExecution(self: *AgentExecutionManager, id: u64) ?*execution.AgentExecution {
        for (self.executions.items) |*item| {
            if (item.id == id) return item;
        }
        return null;
    }

    pub fn getExecutionConst(self: *const AgentExecutionManager, id: u64) ?*const execution.AgentExecution {
        for (self.executions.items) |*item| {
            if (item.id == id) return item;
        }
        return null;
    }

    pub fn activeExecution(self: *AgentExecutionManager) ?*execution.AgentExecution {
        const id = self.active_execution_id orelse return null;
        return self.getExecution(id);
    }

    pub fn activeExecutionConst(self: *const AgentExecutionManager) ?*const execution.AgentExecution {
        const id = self.active_execution_id orelse return null;
        return self.getExecutionConst(id);
    }

    pub fn latestBySessionConst(self: *const AgentExecutionManager, session_id: u64) ?*const execution.AgentExecution {
        var index = self.executions.items.len;
        while (index > 0) {
            index -= 1;
            if (self.executions.items[index].session_id == session_id) return &self.executions.items[index];
        }
        return null;
    }

    pub fn latestByProposalConst(self: *const AgentExecutionManager, proposal_id: u64) ?*const execution.AgentExecution {
        var index = self.executions.items.len;
        while (index > 0) {
            index -= 1;
            if (self.executions.items[index].proposal_id == proposal_id) return &self.executions.items[index];
        }
        return null;
    }

    pub fn executionByTask(self: *AgentExecutionManager, task_id: u64) ?*execution.AgentExecution {
        for (self.executions.items) |*item| {
            for (item.validation_tasks.items) |record| {
                if (record.task_id == task_id) return item;
            }
        }
        return null;
    }

    pub fn markApplying(self: *AgentExecutionManager, id: u64, now_ms: i64) ExecutionError!void {
        const item = self.getExecution(id) orelse return error.ExecutionNotFound;
        if (item.status != .waiting_for_approval) return error.ExecutionNotActive;
        item.status = .applying;
        item.started_at_ms = now_ms;
    }

    pub fn markValidating(self: *AgentExecutionManager, id: u64) ExecutionError!void {
        const item = self.getExecution(id) orelse return error.ExecutionNotFound;
        if (item.status != .applying and item.status != .validating) return error.ExecutionNotActive;
        item.status = .validating;
    }

    pub fn addValidationTask(self: *AgentExecutionManager, id: u64, task_id: u64, command: []const u8) ExecutionError!void {
        const item = self.getExecution(id) orelse return error.ExecutionNotFound;
        if (item.status != .validating) return error.ExecutionNotValidating;
        const owned = try self.allocator.dupe(u8, command);
        errdefer self.allocator.free(owned);
        try item.validation_tasks.append(self.allocator, .{
            .task_id = task_id,
            .command = owned,
        });
        item.next_validation_index = item.validation_tasks.items.len;
    }

    pub fn markTaskStarted(self: *AgentExecutionManager, task_id: u64, started_at_ms: i64) ExecutionError!*execution.AgentExecution {
        const item = self.executionByTask(task_id) orelse return error.TaskNotFound;
        const record = findTaskRecord(item, task_id) orelse return error.TaskNotFound;
        record.status = .running;
        record.started_at_ms = started_at_ms;
        return item;
    }

    pub fn markTaskFinished(
        self: *AgentExecutionManager,
        task_id: u64,
        status: task_mod.TaskStatus,
        exit_code: ?i32,
        finished_at_ms: i64,
    ) ExecutionError!*execution.AgentExecution {
        const item = self.executionByTask(task_id) orelse return error.TaskNotFound;
        const record = findTaskRecord(item, task_id) orelse return error.TaskNotFound;
        record.status = status;
        record.exit_code = exit_code;
        record.finished_at_ms = finished_at_ms;
        return item;
    }

    pub fn requestCancel(self: *AgentExecutionManager, id: u64) ExecutionError!void {
        const item = self.getExecution(id) orelse return error.ExecutionNotFound;
        if (item.status.isTerminal()) return error.ExecutionNotActive;
        item.cancel_requested = true;
    }

    pub fn complete(self: *AgentExecutionManager, id: u64, summary: []const u8, now_ms: i64) ExecutionError!void {
        const item = self.getExecution(id) orelse return error.ExecutionNotFound;
        item.status = .completed;
        item.finished_at_ms = now_ms;
        try item.setSummary(self.allocator, summary);
        if (self.active_execution_id == id) self.active_execution_id = null;
    }

    pub fn fail(self: *AgentExecutionManager, id: u64, message: []const u8, summary: []const u8, now_ms: i64) ExecutionError!void {
        const item = self.getExecution(id) orelse return error.ExecutionNotFound;
        item.status = .failed;
        item.finished_at_ms = now_ms;
        try item.setError(self.allocator, message);
        try item.setSummary(self.allocator, summary);
        if (self.active_execution_id == id) self.active_execution_id = null;
    }

    pub fn cancel(self: *AgentExecutionManager, id: u64, summary: []const u8, now_ms: i64) ExecutionError!void {
        const item = self.getExecution(id) orelse return error.ExecutionNotFound;
        item.status = .cancelled;
        item.finished_at_ms = now_ms;
        item.cancel_requested = true;
        try item.setSummary(self.allocator, summary);
        if (self.active_execution_id == id) self.active_execution_id = null;
    }
};

fn findTaskRecord(item: *execution.AgentExecution, task_id: u64) ?*execution.ValidationTaskRecord {
    for (item.validation_tasks.items) |*record| {
        if (record.task_id == task_id) return record;
    }
    return null;
}

test "execution manager lifecycle success and failure" {
    const allocator = std.testing.allocator;
    var manager = AgentExecutionManager.init(allocator);
    defer manager.deinit();

    const id = try manager.createForProposal(7, 12, 1);
    try manager.markApplying(id, 2);
    try manager.markValidating(id);
    try manager.addValidationTask(id, 3, "zig build test");
    _ = try manager.markTaskStarted(3, 4);
    _ = try manager.markTaskFinished(3, .success, 0, 5);
    try manager.complete(id, "ok", 6);

    try std.testing.expectEqual(execution.AgentExecutionStatus.completed, manager.getExecution(id).?.status);
    try std.testing.expectEqual(@as(?u64, null), manager.active_execution_id);

    const failed = try manager.createForProposal(7, 13, 7);
    try manager.markApplying(failed, 8);
    try manager.fail(failed, "apply failed", "failed", 9);
    try std.testing.expectEqual(execution.AgentExecutionStatus.failed, manager.getExecution(failed).?.status);
}

test "execution manager associates task ids" {
    const allocator = std.testing.allocator;
    var manager = AgentExecutionManager.init(allocator);
    defer manager.deinit();

    const id = try manager.createForProposal(1, 2, 0);
    try manager.markApplying(id, 1);
    try manager.markValidating(id);
    try manager.addValidationTask(id, 44, "zig build");
    const execution_for_task = manager.executionByTask(44).?;
    try std.testing.expectEqual(id, execution_for_task.id);
}

test "execution manager rejects concurrent active execution" {
    const allocator = std.testing.allocator;
    var manager = AgentExecutionManager.init(allocator);
    defer manager.deinit();

    _ = try manager.createForProposal(1, 2, 0);
    try std.testing.expectError(error.ExecutionAlreadyActive, manager.createForProposal(1, 3, 1));
}

test "execution manager records failure and cancellation summaries" {
    const allocator = std.testing.allocator;
    var manager = AgentExecutionManager.init(allocator);
    defer manager.deinit();

    const failed = try manager.createForProposal(1, 2, 0);
    try manager.markApplying(failed, 1);
    try manager.markValidating(failed);
    try manager.addValidationTask(failed, 10, "zig build test");
    _ = try manager.markTaskFinished(10, .failed, 1, 2);
    try manager.fail(failed, "Validation failed", "Patch was applied but validation failed.", 3);
    try std.testing.expectEqual(execution.AgentExecutionStatus.failed, manager.getExecution(failed).?.status);
    try std.testing.expectEqualStrings("Validation failed", manager.getExecution(failed).?.error_message.?);

    const cancelled = try manager.createForProposal(1, 3, 4);
    try manager.markApplying(cancelled, 5);
    try manager.cancel(cancelled, "Execution cancelled.", 6);
    try std.testing.expectEqual(execution.AgentExecutionStatus.cancelled, manager.getExecution(cancelled).?.status);
    try std.testing.expectEqualStrings("Execution cancelled.", manager.getExecution(cancelled).?.summary.?);
}
