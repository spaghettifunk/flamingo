const std = @import("std");
const agent = @import("session.zig");
const context_mod = @import("context.zig");

pub const AgentBackendKind = enum {
    mock,
    openai_codex,

    pub fn label(self: AgentBackendKind) []const u8 {
        return switch (self) {
            .mock => "Mock",
            .openai_codex => "OpenAI Codex",
        };
    }

    pub fn fromString(value: []const u8) ?AgentBackendKind {
        if (std.mem.eql(u8, value, "mock")) return .mock;
        if (std.mem.eql(u8, value, "openai") or
            std.mem.eql(u8, value, "openai_codex") or
            std.mem.eql(u8, value, "codex"))
            return .openai_codex;
        return null;
    }
};

pub const AgentRequest = struct {
    session_id: u64,
    mode: agent.AgentMode,
    prompt: []const u8,
    workspace_root: []const u8,
    context: *const context_mod.AgentContextPackage,
};

pub const AgentBackendError = error{
    AgentSessionAlreadyRunning,
    AgentBackendUnavailable,
} || std.mem.Allocator.Error || std.Thread.SpawnError;

pub const AgentBackend = struct {
    ctx: *anyopaque,
    kind_value: AgentBackendKind,
    startSessionFn: *const fn (ctx: *anyopaque, request: AgentRequest) AgentBackendError!void,
    cancelSessionFn: *const fn (ctx: *anyopaque, session_id: u64) void,
    hasRunningSessionFn: *const fn (ctx: *anyopaque) bool,
    availabilityMessageFn: *const fn (ctx: *anyopaque) ?[]const u8,

    pub fn kind(self: AgentBackend) AgentBackendKind {
        return self.kind_value;
    }

    pub fn startSession(self: AgentBackend, request: AgentRequest) AgentBackendError!void {
        return self.startSessionFn(self.ctx, request);
    }

    pub fn cancelSession(self: AgentBackend, session_id: u64) void {
        self.cancelSessionFn(self.ctx, session_id);
    }

    pub fn hasRunningSession(self: AgentBackend) bool {
        return self.hasRunningSessionFn(self.ctx);
    }

    pub fn availabilityMessage(self: AgentBackend) ?[]const u8 {
        return self.availabilityMessageFn(self.ctx);
    }
};

test "agent backend kind parses config strings" {
    try std.testing.expectEqual(AgentBackendKind.mock, AgentBackendKind.fromString("mock").?);
    try std.testing.expectEqual(AgentBackendKind.openai_codex, AgentBackendKind.fromString("openai").?);
    try std.testing.expect(AgentBackendKind.fromString("nope") == null);
}
