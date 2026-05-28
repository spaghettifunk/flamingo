const std = @import("std");
const agent = @import("session.zig");
const approval = @import("approval.zig");
const audit = @import("audit.zig");
const policy = @import("policy.zig");

pub const StartError = error{
    AgentSessionAlreadyRunning,
    EmptyPrompt,
} || std.mem.Allocator.Error;

pub const AgentManager = struct {
    allocator: std.mem.Allocator,
    sessions: std.ArrayListUnmanaged(agent.AgentSession) = .empty,
    approvals: std.ArrayListUnmanaged(approval.AgentApprovalRequest) = .empty,
    next_id: u64 = 1,
    next_approval_id: u64 = 1,
    active_session_id: ?u64 = null,
    selected_index: usize = 0,
    event_scroll: usize = 0,
    visible: bool = false,
    prompt_input: std.ArrayListUnmanaged(u8) = .empty,
    selected_mode: agent.AgentMode = .plan,

    pub fn init(allocator: std.mem.Allocator) AgentManager {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *AgentManager) void {
        for (self.sessions.items) |*session| session.deinit(self.allocator);
        self.sessions.deinit(self.allocator);
        for (self.approvals.items) |*request| request.deinit(self.allocator);
        self.approvals.deinit(self.allocator);
        self.prompt_input.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn open(self: *AgentManager) void {
        self.visible = true;
        self.selectLatest();
    }

    pub fn close(self: *AgentManager) bool {
        if (self.hasRunningSession()) return false;
        self.visible = false;
        return true;
    }

    pub fn canEditPrompt(self: *const AgentManager) bool {
        return !self.hasRunningSession();
    }

    pub fn appendPromptChar(self: *AgentManager, ch: u8) !void {
        if (!self.canEditPrompt()) return;
        try self.prompt_input.append(self.allocator, ch);
    }

    pub fn backspacePrompt(self: *AgentManager) void {
        if (!self.canEditPrompt() or self.prompt_input.items.len == 0) return;
        _ = self.prompt_input.pop();
    }

    pub fn toggleMode(self: *AgentManager) void {
        if (!self.canEditPrompt()) return;
        self.selected_mode = self.selected_mode.toggle();
    }

    pub fn clearPrompt(self: *AgentManager) void {
        self.prompt_input.clearRetainingCapacity();
    }

    pub fn createSession(self: *AgentManager, now_ms: i64) StartError!u64 {
        if (self.hasRunningSession()) return error.AgentSessionAlreadyRunning;
        const prompt = std.mem.trim(u8, self.prompt_input.items, " \t\r\n");
        if (prompt.len == 0) return error.EmptyPrompt;

        const id = self.next_id;
        self.next_id +%= 1;
        const owned_prompt = try self.allocator.dupe(u8, prompt);
        errdefer self.allocator.free(owned_prompt);

        try self.sessions.append(self.allocator, .{
            .id = id,
            .mode = self.selected_mode,
            .status = .running,
            .prompt = owned_prompt,
            .started_at_ms = now_ms,
        });
        self.selected_index = self.sessions.items.len - 1;
        self.active_session_id = id;
        self.event_scroll = 0;

        const session = self.findSession(id).?;
        try session.appendEvent(self.allocator, .user_prompt, prompt, now_ms);
        return id;
    }

    pub fn appendEvent(
        self: *AgentManager,
        id: u64,
        kind: agent.AgentEventKind,
        text: []const u8,
        timestamp_ms: i64,
    ) !void {
        const session = self.findSession(id) orelse return;
        try session.appendEvent(self.allocator, kind, text, timestamp_ms);
    }

    pub fn appendAuditEvent(
        self: *AgentManager,
        id: u64,
        kind: audit.AgentAuditEventKind,
        message: []const u8,
        timestamp_ms: i64,
    ) !void {
        const session = self.findSession(id) orelse return;
        try session.appendAuditEvent(self.allocator, kind, message, timestamp_ms);
    }

    pub fn createApprovalRequest(
        self: *AgentManager,
        session_id: u64,
        capability: policy.AgentCapability,
        description: []const u8,
        now_ms: i64,
        proposal_id: ?u64,
        command_display: ?[]const u8,
    ) !u64 {
        if (self.pendingApprovalForSession(session_id)) |existing| return existing.id;
        const id = self.next_approval_id;
        self.next_approval_id +%= 1;
        try self.approvals.append(self.allocator, .{
            .id = id,
            .session_id = session_id,
            .capability = capability,
            .description = try self.allocator.dupe(u8, description),
            .created_at_ms = now_ms,
            .proposal_id = proposal_id,
            .command_display = if (command_display) |command| try self.allocator.dupe(u8, command) else null,
        });
        return id;
    }

    pub fn pendingApprovalForSession(self: *AgentManager, session_id: u64) ?*approval.AgentApprovalRequest {
        for (self.approvals.items) |*request| {
            if (request.session_id == session_id and request.status == .pending) return request;
        }
        return null;
    }

    pub fn selectedPendingApproval(self: *AgentManager) ?*approval.AgentApprovalRequest {
        const session = self.selectedSessionConst() orelse return null;
        return self.pendingApprovalForSession(session.id);
    }

    pub fn resolveApproval(self: *AgentManager, id: u64, status: approval.AgentApprovalStatus, now_ms: i64) bool {
        for (self.approvals.items) |*request| {
            if (request.id == id and request.status == .pending) {
                request.status = status;
                request.resolved_at_ms = now_ms;
                return true;
            }
        }
        return false;
    }

    pub fn finishSession(self: *AgentManager, id: u64, status: agent.AgentSessionStatus, finished_at_ms: i64) void {
        const session = self.findSession(id) orelse return;
        session.status = status;
        session.finished_at_ms = finished_at_ms;
        if (self.active_session_id == id) self.active_session_id = null;
    }

    pub fn failToStart(self: *AgentManager, id: u64, message: []const u8, now_ms: i64) !void {
        const session = self.findSession(id) orelse return;
        try session.appendEvent(self.allocator, .agent_error, message, now_ms);
        session.status = .failed;
        session.finished_at_ms = now_ms;
        if (self.active_session_id == id) self.active_session_id = null;
    }

    pub fn selectedSession(self: *AgentManager) ?*agent.AgentSession {
        if (self.sessions.items.len == 0) return null;
        self.clampSelection();
        return &self.sessions.items[self.selected_index];
    }

    pub fn selectedSessionConst(self: *const AgentManager) ?*const agent.AgentSession {
        if (self.sessions.items.len == 0) return null;
        const index = @min(self.selected_index, self.sessions.items.len - 1);
        return &self.sessions.items[index];
    }

    pub fn findSession(self: *AgentManager, id: u64) ?*agent.AgentSession {
        for (self.sessions.items) |*session| {
            if (session.id == id) return session;
        }
        return null;
    }

    pub fn selectLatest(self: *AgentManager) void {
        if (self.sessions.items.len == 0) {
            self.selected_index = 0;
        } else {
            self.selected_index = self.sessions.items.len - 1;
        }
        self.event_scroll = 0;
    }

    pub fn scrollUp(self: *AgentManager, amount: usize) void {
        self.event_scroll = self.event_scroll -| amount;
    }

    pub fn scrollDown(self: *AgentManager, amount: usize, visible_rows: usize) void {
        const session = self.selectedSessionConst() orelse return;
        const max_scroll = session.events.items.len -| visible_rows;
        self.event_scroll = @min(self.event_scroll + amount, max_scroll);
    }

    pub fn clampScroll(self: *AgentManager, visible_rows: usize) void {
        const session = self.selectedSessionConst() orelse {
            self.event_scroll = 0;
            return;
        };
        self.event_scroll = @min(self.event_scroll, session.events.items.len -| visible_rows);
    }

    pub fn hasRunningSession(self: *const AgentManager) bool {
        const id = self.active_session_id orelse return false;
        const session = self.findSessionConst(id) orelse return false;
        return session.status == .running;
    }

    fn findSessionConst(self: *const AgentManager, id: u64) ?*const agent.AgentSession {
        for (self.sessions.items) |*session| {
            if (session.id == id) return session;
        }
        return null;
    }

    fn clampSelection(self: *AgentManager) void {
        if (self.sessions.items.len == 0) {
            self.selected_index = 0;
        } else if (self.selected_index >= self.sessions.items.len) {
            self.selected_index = self.sessions.items.len - 1;
        }
    }
};

test "agent manager creates session and appends events" {
    const allocator = std.testing.allocator;
    var manager = AgentManager.init(allocator);
    defer manager.deinit();

    try manager.prompt_input.appendSlice(allocator, "build an agent");
    const id = try manager.createSession(10);
    try manager.appendEvent(id, .status, "running", 11);

    const session = manager.selectedSessionConst().?;
    try std.testing.expectEqual(id, session.id);
    try std.testing.expectEqual(agent.AgentMode.plan, session.mode);
    try std.testing.expectEqual(agent.AgentSessionStatus.running, session.status);
    try std.testing.expectEqual(@as(usize, 2), session.events.items.len);
    try std.testing.expectEqual(agent.AgentEventKind.user_prompt, session.events.items[0].kind);
    try std.testing.expectEqualStrings("running", session.events.items[1].text);
}

test "agent manager completes and cancels sessions" {
    const allocator = std.testing.allocator;
    var manager = AgentManager.init(allocator);
    defer manager.deinit();

    try manager.prompt_input.appendSlice(allocator, "first");
    const first = try manager.createSession(1);
    manager.finishSession(first, .completed, 2);
    try std.testing.expectEqual(agent.AgentSessionStatus.completed, manager.selectedSessionConst().?.status);

    manager.clearPrompt();
    try manager.prompt_input.appendSlice(allocator, "second");
    const second = try manager.createSession(3);
    manager.finishSession(second, .cancelled, 4);
    try std.testing.expectEqual(agent.AgentSessionStatus.cancelled, manager.selectedSessionConst().?.status);
}

test "agent manager rejects concurrent sessions" {
    const allocator = std.testing.allocator;
    var manager = AgentManager.init(allocator);
    defer manager.deinit();

    try manager.prompt_input.appendSlice(allocator, "one");
    _ = try manager.createSession(1);
    try std.testing.expectError(error.AgentSessionAlreadyRunning, manager.createSession(2));
}
