const std = @import("std");
const builtin = @import("builtin");
const logz = @import("logz");
const agent = @import("../agent/session.zig");
const audit = @import("../agent/audit.zig");
const context_mod = @import("../agent/context.zig");
const policy = @import("../agent/policy.zig");
const tools = @import("../agent/tools.zig");
const tool_executor = @import("../agent/tool_executor.zig");
const readonly_planner = @import("../agent/readonly_planner.zig");
const mock_implementation = @import("../agent/mock_implementation.zig");
const event_queue = @import("event_queue.zig");

pub const StartError = error{AgentSessionAlreadyRunning} || std.mem.Allocator.Error || std.Thread.SpawnError;

const StartRequest = struct {
    id: u64,
    mode: agent.AgentMode,
    prompt: []u8,
    workspace_root: []u8,
    context: context_mod.AgentContextPackage,

    fn deinit(self: *StartRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.prompt);
        allocator.free(self.workspace_root);
        self.context.deinit(allocator);
        self.* = undefined;
    }
};

const ScriptStep = struct {
    kind: agent.AgentEventKind,
    text: []const u8,
};

pub const MockAgentWorker = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    queue: *event_queue.EventQueue,
    mutex: std.Io.Mutex = .init,
    running: bool = false,
    cancelled: bool = false,
    thread: ?std.Thread = null,
    policy_config: policy.AgentPolicyConfig = .{},

    pub fn init(allocator: std.mem.Allocator, io: std.Io, queue: *event_queue.EventQueue) MockAgentWorker {
        return .{
            .allocator = allocator,
            .io = io,
            .queue = queue,
        };
    }

    pub fn deinit(self: *MockAgentWorker) void {
        self.cancelRunning();
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
    }

    pub fn configurePolicy(self: *MockAgentWorker, policy_config: policy.AgentPolicyConfig) void {
        self.policy_config = policy_config;
    }

    pub fn startSession(
        self: *MockAgentWorker,
        id: u64,
        mode: agent.AgentMode,
        prompt: []const u8,
        workspace_root: []const u8,
        context: *const context_mod.AgentContextPackage,
    ) StartError!void {
        try self.prepareForStart();

        if (!builtin.is_test) logz.debug().fmt("msg", "mock startSession: Session ID {d}, Mode: {s}", .{ id, @tagName(mode) }).log();

        const owned_prompt = try self.allocator.dupe(u8, prompt);
        errdefer self.allocator.free(owned_prompt);
        const owned_workspace_root = try self.allocator.dupe(u8, workspace_root);
        errdefer self.allocator.free(owned_workspace_root);
        const owned_context = try context.clone(self.allocator);

        var request = StartRequest{
            .id = id,
            .mode = mode,
            .prompt = owned_prompt,
            .workspace_root = owned_workspace_root,
            .context = owned_context,
        };
        errdefer request.deinit(self.allocator);

        self.mutex.lockUncancelable(self.io);
        self.running = true;
        self.cancelled = false;
        self.mutex.unlock(self.io);

        self.thread = std.Thread.spawn(.{}, run, .{ self, request }) catch |err| {
            self.mutex.lockUncancelable(self.io);
            self.running = false;
            self.mutex.unlock(self.io);
            return err;
        };
    }

    pub fn cancelRunning(self: *MockAgentWorker) void {
        self.mutex.lockUncancelable(self.io);
        self.cancelled = true;
        self.mutex.unlock(self.io);
    }

    pub fn hasRunningSession(self: *MockAgentWorker) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.running;
    }

    fn prepareForStart(self: *MockAgentWorker) error{AgentSessionAlreadyRunning}!void {
        while (true) {
            self.mutex.lockUncancelable(self.io);
            if (self.running) {
                self.mutex.unlock(self.io);
                return error.AgentSessionAlreadyRunning;
            }
            const thread = self.thread;
            if (thread != null) self.thread = null;
            self.mutex.unlock(self.io);

            if (thread) |t| {
                t.join();
                continue;
            }
            return;
        }
    }

    fn run(self: *MockAgentWorker, request: StartRequest) void {
        var owned_request = request;
        defer owned_request.deinit(self.allocator);
        defer {
            self.mutex.lockUncancelable(self.io);
            self.running = false;
            self.mutex.unlock(self.io);
        }

        if (!builtin.is_test) logz.debug().fmt("msg", "mock run: Thread started for session {d}", .{owned_request.id}).log();

        self.emit(.status, "User prompt received.", owned_request.id);
        const context_summary = owned_request.context.formatCompactSummary(self.allocator) catch null;
        if (context_summary) |text| {
            defer self.allocator.free(text);
            self.emit(.status, text, owned_request.id);
        }
        if (self.pauseOrCancel(owned_request.id)) return;

        switch (owned_request.mode) {
            .plan => self.runPlanScript(owned_request.id, owned_request.prompt, owned_request.workspace_root),
            .implementation => self.runImplementationScript(owned_request.id, owned_request.prompt, owned_request.workspace_root),
        }
    }

    fn runPlanScript(self: *MockAgentWorker, id: u64, prompt: []const u8, workspace_root: []const u8) void {
        if (!builtin.is_test) logz.debug().fmt("msg", "mock runPlanScript: Session {d} starting plan with prompt: '{s}'", .{ id, prompt }).log();
        var executor = tool_executor.AgentToolExecutor.initWithPolicy(self.allocator, self.io, workspace_root, id, .plan, self.policy_config, self.queue);
        var planner = readonly_planner.ReadOnlyPlanner.init(self.allocator, &executor, id);
        var emitter = WorkerPlannerEmitter{ .worker = self, .id = id };
        planner.run(prompt, &emitter) catch |err| switch (err) {
            error.Cancelled => {
                if (!builtin.is_test) logz.debug().fmt("msg", "mock runPlanScript: Session {d} cancelled", .{id}).log();
                return;
            },
            else => {
                if (!builtin.is_test) logz.debug().fmt("msg", "mock runPlanScript: Session {d} failed: {s}", .{ id, @errorName(err) }).log();
                self.emitFmt(.agent_error, id, "Plan session failed: {s}", .{@errorName(err)});
                self.finish(id, .failed);
                return;
            },
        };
        if (self.pauseOrCancel(id)) return;
        if (!builtin.is_test) logz.debug().fmt("msg", "mock runPlanScript: Session {d} completed successfully", .{id}).log();
        self.finish(id, .completed);
    }

    fn runImplementationScript(self: *MockAgentWorker, id: u64, prompt: []const u8, workspace_root: []const u8) void {
        if (!builtin.is_test) logz.debug().fmt("msg", "mock runImplementationScript: Session {d} starting implementation with prompt: '{s}'", .{ id, prompt }).log();
        self.emit(.status, "Starting implementation session.", id);
        if (self.pauseOrCancel(id)) return;

        var executor = tool_executor.AgentToolExecutor.initWithPolicy(self.allocator, self.io, workspace_root, id, .implementation, self.policy_config, self.queue);
        const query = implementationSearchQuery(prompt);
        const call = tools.AgentToolCall{
            .id = 1,
            .session_id = id,
            .input = .{ .search_text = .{ .query = query, .max_results = 10 } },
        };
        if (!builtin.is_test) logz.debug().fmt("msg", "mock runImplementationScript: Session {d} executing mock search tool (query: '{s}')", .{ id, query }).log();
        const call_text = tools.formatToolCall(self.allocator, call) catch null;
        if (call_text) |text| {
            defer self.allocator.free(text);
            self.emit(.tool_call, text, id);
        }
        var result = executor.execute(call);
        defer result.deinit(self.allocator);
        const result_text = tools.formatToolResult(self.allocator, result) catch null;
        if (result_text) |text| {
            defer self.allocator.free(text);
            if (!builtin.is_test) {
                logz.debug().fmt("msg", "mock runImplementationScript: Search tool result received, success={}", .{result.ok}).log();
                logz.debug().fmt("tool_result", "\n{s}", .{text}).log();
            }
            self.emit(if (result.ok) .tool_result else .agent_error, text, id);
        }
        if (self.pauseOrCancel(id)) return;

        self.emit(.assistant_message, "Preparing patch proposal.", id);
        var draft = mock_implementation.buildMockProposalDraft(self.allocator, id, prompt, agent.nowMs(self.io)) catch |err| {
            if (!builtin.is_test) logz.debug().fmt("msg", "mock runImplementationScript: Session {d} proposal generation failed: {s}", .{ id, @errorName(err) }).log();
            self.emitFmt(.proposal_failed, id, "Proposal generation failed: {s}", .{@errorName(err)});
            self.finish(id, .failed);
            return;
        };
        if (!builtin.is_test) logz.debug().fmt("msg", "mock runImplementationScript: Proposed patch for file '{s}': '{s}'", .{ draft.file_path, draft.description }).log();

        var engine = policy.AgentPolicyEngine.init(self.allocator, self.io, workspace_root, self.policy_config);
        self.emitAudit(id, .tool_requested, "create_patch_proposal");
        const decision = engine.evaluate(&executor.policy_state, .{
            .session_id = id,
            .capability = .create_patch_proposal,
            .path = draft.file_path,
            .reason = draft.description,
        });
        if (!builtin.is_test) logz.debug().fmt("msg", "mock runImplementationScript policy evaluation: decision={s}, msg={s}", .{ @tagName(decision.decision), decision.message orelse "" }).log();

        if (decision.decision != .allow) {
            const message = decision.message orelse "patch proposal denied by policy";
            self.emitAudit(id, .tool_denied, message);
            self.emitAudit(id, .policy_violation, message);
            self.emitFmt(.proposal_failed, id, "Proposal generation denied: {s}", .{message});
            draft.deinit(self.allocator);
            self.finish(id, .failed);
            return;
        }
        self.emitAudit(id, .tool_allowed, decision.message orelse "proposal allowed");
        self.queue.push(.{ .agent_proposal_created = draft }) catch |err| {
            draft.deinit(self.allocator);
            if (!builtin.is_test) logz.debug().fmt("msg", "mock runImplementationScript: Session {d} failed to queue proposal: {s}", .{ id, @errorName(err) }).log();
            self.emitFmt(.proposal_failed, id, "Proposal could not be queued: {s}", .{@errorName(err)});
            self.finish(id, .failed);
            return;
        };
        self.emit(.status, "Pending review. Open :proposals to inspect.", id);
        self.finish(id, .completed);
    }

    fn emitScript(
        self: *MockAgentWorker,
        id: u64,
        script: []const ScriptStep,
        final_status: agent.AgentSessionStatus,
    ) void {
        for (script) |entry| {
            if (self.pauseOrCancel(id)) return;
            self.emit(entry.kind, entry.text, id);
        }
        if (self.pauseOrCancel(id)) return;
        self.finish(id, final_status);
    }

    fn pauseOrCancel(self: *MockAgentWorker, id: u64) bool {
        sleepMs(80);
        if (!self.isCancelled()) return false;
        self.emit(.status, "Agent session cancelled.", id);
        self.finish(id, .cancelled);
        return true;
    }

    fn isCancelled(self: *MockAgentWorker) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.cancelled;
    }

    fn emit(self: *MockAgentWorker, kind: agent.AgentEventKind, text: []const u8, id: u64) void {
        const owned = self.allocator.dupe(u8, text) catch return;
        self.queue.push(.{ .agent_event = .{
            .id = id,
            .kind = kind,
            .text = owned,
            .timestamp_ms = agent.nowMs(self.io),
        } }) catch {
            self.allocator.free(owned);
        };
    }

    fn emitFmt(self: *MockAgentWorker, kind: agent.AgentEventKind, id: u64, comptime fmt: []const u8, args: anytype) void {
        const owned = std.fmt.allocPrint(self.allocator, fmt, args) catch return;
        self.queue.push(.{ .agent_event = .{
            .id = id,
            .kind = kind,
            .text = owned,
            .timestamp_ms = agent.nowMs(self.io),
        } }) catch {
            self.allocator.free(owned);
        };
    }

    fn finish(self: *MockAgentWorker, id: u64, status: agent.AgentSessionStatus) void {
        self.queue.push(.{ .agent_session_finished = .{
            .id = id,
            .status = status,
            .finished_at_ms = agent.nowMs(self.io),
        } }) catch {
            return;
        };
    }

    fn emitAudit(self: *MockAgentWorker, id: u64, kind: audit.AgentAuditEventKind, message: []const u8) void {
        const owned = self.allocator.dupe(u8, message) catch return;
        self.queue.push(.{ .agent_audit_event = .{
            .id = id,
            .kind = kind,
            .message = owned,
            .timestamp_ms = agent.nowMs(self.io),
        } }) catch {
            self.allocator.free(owned);
        };
    }
};

fn implementationSearchQuery(prompt: []const u8) []const u8 {
    if (containsInsensitive(prompt, "help")) return "help";
    if (containsInsensitive(prompt, "git")) return "git";
    if (containsInsensitive(prompt, "agent")) return "agent";
    return "TODO";
}

fn containsInsensitive(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i <= haystack.len - needle.len) : (i += 1) {
        var matched = true;
        for (needle, 0..) |ch, j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(ch)) {
                matched = false;
                break;
            }
        }
        if (matched) return true;
    }
    return false;
}

const WorkerPlannerEmitter = struct {
    worker: *MockAgentWorker,
    id: u64,

    pub fn emit(self: *WorkerPlannerEmitter, kind: agent.AgentEventKind, text: []const u8) !bool {
        self.worker.emit(kind, text, self.id);
        return !self.worker.pauseOrCancel(self.id);
    }
};

fn sleepMs(ms: i64) void {
    const req = std.c.timespec{
        .sec = @intCast(@divTrunc(ms, std.time.ms_per_s)),
        .nsec = @intCast(@mod(ms, std.time.ms_per_s) * std.time.ns_per_ms),
    };
    _ = std.c.nanosleep(&req, null);
}

test "implementation mode emits proposal without editing files" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);

    var queue = event_queue.EventQueue.init(allocator, io);
    defer queue.deinit();
    var worker = MockAgentWorker.init(allocator, io, &queue);
    defer worker.deinit();

    var context_package = context_mod.AgentContextPackage{
        .session_id = 9,
        .mode = .implementation,
        .system_prompt = try allocator.dupe(u8, "system"),
        .user_prompt = try allocator.dupe(u8, "add help panel"),
        .workspace_summary = try allocator.dupe(u8, "Workspace root: test\nGit repository: no\n"),
        .git_status_summary = try allocator.dupe(u8, "Not a Git repository."),
        .git_diff_summary = try allocator.dupe(u8, "Not a Git repository."),
        .relevant_files = .empty,
        .tool_descriptions = .empty,
        .policy_summary = try allocator.dupe(u8, "policy"),
        .validation_summary = try allocator.dupe(u8, "validation"),
        .budget = .{ .max_total_bytes = 1024, .used_bytes = 128, .truncated = false },
    };
    defer context_package.deinit(allocator);

    try worker.startSession(9, .implementation, "add help panel", root, &context_package);

    var proposal_seen = false;
    var finished = false;
    while (!finished) {
        var ev = queue.pop().?;
        switch (ev) {
            .agent_event => |event| allocator.free(event.text),
            .agent_audit_event => |event| allocator.free(event.message),
            .agent_proposal_created => |*draft| {
                proposal_seen = true;
                try std.testing.expectEqual(@as(u64, 9), draft.session_id);
                try std.testing.expect(std.mem.endsWith(u8, draft.file_path, "mock-session-9.md"));
                draft.deinit(allocator);
            },
            .agent_session_finished => |done| {
                try std.testing.expectEqual(agent.AgentSessionStatus.completed, done.status);
                finished = true;
            },
            else => {},
        }
    }

    const proposed_path = try std.fs.path.join(allocator, &.{ root, "docs/agent-proposals/mock-session-9.md" });
    defer allocator.free(proposed_path);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, proposed_path, .{}));
    try std.testing.expect(proposal_seen);
}
