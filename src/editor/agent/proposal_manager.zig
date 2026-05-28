const std = @import("std");
const proposal = @import("proposal.zig");

pub const ProposalError = error{
    ProposalNotFound,
    ProposalNotPending,
    ProposalNotApplicable,
} || std.mem.Allocator.Error;

pub const ProposalManager = struct {
    allocator: std.mem.Allocator,
    proposals: std.ArrayListUnmanaged(proposal.PatchProposal) = .empty,
    next_id: u64 = 1,
    selected_index: usize = 0,
    diff_scroll: usize = 0,
    visible: bool = false,

    pub fn init(allocator: std.mem.Allocator) ProposalManager {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ProposalManager) void {
        for (self.proposals.items) |*item| item.deinit(self.allocator);
        self.proposals.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn open(self: *ProposalManager) void {
        self.visible = true;
        self.selectLatest();
    }

    pub fn close(self: *ProposalManager) void {
        self.visible = false;
    }

    pub fn createProposal(self: *ProposalManager, draft: proposal.PatchProposalDraft) !u64 {
        var owned_draft = draft;
        errdefer owned_draft.deinit(self.allocator);

        const id = self.next_id;
        self.next_id +%= 1;

        try self.proposals.append(self.allocator, .{
            .id = id,
            .session_id = draft.session_id,
            .file_path = draft.file_path,
            .description = draft.description,
            .unified_diff = draft.unified_diff,
            .edit = draft.edit,
            .status = .pending,
            .created_at_ms = draft.created_at_ms,
            .updated_at_ms = draft.created_at_ms,
        });
        owned_draft = undefined;
        self.selected_index = self.proposals.items.len - 1;
        self.diff_scroll = 0;
        return id;
    }

    pub fn getProposal(self: *ProposalManager, id: u64) ?*proposal.PatchProposal {
        for (self.proposals.items) |*item| {
            if (item.id == id) return item;
        }
        return null;
    }

    pub fn getProposalConst(self: *const ProposalManager, id: u64) ?*const proposal.PatchProposal {
        for (self.proposals.items) |*item| {
            if (item.id == id) return item;
        }
        return null;
    }

    pub fn selectedProposal(self: *ProposalManager) ?*proposal.PatchProposal {
        if (self.proposals.items.len == 0) return null;
        self.clampSelection();
        return &self.proposals.items[self.selected_index];
    }

    pub fn selectedProposalConst(self: *const ProposalManager) ?*const proposal.PatchProposal {
        if (self.proposals.items.len == 0) return null;
        const index = @min(self.selected_index, self.proposals.items.len - 1);
        return &self.proposals.items[index];
    }

    pub fn approveProposal(self: *ProposalManager, id: u64, now_ms: i64) ProposalError!void {
        const item = self.getProposal(id) orelse return error.ProposalNotFound;
        if (item.status != .pending) return error.ProposalNotPending;
        item.status = .approved;
        item.updated_at_ms = now_ms;
    }

    pub fn rejectProposal(self: *ProposalManager, id: u64, now_ms: i64) ProposalError!void {
        const item = self.getProposal(id) orelse return error.ProposalNotFound;
        if (item.status != .pending and item.status != .approved) return error.ProposalNotApplicable;
        item.status = .rejected;
        item.updated_at_ms = now_ms;
    }

    pub fn markApplying(self: *ProposalManager, id: u64, now_ms: i64) ProposalError!void {
        const item = self.getProposal(id) orelse return error.ProposalNotFound;
        if (item.status != .approved and item.status != .pending) return error.ProposalNotApplicable;
        item.status = .applying;
        item.updated_at_ms = now_ms;
    }

    pub fn markApplied(self: *ProposalManager, id: u64, now_ms: i64) ProposalError!void {
        const item = self.getProposal(id) orelse return error.ProposalNotFound;
        if (item.status != .applying) return error.ProposalNotApplicable;
        item.status = .applied;
        item.updated_at_ms = now_ms;
    }

    pub fn markFailed(self: *ProposalManager, id: u64, message: []const u8, now_ms: i64) !void {
        const item = self.getProposal(id) orelse return error.ProposalNotFound;
        try item.setError(self.allocator, message, now_ms);
    }

    pub fn selectLatest(self: *ProposalManager) void {
        if (self.proposals.items.len == 0) {
            self.selected_index = 0;
        } else {
            self.selected_index = self.proposals.items.len - 1;
        }
        self.diff_scroll = 0;
    }

    pub fn selectPrevious(self: *ProposalManager) void {
        if (self.proposals.items.len == 0) return;
        if (self.selected_index > 0) self.selected_index -= 1;
        self.diff_scroll = 0;
    }

    pub fn selectNext(self: *ProposalManager) void {
        if (self.proposals.items.len == 0) return;
        if (self.selected_index + 1 < self.proposals.items.len) self.selected_index += 1;
        self.diff_scroll = 0;
    }

    pub fn scrollUp(self: *ProposalManager, amount: usize) void {
        self.diff_scroll = self.diff_scroll -| amount;
    }

    pub fn scrollDown(self: *ProposalManager, amount: usize, total_rows: usize, visible_rows: usize) void {
        const max_scroll = total_rows -| visible_rows;
        self.diff_scroll = @min(self.diff_scroll + amount, max_scroll);
    }

    pub fn clampScroll(self: *ProposalManager, total_rows: usize, visible_rows: usize) void {
        self.diff_scroll = @min(self.diff_scroll, total_rows -| visible_rows);
    }

    pub fn countBySession(self: *const ProposalManager, session_id: u64) usize {
        var count: usize = 0;
        for (self.proposals.items) |item| {
            if (item.session_id == session_id) count += 1;
        }
        return count;
    }

    fn clampSelection(self: *ProposalManager) void {
        if (self.proposals.items.len == 0) {
            self.selected_index = 0;
        } else if (self.selected_index >= self.proposals.items.len) {
            self.selected_index = self.proposals.items.len - 1;
        }
    }
};

test "proposal manager creates approves and rejects proposals" {
    const allocator = std.testing.allocator;
    var manager = ProposalManager.init(allocator);
    defer manager.deinit();

    const id = try manager.createProposal(.{
        .session_id = 7,
        .file_path = try allocator.dupe(u8, "docs/demo.md"),
        .description = try allocator.dupe(u8, "Create demo"),
        .unified_diff = try allocator.dupe(u8, "--- /dev/null\n+++ b/docs/demo.md\n"),
        .edit = .{ .create_file = .{ .content = try allocator.dupe(u8, "demo\n") } },
        .created_at_ms = 10,
    });

    try std.testing.expectEqual(@as(u64, 1), id);
    try std.testing.expectEqual(proposal.PatchProposalStatus.pending, manager.getProposal(id).?.status);
    try manager.approveProposal(id, 11);
    try std.testing.expectEqual(proposal.PatchProposalStatus.approved, manager.getProposal(id).?.status);

    const second = try manager.createProposal(.{
        .session_id = 7,
        .file_path = try allocator.dupe(u8, "docs/other.md"),
        .description = try allocator.dupe(u8, "Create other"),
        .unified_diff = try allocator.dupe(u8, "--- /dev/null\n+++ b/docs/other.md\n"),
        .edit = .{ .create_file = .{ .content = try allocator.dupe(u8, "other\n") } },
        .created_at_ms = 12,
    });
    try manager.rejectProposal(second, 13);
    try std.testing.expectEqual(proposal.PatchProposalStatus.rejected, manager.getProposal(second).?.status);
    try std.testing.expectEqual(@as(usize, 2), manager.countBySession(7));
}

test "proposal manager enforces state transitions" {
    const allocator = std.testing.allocator;
    var manager = ProposalManager.init(allocator);
    defer manager.deinit();

    const id = try manager.createProposal(.{
        .session_id = 1,
        .file_path = try allocator.dupe(u8, "docs/demo.md"),
        .description = try allocator.dupe(u8, "Create demo"),
        .unified_diff = try allocator.dupe(u8, ""),
        .edit = .{ .create_file = .{ .content = try allocator.dupe(u8, "demo\n") } },
        .created_at_ms = 0,
    });
    try manager.markApplying(id, 1);
    try manager.markApplied(id, 2);
    try std.testing.expectEqual(proposal.PatchProposalStatus.applied, manager.getProposal(id).?.status);
    try std.testing.expectError(error.ProposalNotPending, manager.approveProposal(id, 3));
}
