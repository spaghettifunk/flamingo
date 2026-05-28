const std = @import("std");

pub const max_audit_events = 10_000;

pub const AgentAuditEventKind = enum {
    tool_requested,
    tool_allowed,
    tool_denied,
    approval_requested,
    approval_approved,
    approval_denied,
    tool_completed,
    tool_failed,
    policy_violation,
    proposal_created,
    proposal_applied,
    validation_requested,
    validation_completed,
    session_cancelled,

    pub fn label(self: AgentAuditEventKind) []const u8 {
        return switch (self) {
            .tool_requested => "requested",
            .tool_allowed => "allowed",
            .tool_denied => "denied",
            .approval_requested => "approval requested",
            .approval_approved => "approved",
            .approval_denied => "denied",
            .tool_completed => "completed",
            .tool_failed => "failed",
            .policy_violation => "policy violation",
            .proposal_created => "proposal created",
            .proposal_applied => "proposal applied",
            .validation_requested => "validation requested",
            .validation_completed => "validation completed",
            .session_cancelled => "session cancelled",
        };
    }
};

pub const AgentAuditEvent = struct {
    id: u64,
    kind: AgentAuditEventKind,
    message: []u8,
    timestamp_ms: i64,

    pub fn deinit(self: *AgentAuditEvent, allocator: std.mem.Allocator) void {
        allocator.free(self.message);
        self.* = undefined;
    }
};

