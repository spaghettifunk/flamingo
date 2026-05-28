const std = @import("std");
const policy = @import("policy.zig");

pub const AgentApprovalStatus = enum {
    pending,
    approved,
    denied,
    expired,
};

pub const AgentApprovalRequest = struct {
    id: u64,
    session_id: u64,
    capability: policy.AgentCapability,
    description: []u8,
    status: AgentApprovalStatus = .pending,
    created_at_ms: i64,
    resolved_at_ms: ?i64 = null,
    proposal_id: ?u64 = null,
    command_display: ?[]u8 = null,

    pub fn deinit(self: *AgentApprovalRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.description);
        if (self.command_display) |command| allocator.free(command);
        self.* = undefined;
    }
};

