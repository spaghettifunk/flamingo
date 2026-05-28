const std = @import("std");

pub const PatchProposalStatus = enum {
    pending,
    approved,
    rejected,
    applying,
    applied,
    failed,

    pub fn label(self: PatchProposalStatus) []const u8 {
        return switch (self) {
            .pending => "Pending",
            .approved => "Approved",
            .rejected => "Rejected",
            .applying => "Applying",
            .applied => "Applied",
            .failed => "Failed",
        };
    }

    pub fn glyph(self: PatchProposalStatus) []const u8 {
        return switch (self) {
            .pending => "P",
            .approved => "A",
            .rejected => "x",
            .applying => "*",
            .applied => "+",
            .failed => "!",
        };
    }
};

pub const CreateFileEdit = struct {
    content: []u8,

    pub fn deinit(self: *CreateFileEdit, allocator: std.mem.Allocator) void {
        allocator.free(self.content);
        self.* = undefined;
    }
};

pub const InsertAtLineEdit = struct {
    line: usize,
    expected_before: ?[]u8 = null,
    content: []u8,

    pub fn deinit(self: *InsertAtLineEdit, allocator: std.mem.Allocator) void {
        if (self.expected_before) |expected| allocator.free(expected);
        allocator.free(self.content);
        self.* = undefined;
    }
};

pub const ProposedEdit = union(enum) {
    create_file: CreateFileEdit,
    insert_at_line: InsertAtLineEdit,

    pub fn deinit(self: *ProposedEdit, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .create_file => |*edit| edit.deinit(allocator),
            .insert_at_line => |*edit| edit.deinit(allocator),
        }
        self.* = undefined;
    }
};

pub const PatchProposal = struct {
    id: u64,
    session_id: u64,
    file_path: []u8,
    description: []u8,
    unified_diff: []u8,
    edit: ProposedEdit,
    status: PatchProposalStatus,
    created_at_ms: i64,
    updated_at_ms: i64,
    error_message: ?[]u8 = null,

    pub fn deinit(self: *PatchProposal, allocator: std.mem.Allocator) void {
        allocator.free(self.file_path);
        allocator.free(self.description);
        allocator.free(self.unified_diff);
        self.edit.deinit(allocator);
        if (self.error_message) |message| allocator.free(message);
        self.* = undefined;
    }

    pub fn setError(self: *PatchProposal, allocator: std.mem.Allocator, message: []const u8, now_ms: i64) !void {
        if (self.error_message) |old| allocator.free(old);
        self.error_message = try allocator.dupe(u8, message);
        self.status = .failed;
        self.updated_at_ms = now_ms;
    }
};

pub const PatchProposalDraft = struct {
    session_id: u64,
    file_path: []u8,
    description: []u8,
    unified_diff: []u8,
    edit: ProposedEdit,
    created_at_ms: i64,

    pub fn deinit(self: *PatchProposalDraft, allocator: std.mem.Allocator) void {
        allocator.free(self.file_path);
        allocator.free(self.description);
        allocator.free(self.unified_diff);
        self.edit.deinit(allocator);
        self.* = undefined;
    }
};
