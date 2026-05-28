const std = @import("std");
const config = @import("../../config.zig");
const session_mod = @import("session.zig");
const tools = @import("tools.zig");
const guard = @import("workspace_guard.zig");
const global_search = @import("../global_search.zig");

pub const AgentCapability = enum {
    list_files,
    read_file,
    search_text,
    get_git_status,
    get_git_diff_summary,
    create_patch_proposal,
    apply_patch_proposal,
    run_validation_task,

    pub fn label(self: AgentCapability) []const u8 {
        return switch (self) {
            .list_files => "list_files",
            .read_file => "read_file",
            .search_text => "search_text",
            .get_git_status => "get_git_status",
            .get_git_diff_summary => "get_git_diff_summary",
            .create_patch_proposal => "create_patch_proposal",
            .apply_patch_proposal => "apply_patch_proposal",
            .run_validation_task => "run_validation_task",
        };
    }
};

pub const PolicyDecision = enum {
    allow,
    deny,
    require_user_approval,
};

pub const AgentPolicyRequest = struct {
    session_id: u64,
    capability: AgentCapability,
    tool_name: ?tools.AgentToolName = null,
    path: ?[]const u8 = null,
    command_display: ?[]const u8 = null,
    reason: ?[]const u8 = null,
};

pub const AgentPolicyResult = struct {
    decision: PolicyDecision,
    message: ?[]const u8 = null,
};

pub const AgentPolicySessionState = struct {
    id: u64,
    mode: session_mod.AgentMode,
    tool_call_count: usize = 0,
    file_read_count: usize = 0,
    search_result_count: usize = 0,
};

pub const AgentPolicyConfig = struct {
    require_approval_for_validation: bool = false,
    require_approval_for_patch_apply: bool = true,
    max_tool_calls: usize = 100,
    max_file_reads: usize = 50,
    max_search_results: usize = 100,
    max_file_read_bytes: usize = tools.max_file_read_bytes,
    deny_paths: []const []const u8 = &.{ ".git", "zig-out", ".zig-cache", "node_modules", "target", "dist", "build" },
    validation_commands: []const []const u8 = &.{ "zig build test", "zig build" },

    pub fn fromAgentConfig(agent_cfg: config.AgentConfig) AgentPolicyConfig {
        return .{
            .require_approval_for_validation = agent_cfg.policy.require_approval_for_validation,
            .require_approval_for_patch_apply = agent_cfg.policy.require_approval_for_patch_apply,
            .max_tool_calls = agent_cfg.limits.max_tool_calls,
            .max_file_reads = agent_cfg.limits.max_file_reads,
            .max_search_results = agent_cfg.limits.max_search_results,
            .max_file_read_bytes = agent_cfg.limits.max_file_read_bytes,
            .deny_paths = agent_cfg.policy.paths.deny,
            .validation_commands = agent_cfg.validation.commands,
        };
    }
};

pub const AgentPolicyEngine = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    workspace_root: []const u8,
    config: AgentPolicyConfig = .{},

    pub fn init(allocator: std.mem.Allocator, io: std.Io, workspace_root: []const u8, policy_config: AgentPolicyConfig) AgentPolicyEngine {
        return .{
            .allocator = allocator,
            .io = io,
            .workspace_root = workspace_root,
            .config = policy_config,
        };
    }

    pub fn evaluate(self: *AgentPolicyEngine, session: anytype, request: AgentPolicyRequest) AgentPolicyResult {
        if (request.session_id != session.id) return deny("session mismatch");
        if (session.tool_call_count >= self.config.max_tool_calls) return deny("tool call limit reached");

        const mode_result = self.evaluateMode(session.mode, request);
        if (mode_result.decision != .allow) return mode_result;

        switch (request.capability) {
            .read_file => {
                if (session.file_read_count >= self.config.max_file_reads) return deny("file read limit reached");
                if (request.path) |path| {
                    if (self.evaluateReadPath(path)) |result| return result;
                } else return deny("read_file requires a path");
            },
            .list_files => if (request.path) |path| {
                if (self.evaluateWorkspacePath(path, false)) |result| return result;
            },
            .create_patch_proposal, .apply_patch_proposal => if (request.path) |path| {
                if (self.evaluateWorkspacePath(path, false)) |result| return result;
            },
            .run_validation_task => {
                const command = request.command_display orelse return deny("validation command is missing");
                if (!self.isConfiguredValidationCommand(command)) return deny("validation command is not configured");
                if (self.config.require_approval_for_validation) return requireApproval("validation command requires approval");
            },
            .search_text, .get_git_status, .get_git_diff_summary => {},
        }

        if (request.capability == .apply_patch_proposal and self.config.require_approval_for_patch_apply) {
            return requireApproval("proposal application requires approval");
        }

        session.tool_call_count += 1;
        if (request.capability == .read_file) session.file_read_count += 1;
        return allow("allowed by agent policy");
    }

    pub fn recordSearchResults(self: *AgentPolicyEngine, session: anytype, result_count: usize) AgentPolicyResult {
        if (session.search_result_count + result_count > self.config.max_search_results) {
            return deny("search result limit reached");
        }
        session.search_result_count += result_count;
        return allow("search result count recorded");
    }

    fn evaluateMode(self: *AgentPolicyEngine, mode: session_mod.AgentMode, request: AgentPolicyRequest) AgentPolicyResult {
        _ = self;
        return switch (mode) {
            .plan => switch (request.capability) {
                .list_files,
                .read_file,
                .search_text,
                .get_git_status,
                .get_git_diff_summary,
                => allow("allowed in plan mode"),
                .create_patch_proposal,
                .apply_patch_proposal,
                .run_validation_task,
                => deny("plan mode is read-only"),
            },
            .implementation => switch (request.capability) {
                .list_files,
                .read_file,
                .search_text,
                .get_git_status,
                .get_git_diff_summary,
                .create_patch_proposal,
                .apply_patch_proposal,
                .run_validation_task,
                => allow("allowed in implementation mode"),
            },
        };
    }

    fn evaluateReadPath(self: *AgentPolicyEngine, path: []const u8) ?AgentPolicyResult {
        if (self.evaluateWorkspacePath(path, true)) |result| return result;
        const absolute = guard.resolveWorkspacePath(self.allocator, self.io, self.workspace_root, path) catch |err| {
            return deny(workspaceErrorMessage(err));
        };
        defer self.allocator.free(absolute);
        const stat = std.Io.Dir.cwd().statFile(self.io, absolute, .{}) catch |err| return deny(workspaceErrorMessage(err));
        if (stat.kind != .file) return deny("path is not a file");
        if (stat.size > self.config.max_file_read_bytes) return deny("file exceeds read byte cap");
        const contents = std.Io.Dir.cwd().readFileAlloc(self.io, absolute, self.allocator, std.Io.Limit.limited(self.config.max_file_read_bytes)) catch |err| {
            return deny(workspaceErrorMessage(err));
        };
        defer self.allocator.free(contents);
        if (global_search.isLikelyBinary(contents)) return deny("binary file reads are not allowed");
        return null;
    }

    fn evaluateWorkspacePath(self: *AgentPolicyEngine, path: []const u8, existing: bool) ?AgentPolicyResult {
        if (path.len == 0) return deny("path is empty");
        if (matchesDeniedPath(path, self.config.deny_paths)) return deny("path is denied by agent policy");
        const absolute = guard.resolveWorkspacePath(self.allocator, self.io, self.workspace_root, path) catch |err| {
            if (err == error.FileNotFound and !existing) return null;
            return deny(workspaceErrorMessage(err));
        };
        self.allocator.free(absolute);
        return null;
    }

    fn isConfiguredValidationCommand(self: *const AgentPolicyEngine, command: []const u8) bool {
        for (self.config.validation_commands) |candidate| {
            if (std.mem.eql(u8, command, candidate)) return true;
        }
        return false;
    }
};

pub fn capabilityFromToolName(name: tools.AgentToolName) AgentCapability {
    return switch (name) {
        .list_files => .list_files,
        .read_file => .read_file,
        .search_text => .search_text,
        .get_git_status => .get_git_status,
        .get_git_diff_summary => .get_git_diff_summary,
    };
}

fn matchesDeniedPath(path: []const u8, deny_paths: []const []const u8) bool {
    var it = std.mem.tokenizeAny(u8, path, "/\\");
    while (it.next()) |part| {
        for (deny_paths) |candidate| {
            if (std.mem.eql(u8, part, candidate)) return true;
        }
    }
    return false;
}

fn allow(message: []const u8) AgentPolicyResult {
    return .{ .decision = .allow, .message = message };
}

fn deny(message: []const u8) AgentPolicyResult {
    return .{ .decision = .deny, .message = message };
}

fn requireApproval(message: []const u8) AgentPolicyResult {
    return .{ .decision = .require_user_approval, .message = message };
}

fn workspaceErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.OutsideWorkspace => "path escapes workspace",
        error.GitInternalsForbidden => ".git internals are denied",
        error.EmptyWorkspaceRoot => "workspace root is empty",
        error.EmptyPath => "path is empty",
        error.FileNotFound => "path does not exist",
        error.AccessDenied => "path access denied",
        else => "path is denied by agent policy",
    };
}

test "policy denies write capabilities in plan mode" {
    const allocator = std.testing.allocator;
    var session = session_mod.AgentSession{
        .id = 1,
        .mode = .plan,
        .status = .running,
        .prompt = try allocator.dupe(u8, "plan"),
        .started_at_ms = 0,
    };
    defer session.deinit(allocator);
    var engine = AgentPolicyEngine.init(allocator, std.testing.io, ".", .{});
    const result = engine.evaluate(&session, .{ .session_id = 1, .capability = .run_validation_task, .command_display = "zig build test" });
    try std.testing.expectEqual(PolicyDecision.deny, result.decision);
}

test "policy validation allowlist works" {
    const allocator = std.testing.allocator;
    var session = session_mod.AgentSession{
        .id = 1,
        .mode = .implementation,
        .status = .running,
        .prompt = try allocator.dupe(u8, "impl"),
        .started_at_ms = 0,
    };
    defer session.deinit(allocator);
    var engine = AgentPolicyEngine.init(allocator, std.testing.io, ".", .{});
    try std.testing.expectEqual(PolicyDecision.allow, engine.evaluate(&session, .{ .session_id = 1, .capability = .run_validation_task, .command_display = "zig build test" }).decision);
    try std.testing.expectEqual(PolicyDecision.deny, engine.evaluate(&session, .{ .session_id = 1, .capability = .run_validation_task, .command_display = "rm -rf ." }).decision);
}
