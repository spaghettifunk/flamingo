const std = @import("std");
const agent = @import("session.zig");
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
}

pub fn onTaskFinished(ed: anytype, task_id: u64, status: task_mod.TaskStatus, exit_code: ?i32, finished_at_ms: i64) void {
    const execution_item = ed.state.execution_manager.markTaskFinished(task_id, status, exit_code, finished_at_ms) catch return;
    const execution_id = execution_item.id;
    const command = taskCommand(execution_item, task_id);

    appendExecutionEventById(ed, execution_id, .execution_validation_task_finished, "{s}: {s}", .{ command, status.label() });

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
    if (execution_item.next_validation_index >= validation_commands.len) return;
    const command = validation_commands[execution_item.next_validation_index];
    const root = agentRoot(ed);

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

fn hasMoreValidationCommands(ed: anytype, execution_id: u64) bool {
    const execution_item = ed.state.execution_manager.getExecutionConst(execution_id) orelse return false;
    return execution_item.next_validation_index < validation_commands.len;
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
