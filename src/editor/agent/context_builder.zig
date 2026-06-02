const std = @import("std");
const global_search = @import("../global_search.zig");
const policy = @import("policy.zig");
const session_mod = @import("session.zig");
const tools = @import("tools.zig");
const tool_executor = @import("tool_executor.zig");
const guard = @import("workspace_guard.zig");
const context_mod = @import("context.zig");
const prompt_templates = @import("prompt_templates.zig");

pub const ActiveBufferContext = struct {
    path: []const u8,
    content: []const u8,
};

const Candidate = struct {
    path: []u8,
    reason: []u8,
    active_content: ?[]const u8 = null,

    fn deinit(self: *Candidate, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.reason);
        self.* = undefined;
    }
};

pub const AgentContextBuilder = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    workspace_root: []const u8,
    policy_config: policy.AgentPolicyConfig,
    limits: context_mod.ContextLimits = .{},
    active_buffer: ?ActiveBufferContext = null,
    validation_commands: []const []const u8,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        workspace_root: []const u8,
        policy_config: policy.AgentPolicyConfig,
        limits: context_mod.ContextLimits,
        validation_commands: []const []const u8,
        active_buffer: ?ActiveBufferContext,
    ) AgentContextBuilder {
        return .{
            .allocator = allocator,
            .io = io,
            .workspace_root = workspace_root,
            .policy_config = policy_config,
            .limits = limits,
            .active_buffer = active_buffer,
            .validation_commands = validation_commands,
        };
    }

    pub fn build(
        self: *AgentContextBuilder,
        session: *const session_mod.AgentSession,
        prompt: []const u8,
        mode: session_mod.AgentMode,
    ) !context_mod.AgentContextPackage {
        const root = try guard.normalizeWorkspaceRoot(self.allocator, self.io, self.workspace_root);
        defer self.allocator.free(root);

        var executor = tool_executor.AgentToolExecutor.initWithPolicy(
            self.allocator,
            self.io,
            root,
            session.id,
            mode,
            self.policy_config,
            null,
        );

        var status_result = executor.execute(.{
            .id = 1,
            .session_id = session.id,
            .input = .{ .get_git_status = .{} },
        });
        defer status_result.deinit(self.allocator);
        var diff_result = executor.execute(.{
            .id = 2,
            .session_id = session.id,
            .input = .{ .get_git_diff_summary = .{} },
        });
        defer diff_result.deinit(self.allocator);

        const workspace_summary = try self.buildWorkspaceSummary(root, status_result);
        errdefer self.allocator.free(workspace_summary);
        const git_status_summary = try self.formatGitStatus(status_result);
        errdefer self.allocator.free(git_status_summary);
        const git_diff_summary = try self.formatGitDiff(diff_result);
        errdefer self.allocator.free(git_diff_summary);
        const policy_summary = try self.buildPolicySummary(mode);
        errdefer self.allocator.free(policy_summary);
        const validation_summary = try self.buildValidationSummary();
        errdefer self.allocator.free(validation_summary);

        var package = context_mod.AgentContextPackage{
            .session_id = session.id,
            .mode = mode,
            .system_prompt = try self.allocator.dupe(u8, prompt_templates.systemPromptForMode(mode)),
            .user_prompt = try self.allocator.dupe(u8, prompt),
            .workspace_summary = workspace_summary,
            .git_status_summary = git_status_summary,
            .git_diff_summary = git_diff_summary,
            .relevant_files = .empty,
            .tool_descriptions = .empty,
            .policy_summary = policy_summary,
            .validation_summary = validation_summary,
            .budget = .{
                .max_total_bytes = self.limits.max_context_total_bytes,
                .used_bytes = 0,
                .truncated = false,
            },
        };
        errdefer package.deinit(self.allocator);

        try self.appendToolDescriptions(&package.tool_descriptions);
        package.budget.used_bytes = basePackageBytes(&package);
        if (package.budget.used_bytes > package.budget.max_total_bytes) package.budget.truncated = true;

        var candidates = std.ArrayListUnmanaged(Candidate).empty;
        defer {
            for (candidates.items) |*candidate| candidate.deinit(self.allocator);
            candidates.deinit(self.allocator);
        }
        try self.collectPromptPathCandidates(prompt, &candidates);
        try self.collectSearchCandidates(session.id, mode, root, prompt, &candidates);
        try self.collectGitCandidates(status_result, &candidates);
        try self.collectActiveBufferCandidate(root, &candidates);

        var engine = policy.AgentPolicyEngine.init(self.allocator, self.io, root, self.policy_config);
        var policy_state = policy.AgentPolicySessionState{ .id = session.id, .mode = mode };
        for (candidates.items) |candidate| {
            if (package.relevant_files.items.len >= self.limits.max_context_files) break;
            try self.tryAppendContextFile(&package, &engine, &policy_state, root, candidate);
        }

        return package;
    }

    fn buildWorkspaceSummary(self: *AgentContextBuilder, root: []const u8, status_result: tools.AgentToolResult) ![]const u8 {
        var out = std.Io.Writer.Allocating.init(self.allocator);
        errdefer out.deinit();
        const writer = &out.writer;
        try writer.print("Workspace root: {s}\n", .{root});
        const is_git = if (status_result.ok and status_result.output != null and std.meta.activeTag(status_result.output.?) == .get_git_status)
            !status_result.output.?.get_git_status.non_git
        else
            false;
        try writer.print("Git repository: {s}\n", .{if (is_git) "yes" else "no"});
        try writer.print("Detected project hints:\n", .{});
        var found = false;
        found = try self.appendHint(writer, root, "build.zig", "Zig project") or found;
        found = try self.appendHint(writer, root, "go.mod", "Go project") or found;
        found = try self.appendHint(writer, root, "package.json", "Node project") or found;
        found = try self.appendHint(writer, root, "Cargo.toml", "Rust project") or found;
        if (!found) try writer.print("- none\n", .{});
        return out.toOwnedSlice();
    }

    fn appendHint(self: *AgentContextBuilder, writer: anytype, root: []const u8, file_name: []const u8, label: []const u8) !bool {
        const path = try std.fs.path.join(self.allocator, &.{ root, file_name });
        defer self.allocator.free(path);
        std.Io.Dir.cwd().access(self.io, path, .{}) catch return false;
        try writer.print("- {s} if {s} exists\n", .{ label, file_name });
        return true;
    }

    fn formatGitStatus(self: *AgentContextBuilder, result: tools.AgentToolResult) ![]const u8 {
        if (!result.ok or result.output == null or std.meta.activeTag(result.output.?) != .get_git_status) {
            return self.allocator.dupe(u8, "Git status unavailable.");
        }
        const output = result.output.?.get_git_status;
        if (output.non_git) return self.allocator.dupe(u8, "Not a Git repository.");
        if (output.entries.len == 0) return self.allocator.dupe(u8, "No changed files.");
        var out = std.Io.Writer.Allocating.init(self.allocator);
        errdefer out.deinit();
        const writer = &out.writer;
        for (output.entries) |entry| {
            try writer.print("{s} {s}\n", .{ statusLabel(entry.state), entry.path });
        }
        return out.toOwnedSlice();
    }

    fn formatGitDiff(self: *AgentContextBuilder, result: tools.AgentToolResult) ![]const u8 {
        if (!result.ok or result.output == null or std.meta.activeTag(result.output.?) != .get_git_diff_summary) {
            return self.allocator.dupe(u8, "Git diff summary unavailable.");
        }
        const output = result.output.?.get_git_diff_summary;
        if (output.non_git) return self.allocator.dupe(u8, "Not a Git repository.");
        if (output.entries.len == 0) return self.allocator.dupe(u8, "No diff hunks.");
        var out = std.Io.Writer.Allocating.init(self.allocator);
        errdefer out.deinit();
        const writer = &out.writer;
        for (output.entries) |entry| {
            try writer.print("{s} {s} ({d} hunks, +{d} -{d}{s})\n", .{
                entry.kind.label(),
                entry.path,
                entry.hunks,
                entry.added,
                entry.removed,
                if (entry.binary) ", binary" else "",
            });
        }
        if (output.truncated) try writer.print("Diff summary truncated by git service.\n", .{});
        return out.toOwnedSlice();
    }

    fn buildPolicySummary(self: *AgentContextBuilder, mode: session_mod.AgentMode) ![]const u8 {
        var out = std.Io.Writer.Allocating.init(self.allocator);
        errdefer out.deinit();
        const writer = &out.writer;
        try writer.print("Mode: {s}\n", .{mode.label()});
        switch (mode) {
            .plan => try writer.print("Allowed: list_files, read_file, search_text, get_git_status, get_git_diff_summary\nDenied: patch proposals, patch application, validation tasks\n", .{}),
            .implementation => try writer.print("Allowed: read-only tools, patch proposals, reviewed patch application, configured validation tasks\n", .{}),
        }
        try writer.print("Denied path segments:", .{});
        for (self.policy_config.deny_paths) |path| try writer.print(" {s}", .{path});
        try writer.print("\nPatch application approval: {s}\nValidation approval: {s}\n", .{
            if (self.policy_config.require_approval_for_patch_apply) "required" else "not required",
            if (self.policy_config.require_approval_for_validation) "required" else "not required",
        });
        return out.toOwnedSlice();
    }

    fn buildValidationSummary(self: *AgentContextBuilder) ![]const u8 {
        var out = std.Io.Writer.Allocating.init(self.allocator);
        errdefer out.deinit();
        const writer = &out.writer;
        try writer.print("Validation must run through the Task Runner.\nConfigured commands:\n", .{});
        for (self.validation_commands) |command| try writer.print("- {s}\n", .{command});
        return out.toOwnedSlice();
    }

    fn appendToolDescriptions(self: *AgentContextBuilder, out: *std.ArrayListUnmanaged(context_mod.ContextToolDescription)) !void {
        try self.appendTool(out, "list_files", "List files under a workspace-relative directory.", "{ root_relative_path?: string, max_results?: number }", "{ entries: [{ path, kind, size? }], truncated: bool }", "Workspace-only; denied paths are omitted.", "Default max_results 200.");
        try self.appendTool(out, "read_file", "Read a text file from the workspace.", "{ path: string, start_line?: number, max_lines?: number }", "{ path, content, start_line, line_count, truncated_bytes, truncated_lines, binary }", "Workspace-only; denied paths, binary files, and oversized files are rejected.", "Policy max_file_read_bytes applies.");
        try self.appendTool(out, "search_text", "Search workspace text files for a literal query.", "{ query: string, max_results?: number }", "{ matches: [{ path, line, preview }], truncated: bool }", "Workspace-only; generated/denied directories are skipped.", "Search result policy cap applies.");
        try self.appendTool(out, "get_git_status", "Summarize changed files in the current git workspace.", "{}", "{ branch?, entries: [{ path, state }], non_git: bool }", "Read-only git metadata.", "No full file contents.");
        try self.appendTool(out, "get_git_diff_summary", "Summarize changed files and hunk counts without full diffs.", "{}", "{ entries: [{ path, kind, hunks, added, removed, binary }], truncated, non_git }", "Read-only git metadata.", "Full diffs are not dumped by default.");
        try self.appendTool(out, "create_patch_proposal", "Create a patch proposal for user review.", "{ file_path: string, description: string, unified_diff: string }", "{ proposal_id, review_status }", "Not allowed in Plan mode; proposals require review before application.", "Does not write files directly.");
    }

    fn appendTool(self: *AgentContextBuilder, out: *std.ArrayListUnmanaged(context_mod.ContextToolDescription), name: []const u8, purpose: []const u8, input_shape: []const u8, output_shape: []const u8, policy_constraints: []const u8, limits: []const u8) !void {
        try out.append(self.allocator, .{
            .name = try self.allocator.dupe(u8, name),
            .purpose = try self.allocator.dupe(u8, purpose),
            .input_shape = try self.allocator.dupe(u8, input_shape),
            .output_shape = try self.allocator.dupe(u8, output_shape),
            .policy_constraints = try self.allocator.dupe(u8, policy_constraints),
            .limits = try self.allocator.dupe(u8, limits),
        });
    }

    fn collectPromptPathCandidates(self: *AgentContextBuilder, prompt: []const u8, out: *std.ArrayListUnmanaged(Candidate)) !void {
        var it = std.mem.tokenizeAny(u8, prompt, " \t\r\n\"'`()[]{}<>,;");
        while (it.next()) |raw| {
            const token = trimPromptPathToken(raw);
            if (!looksLikePath(token)) continue;
            try self.appendCandidate(out, token, "mentioned in prompt", null);
        }
    }

    fn collectSearchCandidates(self: *AgentContextBuilder, session_id: u64, mode: session_mod.AgentMode, root: []const u8, prompt: []const u8, out: *std.ArrayListUnmanaged(Candidate)) !void {
        const query = firstSearchKeyword(prompt) orelse return;
        var executor = tool_executor.AgentToolExecutor.initWithPolicy(self.allocator, self.io, root, session_id, mode, self.policy_config, null);
        var result = executor.execute(.{
            .id = 3,
            .session_id = session_id,
            .input = .{ .search_text = .{ .query = query, .max_results = 12 } },
        });
        defer result.deinit(self.allocator);
        if (!result.ok or result.output == null or std.meta.activeTag(result.output.?) != .search_text) return;
        for (result.output.?.search_text.matches) |match| {
            try self.appendCandidate(out, match.path, "matched prompt keywords", null);
        }
    }

    fn collectGitCandidates(self: *AgentContextBuilder, result: tools.AgentToolResult, out: *std.ArrayListUnmanaged(Candidate)) !void {
        if (!result.ok or result.output == null or std.meta.activeTag(result.output.?) != .get_git_status) return;
        for (result.output.?.get_git_status.entries) |entry| {
            try self.appendCandidate(out, entry.path, "changed in git status", null);
        }
    }

    fn collectActiveBufferCandidate(self: *AgentContextBuilder, root: []const u8, out: *std.ArrayListUnmanaged(Candidate)) !void {
        const active = self.active_buffer orelse return;
        const absolute = guard.resolveWorkspacePath(self.allocator, self.io, root, active.path) catch return;
        defer self.allocator.free(absolute);
        try self.appendCandidate(out, guard.relativePath(root, absolute), "active open buffer", active.content);
    }

    fn appendCandidate(self: *AgentContextBuilder, out: *std.ArrayListUnmanaged(Candidate), path: []const u8, reason: []const u8, active_content: ?[]const u8) !void {
        if (path.len == 0) return;
        for (out.items) |existing| {
            if (std.mem.eql(u8, existing.path, path)) return;
        }
        try out.append(self.allocator, .{
            .path = try self.allocator.dupe(u8, path),
            .reason = try self.allocator.dupe(u8, reason),
            .active_content = active_content,
        });
    }

    fn tryAppendContextFile(
        self: *AgentContextBuilder,
        package: *context_mod.AgentContextPackage,
        engine: *policy.AgentPolicyEngine,
        policy_state: *policy.AgentPolicySessionState,
        root: []const u8,
        candidate: Candidate,
    ) !void {
        if (isPackagingDenied(candidate.path)) {
            try self.appendNote(package, "Skipped {s} because it may contain secrets or generated content.", .{candidate.path});
            return;
        }
        const absolute = guard.resolveWorkspacePath(self.allocator, self.io, root, candidate.path) catch |err| {
            try self.appendNote(package, "Skipped {s}: {s}.", .{ candidate.path, workspaceErrorMessage(err) });
            return;
        };
        defer self.allocator.free(absolute);
        const rel = guard.relativePath(root, absolute);

        const decision = engine.evaluate(policy_state, .{
            .session_id = package.session_id,
            .capability = .read_file,
            .path = rel,
        });
        if (decision.decision != .allow) {
            try self.appendNote(package, "Skipped {s}: {s}.", .{ rel, decision.message orelse "denied by policy" });
            return;
        }

        const source = if (candidate.active_content) |content|
            try self.allocator.dupe(u8, content)
        else
            try std.Io.Dir.cwd().readFileAlloc(self.io, absolute, self.allocator, std.Io.Limit.limited(self.policy_config.max_file_read_bytes));
        defer self.allocator.free(source);
        if (global_search.isLikelyBinary(source)) {
            try self.appendNote(package, "Skipped {s}: binary file.", .{rel});
            return;
        }
        if (package.budget.used_bytes >= package.budget.max_total_bytes) {
            package.budget.truncated = true;
            try self.appendNote(package, "Context budget exhausted before {s}.", .{rel});
            return;
        }
        const remaining_total = package.budget.max_total_bytes - package.budget.used_bytes;
        const cap = @min(self.limits.max_context_file_bytes, remaining_total);
        const take = @min(source.len, cap);
        const truncated = take < source.len;
        const content = try self.allocator.dupe(u8, source[0..take]);
        errdefer self.allocator.free(content);
        try package.relevant_files.append(self.allocator, .{
            .path = try self.allocator.dupe(u8, rel),
            .reason = try self.allocator.dupe(u8, candidate.reason),
            .content = content,
            .truncated = truncated,
        });
        package.budget.used_bytes += content.len;
        if (truncated) {
            package.budget.truncated = true;
            try self.appendNote(package, "{s} was truncated after {d} bytes.", .{ rel, take });
        }
    }

    fn appendNote(self: *AgentContextBuilder, package: *context_mod.AgentContextPackage, comptime fmt: []const u8, args: anytype) !void {
        const note = try std.fmt.allocPrint(self.allocator, fmt, args);
        errdefer self.allocator.free(note);
        try package.notes.append(self.allocator, note);
        package.budget.used_bytes += note.len;
        if (package.budget.used_bytes > package.budget.max_total_bytes) package.budget.truncated = true;
    }
};

fn basePackageBytes(package: *const context_mod.AgentContextPackage) usize {
    var total: usize = 0;
    total += package.system_prompt.len + package.user_prompt.len;
    total += package.workspace_summary.len + package.git_status_summary.len + package.git_diff_summary.len;
    total += package.policy_summary.len + package.validation_summary.len;
    for (package.tool_descriptions.items) |tool| {
        total += tool.name.len + tool.purpose.len + tool.input_shape.len + tool.output_shape.len + tool.policy_constraints.len + tool.limits.len;
    }
    return total;
}

fn statusLabel(state: @import("../git_status.zig").FileState) []const u8 {
    return switch (state) {
        .modified => "M",
        .untracked => "A",
        .ignored => "I",
    };
}

fn looksLikePath(token: []const u8) bool {
    if (token.len == 0) return false;
    if (std.mem.indexOfScalar(u8, token, '/') != null) return true;
    const exts = [_][]const u8{ ".zig", ".md", ".toml", ".json", ".go", ".rs", ".c", ".h", ".cpp", ".hpp", ".js", ".ts", ".tsx", ".jsx", ".env", ".pem", ".key" };
    for (exts) |ext| {
        if (std.mem.endsWith(u8, token, ext)) return true;
    }
    return false;
}

fn trimPromptPathToken(raw: []const u8) []const u8 {
    var token = std.mem.trim(u8, raw, ":!?");
    while (token.len > 0 and token[token.len - 1] == '.') token = token[0 .. token.len - 1];
    return token;
}

fn firstSearchKeyword(prompt: []const u8) ?[]const u8 {
    var it = std.mem.tokenizeAny(u8, prompt, " \t\r\n\"'`()[]{}<>,;.:!?/\\");
    while (it.next()) |token| {
        if (token.len >= 4 and isMostlyIdentifier(token)) return token;
    }
    return null;
}

fn isMostlyIdentifier(token: []const u8) bool {
    for (token) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '-') return false;
    }
    return true;
}

fn isPackagingDenied(path: []const u8) bool {
    const base = std.fs.path.basename(path);
    if (std.mem.eql(u8, base, ".env")) return true;
    if (std.mem.endsWith(u8, base, ".pem") or std.mem.endsWith(u8, base, ".key")) return true;
    var it = std.mem.tokenizeAny(u8, path, "/\\");
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, ".git") or
            std.mem.eql(u8, part, "node_modules") or
            std.mem.eql(u8, part, "zig-out") or
            std.mem.eql(u8, part, ".zig-cache") or
            std.mem.eql(u8, part, "target") or
            std.mem.eql(u8, part, "dist") or
            std.mem.eql(u8, part, "build"))
            return true;
    }
    return false;
}

fn workspaceErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.OutsideWorkspace => "outside workspace",
        error.GitInternalsForbidden => ".git internals are denied",
        error.EmptyWorkspaceRoot => "empty workspace root",
        error.EmptyPath => "empty path",
        error.FileNotFound => "file not found",
        else => @errorName(err),
    };
}

test "context builder extracts prompt paths and excludes secrets" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/main.zig", .data = "pub fn main() void {}\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = ".env", .data = "SECRET=1\n" });
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);

    var session = session_mod.AgentSession{
        .id = 7,
        .mode = .plan,
        .status = .running,
        .prompt = try allocator.dupe(u8, "read src/main.zig and .env"),
        .started_at_ms = 0,
    };
    defer session.deinit(allocator);
    var builder = AgentContextBuilder.init(allocator, io, root, .{ .max_file_read_bytes = 4096 }, .{}, &.{"zig build test"}, null);
    var package = try builder.build(&session, session.prompt, .plan);
    defer package.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), package.relevant_files.items.len);
    try std.testing.expectEqualStrings("src/main.zig", package.relevant_files.items[0].path);
    try std.testing.expect(package.notes.items.len >= 1);
}

test "context builder prompt path trimming preserves dotfiles" {
    try std.testing.expectEqualStrings(".env", trimPromptPathToken(".env"));
    try std.testing.expectEqualStrings("src/main.zig", trimPromptPathToken("src/main.zig."));
}

test "context builder rejects git internals keys outside workspace and binary files" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, ".git");
    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.writeFile(io, .{ .sub_path = ".git/config", .data = "private\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/key.pem", .data = "private\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/key.key", .data = "private\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/blob.zig", .data = "a\x00b" });
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);

    var session = session_mod.AgentSession{
        .id = 10,
        .mode = .plan,
        .status = .running,
        .prompt = try allocator.dupe(u8, "read .git/config src/key.pem src/key.key src/blob.zig ../outside.zig"),
        .started_at_ms = 0,
    };
    defer session.deinit(allocator);
    var builder = AgentContextBuilder.init(allocator, io, root, .{ .max_file_read_bytes = 4096 }, .{}, &.{"zig build test"}, null);
    var package = try builder.build(&session, session.prompt, .plan);
    defer package.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), package.relevant_files.items.len);
    try std.testing.expect(package.notes.items.len >= 4);
}

test "context builder truncates files and total budget" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "src");
    var data: [128]u8 = undefined;
    @memset(&data, 'x');
    try tmp.dir.writeFile(io, .{ .sub_path = "src/big.zig", .data = &data });
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);
    var session = session_mod.AgentSession{
        .id = 8,
        .mode = .plan,
        .status = .running,
        .prompt = try allocator.dupe(u8, "read src/big.zig"),
        .started_at_ms = 0,
    };
    defer session.deinit(allocator);
    var builder = AgentContextBuilder.init(
        allocator,
        io,
        root,
        .{ .max_file_read_bytes = 1024 },
        .{ .max_context_files = 8, .max_context_file_bytes = 32, .max_context_total_bytes = 4096 },
        &.{"zig build test"},
        null,
    );
    var package = try builder.build(&session, session.prompt, .plan);
    defer package.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), package.relevant_files.items.len);
    try std.testing.expect(package.relevant_files.items[0].truncated);
    try std.testing.expect(package.budget.truncated);
}

test "context builder includes active buffer content" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/live.zig", .data = "old\n" });
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);
    var session = session_mod.AgentSession{
        .id = 9,
        .mode = .plan,
        .status = .running,
        .prompt = try allocator.dupe(u8, "live"),
        .started_at_ms = 0,
    };
    defer session.deinit(allocator);
    var builder = AgentContextBuilder.init(
        allocator,
        io,
        root,
        .{ .max_file_read_bytes = 1024 },
        .{},
        &.{"zig build test"},
        .{ .path = "src/live.zig", .content = "unsaved\n" },
    );
    var package = try builder.build(&session, session.prompt, .plan);
    defer package.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), package.relevant_files.items.len);
    try std.testing.expectEqualStrings("unsaved\n", package.relevant_files.items[0].content);
}
