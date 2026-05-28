const std = @import("std");
const agent = @import("session.zig");
const audit = @import("audit.zig");
const policy = @import("policy.zig");
const proposal_apply = @import("proposal_apply.zig");
const command_parser = @import("../tasks/command_parser.zig");
const task_mod = @import("../tasks/task.zig");

pub const validation_commands = [_][]const u8{
    "zig build test",
    "zig build",
};

pub fn approveApplyAndStart(ed: anytype, proposal_id: u64) void {
    const selected = ed.state.proposal_manager.getProposalConst(proposal_id) orelse {
        ed.state.status_message = "No proposal selected";
        return;
    };
    if (selected.status != .pending and selected.status != .approved) {
        ed.state.error_message = "Proposal cannot be applied from its current state";
        return;
    }

    const now = agent.nowMs(ed.io);
    if (!evaluateProposalApplyPolicy(ed, selected.session_id, proposal_id, selected.file_path, selected.description, now)) return;

    const execution_id = ed.state.execution_manager.createForProposal(selected.session_id, proposal_id, now) catch |err| {
        ed.state.error_message = executionErrorMessage(err);
        return;
    };
    appendExecutionEvent(ed, execution_id, .execution_started, "Execution #{d} started for proposal #{d}.", .{ execution_id, proposal_id });

    ed.state.proposal_manager.approveProposal(proposal_id, now) catch |err| switch (err) {
        error.ProposalNotPending => {},
        else => {
            failExecution(ed, execution_id, "Proposal approval failed", "Execution failed before applying the proposal.");
            ed.state.error_message = proposalActionErrorMessage(err);
            return;
        },
    };
    appendProposalEvent(ed, proposal_id, .proposal_approved, "Proposal #{d} approved.", .{proposal_id});

    ed.state.execution_manager.markApplying(execution_id, agent.nowMs(ed.io)) catch {};
    appendExecutionEvent(ed, execution_id, .execution_applying, "Applying proposal #{d}.", .{proposal_id});

    ed.state.proposal_manager.markApplying(proposal_id, agent.nowMs(ed.io)) catch |err| {
        failExecution(ed, execution_id, proposalActionErrorMessage(err), "Execution failed before applying the proposal.");
        ed.state.error_message = proposalActionErrorMessage(err);
        return;
    };
    appendProposalEvent(ed, proposal_id, .proposal_applying, "Proposal #{d} applying.", .{proposal_id});

    const root = agentRoot(ed);
    const proposal = ed.state.proposal_manager.getProposal(proposal_id) orelse return;
    proposal_apply.applyProposalToEditor(ed, proposal, root) catch |err| {
        const message = proposalApplyErrorMessage(err);
        ed.state.proposal_manager.markFailed(proposal_id, message, agent.nowMs(ed.io)) catch {};
        appendProposalEvent(ed, proposal_id, .proposal_failed, "Proposal #{d} failed: {s}", .{ proposal_id, message });
        failExecution(ed, execution_id, message, "Patch application failed. No validation tasks were run.");
        ed.state.error_message = message;
        return;
    };

    ed.state.proposal_manager.markApplied(proposal_id, agent.nowMs(ed.io)) catch {};
    appendProposalEvent(ed, proposal_id, .proposal_applied, "Proposal #{d} applied.", .{proposal_id});
    ed.state.agent_manager.appendAuditEvent(proposal.session_id, .proposal_applied, "proposal applied", agent.nowMs(ed.io)) catch {};

    if (executionCancelRequested(ed, execution_id)) {
        cancelExecution(ed, execution_id, "Execution cancelled after applying. Applied file changes were not rolled back. Review changes with :gitdiff.");
        return;
    }

    startValidation(ed, execution_id);
}

pub fn onTaskStarted(ed: anytype, task_id: u64, started_at_ms: i64) void {
    const execution_item = ed.state.execution_manager.markTaskStarted(task_id, started_at_ms) catch return;
    appendExecutionEventById(ed, execution_item.id, .execution_validation_task_started, "Running validation: {s}", .{
        taskCommand(execution_item, task_id),
    });
    ed.state.agent_manager.appendAuditEvent(execution_item.session_id, .validation_requested, taskCommand(execution_item, task_id), started_at_ms) catch {};
}

pub fn onTaskFinished(ed: anytype, task_id: u64, status: task_mod.TaskStatus, exit_code: ?i32, finished_at_ms: i64) void {
    const execution_item = ed.state.execution_manager.markTaskFinished(task_id, status, exit_code, finished_at_ms) catch return;
    const execution_id = execution_item.id;
    const command = taskCommand(execution_item, task_id);

    appendExecutionEventById(ed, execution_id, .execution_validation_task_finished, "{s}: {s}", .{ command, status.label() });
    ed.state.agent_manager.appendAuditEvent(execution_item.session_id, .validation_completed, command, finished_at_ms) catch {};

    if (status == .cancelled) {
        cancelExecution(ed, execution_id, "Execution cancelled. Applied file changes were not rolled back. Review changes with :gitdiff.");
        return;
    }
    if (status != .success) {
        failExecution(ed, execution_id, "Validation failed", "Patch was applied but validation failed. Open :tasks to inspect output. Review changes with :gitdiff.");
        return;
    }
    if (executionCancelRequested(ed, execution_id)) {
        cancelExecution(ed, execution_id, "Execution cancelled. Applied file changes were not rolled back. Review changes with :gitdiff.");
        return;
    }
    if (hasMoreValidationCommands(ed, execution_id)) {
        startNextValidationCommand(ed, execution_id);
        return;
    }

    const summary = "Applied proposal and validation passed. Review changes with :gitdiff.";
    ed.state.execution_manager.complete(execution_id, summary, agent.nowMs(ed.io)) catch {};
    appendExecutionEventById(ed, execution_id, .execution_completed, "Execution #{d} completed. Open :gitdiff to review workspace changes.", .{execution_id});
    ed.state.status_message = "Execution completed";
}

pub fn onTaskFailedToStart(ed: anytype, task_id: u64, message: []const u8, finished_at_ms: i64) void {
    const execution_item = ed.state.execution_manager.markTaskFinished(task_id, .failed, null, finished_at_ms) catch return;
    failExecution(ed, execution_item.id, message, "Validation task failed to start. Open :tasks to inspect output. Review changes with :gitdiff.");
}

pub fn cancelActiveExecution(ed: anytype) bool {
    const active = ed.state.execution_manager.activeExecutionConst() orelse return false;
    const id = active.id;
    const status = active.status;
    ed.state.execution_manager.requestCancel(id) catch return false;
    if (status == .validating) {
        ed.runtime.task_worker.cancelRunning();
        ed.state.status_message = "Cancelling execution";
        appendExecutionEventById(ed, id, .execution_cancelled, "Execution #{d} cancellation requested.", .{id});
        return true;
    }
    cancelExecution(ed, id, "Execution cancelled. Applied file changes were not rolled back. Review changes with :gitdiff.");
    return true;
}

pub fn approvePendingApproval(ed: anytype) bool {
    const request = ed.state.agent_manager.selectedPendingApproval() orelse return false;
    const request_id = request.id;
    const session_id = request.session_id;
    const capability = request.capability;
    const now = agent.nowMs(ed.io);
    if (!ed.state.agent_manager.resolveApproval(request_id, .approved, now)) return false;
    ed.state.agent_manager.appendAuditEvent(session_id, .approval_approved, "user approved request", now) catch {};
    ed.state.agent_manager.appendEvent(session_id, .status, "Approval granted.", now) catch {};
    if (capability == .run_validation_task) {
        const active = ed.state.execution_manager.activeExecutionConst() orelse return true;
        startNextValidationCommand(ed, active.id);
    }
    return true;
}

pub fn denyPendingApproval(ed: anytype) bool {
    const request = ed.state.agent_manager.selectedPendingApproval() orelse return false;
    const request_id = request.id;
    const session_id = request.session_id;
    const capability = request.capability;
    const now = agent.nowMs(ed.io);
    if (!ed.state.agent_manager.resolveApproval(request_id, .denied, now)) return false;
    ed.state.agent_manager.appendAuditEvent(session_id, .approval_denied, "user denied request", now) catch {};
    ed.state.agent_manager.appendEvent(session_id, .agent_error, "Approval denied.", now) catch {};
    if (capability == .run_validation_task) {
        if (ed.state.execution_manager.activeExecutionConst()) |active| {
            failExecution(ed, active.id, "Validation approval denied", "Validation was denied by the user.");
        }
    }
    return true;
}

fn startValidation(ed: anytype, execution_id: u64) void {
    ed.state.execution_manager.markValidating(execution_id) catch |err| {
        failExecution(ed, execution_id, executionErrorMessage(err), "Execution failed before validation could start.");
        return;
    };
    appendExecutionEventById(ed, execution_id, .execution_validating, "Running validation tasks.", .{});
    startNextValidationCommand(ed, execution_id);
}

fn startNextValidationCommand(ed: anytype, execution_id: u64) void {
    const execution_item = ed.state.execution_manager.getExecutionConst(execution_id) orelse return;
    const commands = configuredValidationCommands(ed);
    if (execution_item.next_validation_index >= commands.len) return;
    const command = commands[execution_item.next_validation_index];
    const root = agentRoot(ed);
    const policy_result = evaluateValidationPolicy(ed, execution_item.session_id, execution_id, command);
    switch (policy_result) {
        .allowed => {},
        .pending => return,
        .denied => |message| {
            failExecution(ed, execution_id, message, "Validation command was denied by policy.");
            return;
        },
    }

    var parsed = command_parser.parse(ed.allocator, command) catch |err| {
        failExecution(ed, execution_id, parseErrorMessage(err), "Validation command could not be parsed.");
        return;
    };
    var parsed_owned = true;
    errdefer if (parsed_owned) parsed.deinit(ed.allocator);

    const task_id = ed.state.task_manager.addQueuedTask(parsed, root, task_mod.nowMs(ed.io)) catch |err| {
        failExecution(ed, execution_id, executionErrorMessage(err), "Validation task could not be queued.");
        return;
    };
    parsed_owned = false;
    ed.state.execution_manager.addValidationTask(execution_id, task_id, command) catch |err| {
        failExecution(ed, execution_id, executionErrorMessage(err), "Validation task could not be tracked.");
        return;
    };

    const task = ed.state.task_manager.findTask(task_id) orelse return;
    ed.runtime.task_worker.startTask(task_id, task.argvConst(), task.cwd) catch |err| {
        const message = switch (err) {
            error.TaskAlreadyRunning => "Another task is already running.",
            else => "Unable to start validation task.",
        };
        ed.state.task_manager.failToStart(task_id, message, task_mod.nowMs(ed.io)) catch {};
        failExecution(ed, execution_id, message, "Validation task failed to start. Open :tasks to inspect output. Review changes with :gitdiff.");
        return;
    };
}

const ValidationPolicyOutcome = union(enum) {
    allowed,
    pending,
    denied: []const u8,
};

fn evaluateProposalApplyPolicy(ed: anytype, session_id: u64, proposal_id: u64, path: []const u8, description: []const u8, now: i64) bool {
    var engine = policy.AgentPolicyEngine.init(ed.allocator, ed.io, agentRoot(ed), policy.AgentPolicyConfig.fromAgentConfig(ed.config.agent));
    var state = policy.AgentPolicySessionState{ .id = session_id, .mode = .implementation };
    ed.state.agent_manager.appendAuditEvent(session_id, .tool_requested, "apply_patch_proposal", now) catch {};
    const decision = engine.evaluate(&state, .{
        .session_id = session_id,
        .capability = .apply_patch_proposal,
        .path = path,
        .reason = description,
    });
    switch (decision.decision) {
        .allow => {
            ed.state.agent_manager.appendAuditEvent(session_id, .tool_allowed, decision.message orelse "proposal apply allowed", now) catch {};
            return true;
        },
        .require_user_approval => {
            _ = ed.state.agent_manager.createApprovalRequest(session_id, .apply_patch_proposal, "Proposal application approved from Proposals panel.", now, proposal_id, null) catch {};
            if (ed.state.agent_manager.pendingApprovalForSession(session_id)) |request| {
                _ = ed.state.agent_manager.resolveApproval(request.id, .approved, now);
            }
            ed.state.agent_manager.appendAuditEvent(session_id, .approval_approved, "proposal apply approved by proposals panel", now) catch {};
            return true;
        },
        .deny => {
            const message = decision.message orelse "proposal apply denied";
            ed.state.agent_manager.appendAuditEvent(session_id, .tool_denied, message, now) catch {};
            ed.state.agent_manager.appendAuditEvent(session_id, .policy_violation, message, now) catch {};
            ed.state.agent_manager.appendEvent(session_id, .agent_error, message, now) catch {};
            ed.state.error_message = message;
            return false;
        },
    }
}

fn evaluateValidationPolicy(ed: anytype, session_id: u64, execution_id: u64, command: []const u8) ValidationPolicyOutcome {
    if (hasApprovedValidationApproval(ed, session_id, command)) return .allowed;
    var engine = policy.AgentPolicyEngine.init(ed.allocator, ed.io, agentRoot(ed), policy.AgentPolicyConfig.fromAgentConfig(ed.config.agent));
    var state = policy.AgentPolicySessionState{ .id = session_id, .mode = .implementation };
    const now = agent.nowMs(ed.io);
    ed.state.agent_manager.appendAuditEvent(session_id, .validation_requested, command, now) catch {};
    const decision = engine.evaluate(&state, .{
        .session_id = session_id,
        .capability = .run_validation_task,
        .command_display = command,
        .reason = "Validate applied proposal.",
    });
    switch (decision.decision) {
        .allow => return .allowed,
        .deny => {
            const message = decision.message orelse "validation denied";
            ed.state.agent_manager.appendAuditEvent(session_id, .tool_denied, message, now) catch {};
            ed.state.agent_manager.appendAuditEvent(session_id, .policy_violation, message, now) catch {};
            return .{ .denied = message };
        },
        .require_user_approval => {
            var buf: [256]u8 = undefined;
            const description = std.fmt.bufPrint(&buf, "Agent wants to run validation command: {s}", .{command}) catch "Agent wants to run validation.";
            _ = ed.state.agent_manager.createApprovalRequest(session_id, .run_validation_task, description, now, null, command) catch {};
            ed.state.agent_manager.appendAuditEvent(session_id, .approval_requested, command, now) catch {};
            appendExecutionEventById(ed, execution_id, .status, "Approval required for validation: {s}", .{command});
            ed.state.status_message = "Agent approval required";
            return .pending;
        },
    }
}

fn hasApprovedValidationApproval(ed: anytype, session_id: u64, command: []const u8) bool {
    for (ed.state.agent_manager.approvals.items) |request| {
        if (request.session_id != session_id or request.status != .approved or request.capability != .run_validation_task) continue;
        if (request.command_display) |approved_command| {
            if (std.mem.eql(u8, approved_command, command)) return true;
        }
    }
    return false;
}

fn hasMoreValidationCommands(ed: anytype, execution_id: u64) bool {
    const execution_item = ed.state.execution_manager.getExecutionConst(execution_id) orelse return false;
    return execution_item.next_validation_index < configuredValidationCommands(ed).len;
}

fn configuredValidationCommands(ed: anytype) []const []const u8 {
    if (ed.config.agent.validation.commands.len == 0) return &validation_commands;
    return ed.config.agent.validation.commands;
}

fn executionCancelRequested(ed: anytype, execution_id: u64) bool {
    const execution_item = ed.state.execution_manager.getExecutionConst(execution_id) orelse return false;
    return execution_item.cancel_requested;
}

fn failExecution(ed: anytype, execution_id: u64, message: []const u8, summary: []const u8) void {
    ed.state.execution_manager.fail(execution_id, message, summary, agent.nowMs(ed.io)) catch {};
    appendExecutionEventById(ed, execution_id, .execution_failed, "Execution #{d} failed: {s}", .{ execution_id, message });
}

fn cancelExecution(ed: anytype, execution_id: u64, summary: []const u8) void {
    ed.state.execution_manager.cancel(execution_id, summary, agent.nowMs(ed.io)) catch {};
    appendExecutionEventById(ed, execution_id, .execution_cancelled, "Execution #{d} cancelled. Applied file changes were not rolled back.", .{execution_id});
}

fn appendProposalEvent(ed: anytype, proposal_id: u64, kind: agent.AgentEventKind, comptime fmt: []const u8, args: anytype) void {
    const proposal = ed.state.proposal_manager.getProposalConst(proposal_id) orelse return;
    var buf: [256]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch return;
    ed.state.agent_manager.appendEvent(proposal.session_id, kind, text, agent.nowMs(ed.io)) catch {};
}

fn appendExecutionEvent(ed: anytype, execution_id: u64, kind: agent.AgentEventKind, comptime fmt: []const u8, args: anytype) void {
    appendExecutionEventById(ed, execution_id, kind, fmt, args);
}

fn appendExecutionEventById(ed: anytype, execution_id: u64, kind: agent.AgentEventKind, comptime fmt: []const u8, args: anytype) void {
    const execution_item = ed.state.execution_manager.getExecutionConst(execution_id) orelse return;
    var buf: [256]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch return;
    ed.state.agent_manager.appendEvent(execution_item.session_id, kind, text, agent.nowMs(ed.io)) catch {};
}

fn taskCommand(execution_item: anytype, task_id: u64) []const u8 {
    for (execution_item.validation_tasks.items) |record| {
        if (record.task_id == task_id) return record.command;
    }
    return "validation task";
}

fn agentRoot(ed: anytype) []const u8 {
    if (ed.state.project_root) |root| return root;
    if (ed.state.tree) |tree| return tree.root_path;
    if (ed.state.workspace.root_path) |root| return root;
    return ".";
}

fn proposalActionErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.ProposalNotFound => "Proposal not found",
        error.ProposalNotPending => "Proposal is not pending",
        error.ProposalNotApplicable => "Proposal cannot be changed from its current state",
        else => "Proposal action failed",
    };
}

fn proposalApplyErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.OutsideWorkspace => "Proposal target is outside the workspace",
        error.GitInternalsForbidden => "Proposal cannot target .git internals",
        error.BinaryFile => "Proposal target appears to be binary",
        error.PathAlreadyExists => "Proposal target already exists",
        error.FileNotFound => "Proposal target file was not found",
        error.ExpectedFile => "Proposal target is not a file",
        error.HunkMismatch => "Proposal no longer matches the target file",
        error.InvalidLine => "Proposal target line is invalid",
        else => "Proposal apply failed",
    };
}

fn executionErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.ExecutionAlreadyActive => "Another execution is already active",
        error.ExecutionNotFound => "Execution not found",
        error.ExecutionNotActive => "Execution is not active",
        error.ExecutionNotValidating => "Execution is not validating",
        else => "Execution failed",
    };
}

fn parseErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.EmptyCommand => "Validation command is empty",
        error.UnterminatedQuote => "Validation command has an unterminated quote",
        error.TrailingEscape => "Validation command ends with an incomplete escape",
        else => "Validation command could not be parsed",
    };
}
