const backend = @import("backend.zig");
const config = @import("../../config.zig");

pub const ProviderError = error{UnknownAgentProvider};

pub fn kindFromConfig(cfg: config.AgentConfig) ProviderError!backend.AgentBackendKind {
    return cfg.providerKind() orelse error.UnknownAgentProvider;
}

test "provider registry resolves configured backend" {
    try @import("std").testing.expectEqual(backend.AgentBackendKind.mock, try kindFromConfig(.{}));
    try @import("std").testing.expectEqual(backend.AgentBackendKind.openai_codex, try kindFromConfig(.{ .provider = "openai" }));
    try @import("std").testing.expectError(error.UnknownAgentProvider, kindFromConfig(.{ .provider = "bogus" }));
}
