const std = @import("std");
const session = @import("session.zig");

pub const default_max_context_files: usize = 8;
pub const default_max_context_file_bytes: usize = 32 * 1024;
pub const default_max_context_total_bytes: usize = 256 * 1024;

pub const ContextLimits = struct {
    max_context_files: usize = default_max_context_files,
    max_context_file_bytes: usize = default_max_context_file_bytes,
    max_context_total_bytes: usize = default_max_context_total_bytes,
};

/// All string fields in ContextFile are owned by the package allocator.
pub const ContextFile = struct {
    path: []const u8,
    reason: []const u8,
    content: []const u8,
    truncated: bool,

    pub fn deinit(self: *ContextFile, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.reason);
        allocator.free(self.content);
        self.* = undefined;
    }

    pub fn clone(self: ContextFile, allocator: std.mem.Allocator) !ContextFile {
        return .{
            .path = try allocator.dupe(u8, self.path),
            .reason = try allocator.dupe(u8, self.reason),
            .content = try allocator.dupe(u8, self.content),
            .truncated = self.truncated,
        };
    }
};

/// Backend-facing tool metadata. All string fields are owned by the package allocator.
pub const ContextToolDescription = struct {
    name: []const u8,
    purpose: []const u8,
    input_shape: []const u8,
    output_shape: []const u8,
    policy_constraints: []const u8,
    limits: []const u8,

    pub fn deinit(self: *ContextToolDescription, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.purpose);
        allocator.free(self.input_shape);
        allocator.free(self.output_shape);
        allocator.free(self.policy_constraints);
        allocator.free(self.limits);
        self.* = undefined;
    }

    pub fn clone(self: ContextToolDescription, allocator: std.mem.Allocator) !ContextToolDescription {
        return .{
            .name = try allocator.dupe(u8, self.name),
            .purpose = try allocator.dupe(u8, self.purpose),
            .input_shape = try allocator.dupe(u8, self.input_shape),
            .output_shape = try allocator.dupe(u8, self.output_shape),
            .policy_constraints = try allocator.dupe(u8, self.policy_constraints),
            .limits = try allocator.dupe(u8, self.limits),
        };
    }
};

pub const ContextBudget = struct {
    max_total_bytes: usize,
    used_bytes: usize,
    truncated: bool,
};

pub const AgentContextSummary = struct {
    workspace_name: []const u8,
    git_changed_files: usize,
    relevant_files: usize,
    tools: usize,
    used_bytes: usize,
    max_bytes: usize,
    truncated: bool,
};

/// AgentContextPackage owns every slice it stores. Call deinit with the same
/// allocator used to create or clone the package.
pub const AgentContextPackage = struct {
    session_id: u64,
    mode: session.AgentMode,

    system_prompt: []const u8,
    user_prompt: []const u8,

    workspace_summary: []const u8,
    git_status_summary: []const u8,
    git_diff_summary: []const u8,

    relevant_files: std.ArrayListUnmanaged(ContextFile),
    tool_descriptions: std.ArrayListUnmanaged(ContextToolDescription),
    policy_summary: []const u8,
    validation_summary: []const u8,
    notes: std.ArrayListUnmanaged([]const u8) = .empty,

    budget: ContextBudget,

    pub fn deinit(self: *AgentContextPackage, allocator: std.mem.Allocator) void {
        allocator.free(self.system_prompt);
        allocator.free(self.user_prompt);
        allocator.free(self.workspace_summary);
        allocator.free(self.git_status_summary);
        allocator.free(self.git_diff_summary);
        for (self.relevant_files.items) |*file| file.deinit(allocator);
        self.relevant_files.deinit(allocator);
        for (self.tool_descriptions.items) |*tool| tool.deinit(allocator);
        self.tool_descriptions.deinit(allocator);
        allocator.free(self.policy_summary);
        allocator.free(self.validation_summary);
        for (self.notes.items) |note| allocator.free(note);
        self.notes.deinit(allocator);
        self.* = undefined;
    }

    pub fn clone(self: AgentContextPackage, allocator: std.mem.Allocator) !AgentContextPackage {
        var copy = AgentContextPackage{
            .session_id = self.session_id,
            .mode = self.mode,
            .system_prompt = try allocator.dupe(u8, self.system_prompt),
            .user_prompt = try allocator.dupe(u8, self.user_prompt),
            .workspace_summary = try allocator.dupe(u8, self.workspace_summary),
            .git_status_summary = try allocator.dupe(u8, self.git_status_summary),
            .git_diff_summary = try allocator.dupe(u8, self.git_diff_summary),
            .relevant_files = .empty,
            .tool_descriptions = .empty,
            .policy_summary = try allocator.dupe(u8, self.policy_summary),
            .validation_summary = try allocator.dupe(u8, self.validation_summary),
            .notes = .empty,
            .budget = self.budget,
        };
        errdefer copy.deinit(allocator);
        for (self.relevant_files.items) |file| {
            try copy.relevant_files.append(allocator, try file.clone(allocator));
        }
        for (self.tool_descriptions.items) |tool| {
            try copy.tool_descriptions.append(allocator, try tool.clone(allocator));
        }
        for (self.notes.items) |note| {
            try copy.notes.append(allocator, try allocator.dupe(u8, note));
        }
        return copy;
    }

    pub fn summary(self: *const AgentContextPackage, allocator: std.mem.Allocator) !AgentContextSummary {
        return .{
            .workspace_name = try workspaceNameFromSummary(allocator, self.workspace_summary),
            .git_changed_files = countSummaryLines(self.git_status_summary),
            .relevant_files = self.relevant_files.items.len,
            .tools = self.tool_descriptions.items.len,
            .used_bytes = self.budget.used_bytes,
            .max_bytes = self.budget.max_total_bytes,
            .truncated = self.budget.truncated,
        };
    }

    pub fn formatCompactSummary(self: *const AgentContextPackage, allocator: std.mem.Allocator) ![]u8 {
        const summary_value = try self.summary(allocator);
        defer allocator.free(summary_value.workspace_name);
        return std.fmt.allocPrint(
            allocator,
            "Context packaged: workspace {s}, {d} git changes, {d} files, {d} tools, {d} KiB / {d} KiB{s}",
            .{
                summary_value.workspace_name,
                summary_value.git_changed_files,
                summary_value.relevant_files,
                summary_value.tools,
                summary_value.used_bytes / 1024,
                summary_value.max_bytes / 1024,
                if (summary_value.truncated) " (truncated)" else "",
            },
        );
    }

    pub fn formatDetails(self: *const AgentContextPackage, allocator: std.mem.Allocator) ![]u8 {
        var out = std.Io.Writer.Allocating.init(allocator);
        errdefer out.deinit();
        const writer = &out.writer;
        try writer.print("System Prompt:\n{s}\n\n", .{self.system_prompt});
        try writer.print("User Prompt:\n{s}\n\n", .{self.user_prompt});
        try writer.print("{s}\n\n", .{self.workspace_summary});
        try writer.print("Git Status:\n{s}\n\n", .{self.git_status_summary});
        try writer.print("Git Diff Summary:\n{s}\n\n", .{self.git_diff_summary});
        try writer.print("Policy:\n{s}\n\nValidation:\n{s}\n\n", .{ self.policy_summary, self.validation_summary });
        try writer.print("Tools:\n", .{});
        for (self.tool_descriptions.items) |tool| {
            try writer.print("- {s}: {s}\n  input: {s}\n  output: {s}\n  policy: {s}\n  limits: {s}\n", .{
                tool.name,
                tool.purpose,
                tool.input_shape,
                tool.output_shape,
                tool.policy_constraints,
                tool.limits,
            });
        }
        try writer.print("\nRelevant Files:\n", .{});
        for (self.relevant_files.items) |file| {
            try writer.print("- {s} ({s}){s}\n", .{ file.path, file.reason, if (file.truncated) " truncated" else "" });
        }
        if (self.notes.items.len > 0) {
            try writer.print("\nNotes:\n", .{});
            for (self.notes.items) |note| try writer.print("- {s}\n", .{note});
        }
        try writer.print("\nBudget: {d} / {d} bytes{s}\n", .{
            self.budget.used_bytes,
            self.budget.max_total_bytes,
            if (self.budget.truncated) " (truncated)" else "",
        });
        return out.toOwnedSlice();
    }
};

fn workspaceNameFromSummary(allocator: std.mem.Allocator, summary_text: []const u8) ![]const u8 {
    const prefix = "Workspace root: ";
    var lines = std.mem.splitScalar(u8, summary_text, '\n');
    const first = lines.next() orelse return allocator.dupe(u8, "workspace");
    if (!std.mem.startsWith(u8, first, prefix)) return allocator.dupe(u8, "workspace");
    const root = first[prefix.len..];
    const base = std.fs.path.basename(root);
    return allocator.dupe(u8, if (base.len > 0) base else root);
}

fn countSummaryLines(text: []const u8) usize {
    if (text.len == 0 or std.mem.eql(u8, text, "No changed files.")) return 0;
    if (std.mem.eql(u8, text, "Not a Git repository.")) return 0;
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.trim(u8, line, " \t\r").len > 0) count += 1;
    }
    return count;
}

test "context package clones and formats summary" {
    const allocator = std.testing.allocator;
    var package = AgentContextPackage{
        .session_id = 1,
        .mode = .plan,
        .system_prompt = try allocator.dupe(u8, "system"),
        .user_prompt = try allocator.dupe(u8, "user"),
        .workspace_summary = try allocator.dupe(u8, "Workspace root: /tmp/flamingo\nGit repository: yes\n"),
        .git_status_summary = try allocator.dupe(u8, "M src/main.zig\n"),
        .git_diff_summary = try allocator.dupe(u8, "M src/main.zig (1 hunks, +1 -0)\n"),
        .relevant_files = .empty,
        .tool_descriptions = .empty,
        .policy_summary = try allocator.dupe(u8, "policy"),
        .validation_summary = try allocator.dupe(u8, "validation"),
        .budget = .{ .max_total_bytes = 1024, .used_bytes = 512, .truncated = false },
    };
    defer package.deinit(allocator);
    try package.relevant_files.append(allocator, .{
        .path = try allocator.dupe(u8, "src/main.zig"),
        .reason = try allocator.dupe(u8, "test"),
        .content = try allocator.dupe(u8, "const x = 1;"),
        .truncated = false,
    });

    var cloned = try package.clone(allocator);
    defer cloned.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 1), cloned.session_id);
    try std.testing.expectEqual(@as(usize, 1), cloned.relevant_files.items.len);
    const summary_text = try cloned.formatCompactSummary(allocator);
    defer allocator.free(summary_text);
    try std.testing.expect(std.mem.indexOf(u8, summary_text, "workspace flamingo") != null);
}
