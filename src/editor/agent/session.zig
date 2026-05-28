const std = @import("std");

pub const max_agent_events = 10_000;

pub const AgentMode = enum {
    plan,
    implementation,

    pub fn label(self: AgentMode) []const u8 {
        return switch (self) {
            .plan => "Plan",
            .implementation => "Implementation",
        };
    }

    pub fn toggle(self: AgentMode) AgentMode {
        return switch (self) {
            .plan => .implementation,
            .implementation => .plan,
        };
    }
};

pub const AgentSessionStatus = enum {
    idle,
    running,
    completed,
    failed,
    cancelled,

    pub fn label(self: AgentSessionStatus) []const u8 {
        return switch (self) {
            .idle => "idle",
            .running => "running",
            .completed => "completed",
            .failed => "failed",
            .cancelled => "cancelled",
        };
    }
};

pub const AgentEventKind = enum {
    user_prompt,
    assistant_message,
    status,
    tool_call,
    tool_result,
    final_plan,
    task_started,
    task_finished,
    diff_available,
    proposal_created,
    proposal_approved,
    proposal_rejected,
    proposal_applying,
    proposal_applied,
    proposal_failed,
    execution_started,
    execution_applying,
    execution_validating,
    execution_validation_task_started,
    execution_validation_task_finished,
    execution_completed,
    execution_failed,
    execution_cancelled,
    agent_error,

    pub fn label(self: AgentEventKind) []const u8 {
        return switch (self) {
            .user_prompt => "You",
            .assistant_message => "Agent",
            .status => "Status",
            .tool_call => "Tool",
            .tool_result => "Result",
            .final_plan => "Plan",
            .task_started => "Task",
            .task_finished => "Task",
            .diff_available => "Diff",
            .proposal_created => "Proposal",
            .proposal_approved => "Proposal",
            .proposal_rejected => "Proposal",
            .proposal_applying => "Proposal",
            .proposal_applied => "Proposal",
            .proposal_failed => "Proposal",
            .execution_started => "Execution",
            .execution_applying => "Execution",
            .execution_validating => "Execution",
            .execution_validation_task_started => "Validation",
            .execution_validation_task_finished => "Validation",
            .execution_completed => "Execution",
            .execution_failed => "Execution",
            .execution_cancelled => "Execution",
            .agent_error => "Error",
        };
    }
};

pub const AgentEvent = struct {
    kind: AgentEventKind,
    text: []u8,
    timestamp_ms: i64,

    pub fn deinit(self: *AgentEvent, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        self.* = undefined;
    }
};

pub const AgentSession = struct {
    id: u64,
    mode: AgentMode,
    status: AgentSessionStatus,
    prompt: []u8,
    started_at_ms: i64,
    finished_at_ms: ?i64 = null,
    events: std.ArrayListUnmanaged(AgentEvent) = .empty,
    truncated: bool = false,

    pub fn deinit(self: *AgentSession, allocator: std.mem.Allocator) void {
        allocator.free(self.prompt);
        for (self.events.items) |*event| event.deinit(allocator);
        self.events.deinit(allocator);
        self.* = undefined;
    }

    pub fn appendEvent(
        self: *AgentSession,
        allocator: std.mem.Allocator,
        kind: AgentEventKind,
        text: []const u8,
        timestamp_ms: i64,
    ) !void {
        if (self.events.items.len >= max_agent_events) {
            if (!self.truncated) {
                self.truncated = true;
                if (self.events.items.len > 0) {
                    var old = self.events.orderedRemove(0);
                    old.deinit(allocator);
                }
                const marker = try allocator.dupe(u8, "Agent event log truncated after 10000 events.");
                try self.events.append(allocator, .{
                    .kind = .status,
                    .text = marker,
                    .timestamp_ms = timestamp_ms,
                });
            }
            return;
        }
        const owned = try allocator.dupe(u8, text);
        try self.events.append(allocator, .{
            .kind = kind,
            .text = owned,
            .timestamp_ms = timestamp_ms,
        });
    }
};

pub fn nowMs(io: std.Io) i64 {
    return @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_ms));
}

test "agent session appends events in order" {
    const allocator = std.testing.allocator;
    var session = AgentSession{
        .id = 1,
        .mode = .plan,
        .status = .running,
        .prompt = try allocator.dupe(u8, "make a plan"),
        .started_at_ms = 0,
    };
    defer session.deinit(allocator);

    try session.appendEvent(allocator, .status, "one", 1);
    try session.appendEvent(allocator, .assistant_message, "two", 2);

    try std.testing.expectEqual(@as(usize, 2), session.events.items.len);
    try std.testing.expectEqual(AgentEventKind.status, session.events.items[0].kind);
    try std.testing.expectEqualStrings("one", session.events.items[0].text);
    try std.testing.expectEqualStrings("two", session.events.items[1].text);
}

test "agent event cap adds marker once" {
    const allocator = std.testing.allocator;
    var session = AgentSession{
        .id = 1,
        .mode = .plan,
        .status = .running,
        .prompt = try allocator.dupe(u8, "prompt"),
        .started_at_ms = 0,
    };
    defer session.deinit(allocator);

    for (0..max_agent_events + 2) |_| {
        try session.appendEvent(allocator, .status, "event", 1);
    }

    try std.testing.expectEqual(@as(usize, max_agent_events), session.events.items.len);
    try std.testing.expect(session.truncated);
    try std.testing.expectEqual(AgentEventKind.status, session.events.items[session.events.items.len - 1].kind);
}
