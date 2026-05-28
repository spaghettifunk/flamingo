const session = @import("session.zig");

pub fn systemPromptForMode(mode: session.AgentMode) []const u8 {
    return switch (mode) {
        .plan =>
        \\You are running in Plan mode.
        \\You may inspect files and repository state.
        \\You must not propose direct file writes.
        \\You must produce a structured implementation plan.
        \\You must mention likely files, risks, validation steps, and non-goals.
        ,
        .implementation =>
        \\You are running in Implementation mode.
        \\You must not write files directly.
        \\All code changes must be represented as patch proposals.
        \\All proposals require review before application.
        \\Validation must run through the Task Runner.
        \\Git diff review is the final source of truth.
        ,
    };
}

test "prompt templates include mode rules" {
    const std = @import("std");
    try std.testing.expect(std.mem.indexOf(u8, systemPromptForMode(.plan), "Plan mode") != null);
    try std.testing.expect(std.mem.indexOf(u8, systemPromptForMode(.implementation), "patch proposals") != null);
}
