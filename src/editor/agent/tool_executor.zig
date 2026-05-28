const std = @import("std");
const global_search = @import("../global_search.zig");
const git_status = @import("../git_status.zig");
const workspace_diff = @import("../git/workspace_diff.zig");
const audit = @import("audit.zig");
const event_queue = @import("../runtime/event_queue.zig");
const policy = @import("policy.zig");
const session = @import("session.zig");
const tools = @import("tools.zig");
const guard = @import("workspace_guard.zig");

pub const AgentToolExecutor = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    workspace_root: []const u8,
    policy_config: policy.AgentPolicyConfig = .{},
    policy_state: policy.AgentPolicySessionState,
    audit_queue: ?*event_queue.EventQueue = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, workspace_root: []const u8) AgentToolExecutor {
        return .{
            .allocator = allocator,
            .io = io,
            .workspace_root = workspace_root,
            .policy_state = .{ .id = 0, .mode = .plan },
        };
    }

    pub fn initWithPolicy(
        allocator: std.mem.Allocator,
        io: std.Io,
        workspace_root: []const u8,
        session_id: u64,
        mode: session.AgentMode,
        policy_config: policy.AgentPolicyConfig,
        audit_queue: ?*event_queue.EventQueue,
    ) AgentToolExecutor {
        return .{
            .allocator = allocator,
            .io = io,
            .workspace_root = workspace_root,
            .policy_config = policy_config,
            .policy_state = .{ .id = session_id, .mode = mode },
            .audit_queue = audit_queue,
        };
    }

    pub fn execute(self: *AgentToolExecutor, call: tools.AgentToolCall) tools.AgentToolResult {
        if (self.policy_state.id == 0) self.policy_state.id = call.session_id;
        const requested_text = tools.formatToolCall(self.allocator, call) catch null;
        defer if (requested_text) |text| self.allocator.free(text);
        auditEvent(self, call.session_id, .tool_requested, requested_text orelse call.name().label());
        var engine = policy.AgentPolicyEngine.init(self.allocator, self.io, self.workspace_root, self.policy_config);
        const request = policyRequestFromCall(call);
        const decision = engine.evaluate(&self.policy_state, request);
        switch (decision.decision) {
            .allow => auditEvent(self, call.session_id, .tool_allowed, decision.message orelse "allowed"),
            .deny => {
                const message = decision.message orelse "denied by agent policy";
                auditEvent(self, call.session_id, .tool_denied, message);
                auditEvent(self, call.session_id, .policy_violation, message);
                return .{
                    .call_id = call.id,
                    .ok = false,
                    .error_message = std.fmt.allocPrint(self.allocator, "{s}", .{message}) catch null,
                };
            },
            .require_user_approval => {
                const message = decision.message orelse "approval required";
                auditEvent(self, call.session_id, .approval_requested, message);
                return .{
                    .call_id = call.id,
                    .ok = false,
                    .error_message = std.fmt.allocPrint(self.allocator, "{s}", .{message}) catch null,
                };
            },
        }

        const output = self.executeOutput(call.input) catch |err| {
            auditEvent(self, call.session_id, .tool_failed, @errorName(err));
            return .{
                .call_id = call.id,
                .ok = false,
                .error_message = std.fmt.allocPrint(self.allocator, "{s}", .{@errorName(err)}) catch null,
            };
        };
        if (std.meta.activeTag(output) == .search_text) {
            const limit_result = engine.recordSearchResults(&self.policy_state, output.search_text.matches.len);
            if (limit_result.decision != .allow) {
                var owned_output = output;
                owned_output.deinit(self.allocator);
                const message = limit_result.message orelse "search result limit reached";
                auditEvent(self, call.session_id, .tool_denied, message);
                auditEvent(self, call.session_id, .policy_violation, message);
                return .{
                    .call_id = call.id,
                    .ok = false,
                    .error_message = std.fmt.allocPrint(self.allocator, "{s}", .{message}) catch null,
                };
            }
        }
        auditEvent(self, call.session_id, .tool_completed, "tool completed");
        return .{
            .call_id = call.id,
            .ok = true,
            .output = output,
        };
    }

    fn executeOutput(self: *AgentToolExecutor, input: tools.AgentToolInput) !tools.AgentToolOutput {
        return switch (input) {
            .list_files => |payload| .{ .list_files = try self.listFiles(payload) },
            .read_file => |payload| .{ .read_file = try self.readFile(payload) },
            .search_text => |payload| .{ .search_text = try self.searchText(payload) },
            .get_git_status => .{ .get_git_status = try self.getGitStatus() },
            .get_git_diff_summary => .{ .get_git_diff_summary = try self.getGitDiffSummary() },
        };
    }

    fn normalizeRoot(self: *AgentToolExecutor) ![]u8 {
        return guard.normalizeWorkspaceRoot(self.allocator, self.io, self.workspace_root);
    }

    fn listFiles(self: *AgentToolExecutor, input: tools.ListFilesInput) !tools.ListFilesOutput {
        const path = input.root_relative_path orelse ".";
        const root = try self.normalizeRoot();
        defer self.allocator.free(root);

        const start = try guard.resolveWorkspacePath(self.allocator, self.io, root, path);
        defer self.allocator.free(start);

        var entries = std.ArrayListUnmanaged(tools.ListFileEntry).empty;
        errdefer {
            for (entries.items) |*entry| entry.deinit(self.allocator);
            entries.deinit(self.allocator);
        }

        var truncated = false;
        try self.scanFiles(root, start, @max(input.max_results, 1), &entries, &truncated);
        return .{
            .entries = try entries.toOwnedSlice(self.allocator),
            .truncated = truncated,
        };
    }

    fn scanFiles(
        self: *AgentToolExecutor,
        root: []const u8,
        dir_path: []const u8,
        max_results: usize,
        entries: *std.ArrayListUnmanaged(tools.ListFileEntry),
        truncated: *bool,
    ) !void {
        if (entries.items.len >= max_results) {
            truncated.* = true;
            return;
        }

        var dir = std.Io.Dir.cwd().openDir(self.io, dir_path, .{ .iterate = true }) catch return;
        defer dir.close(self.io);

        var it = dir.iterate();
        while (true) {
            const maybe_entry = it.next(self.io) catch return;
            const entry = maybe_entry orelse break;
            if (shouldIgnoreName(entry.name)) continue;

            if (entries.items.len >= max_results) {
                truncated.* = true;
                return;
            }

            const absolute_path = try std.fs.path.join(self.allocator, &.{ dir_path, entry.name });
            defer self.allocator.free(absolute_path);
            if (!guard.isPathInsideRoot(absolute_path, root) or guard.hasGitSegment(guard.relativePath(root, absolute_path))) continue;

            const rel = guard.relativePath(root, absolute_path);
            switch (entry.kind) {
                .directory => {
                    try entries.append(self.allocator, .{
                        .path = try self.allocator.dupe(u8, rel),
                        .kind = .directory,
                    });
                    try self.scanFiles(root, absolute_path, max_results, entries, truncated);
                    if (truncated.*) return;
                },
                .file => {
                    const stat = std.Io.Dir.cwd().statFile(self.io, absolute_path, .{}) catch null;
                    try entries.append(self.allocator, .{
                        .path = try self.allocator.dupe(u8, rel),
                        .kind = .file,
                        .size = if (stat) |s| s.size else null,
                    });
                },
                else => {},
            }
        }
    }

    fn readFile(self: *AgentToolExecutor, input: tools.ReadFileInput) !tools.ReadFileOutput {
        const root = try self.normalizeRoot();
        defer self.allocator.free(root);

        const absolute_path = try guard.resolveWorkspacePath(self.allocator, self.io, root, input.path);
        defer self.allocator.free(absolute_path);
        const rel = guard.relativePath(root, absolute_path);

        const stat = try std.Io.Dir.cwd().statFile(self.io, absolute_path, .{});
        if (stat.kind != .file) return error.ExpectedFile;
        if (stat.size > self.policy_config.max_file_read_bytes) return error.FileTooLarge;

        const contents = try std.Io.Dir.cwd().readFileAlloc(
            self.io,
            absolute_path,
            self.allocator,
            std.Io.Limit.limited(self.policy_config.max_file_read_bytes),
        );
        defer self.allocator.free(contents);

        if (global_search.isLikelyBinary(contents)) {
            return .{
                .path = try self.allocator.dupe(u8, rel),
                .content = try self.allocator.dupe(u8, "[binary file omitted]"),
                .start_line = input.start_line orelse 1,
                .line_count = 0,
                .binary = true,
            };
        }

        const start_line = @max(input.start_line orelse 1, 1);
        const max_lines = @min(input.max_lines orelse tools.max_file_read_lines, tools.max_file_read_lines);

        var out = std.ArrayListUnmanaged(u8).empty;
        errdefer out.deinit(self.allocator);

        var line_no: usize = 1;
        var returned: usize = 0;
        var truncated_lines = false;
        var lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |raw_line| : (line_no += 1) {
            if (line_no < start_line) continue;
            if (returned >= max_lines) {
                truncated_lines = true;
                break;
            }

            var line = raw_line;
            if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
            if (returned > 0) try out.append(self.allocator, '\n');
            try out.appendSlice(self.allocator, line);
            returned += 1;
        }

        return .{
            .path = try self.allocator.dupe(u8, rel),
            .content = try out.toOwnedSlice(self.allocator),
            .start_line = start_line,
            .line_count = returned,
            .truncated_lines = truncated_lines,
        };
    }

    fn searchText(self: *AgentToolExecutor, input: tools.SearchTextInput) !tools.SearchTextOutput {
        var matches = std.ArrayListUnmanaged(tools.SearchMatch).empty;
        errdefer {
            for (matches.items) |*match| match.deinit(self.allocator);
            matches.deinit(self.allocator);
        }
        if (input.query.len == 0) {
            return .{ .matches = try matches.toOwnedSlice(self.allocator) };
        }

        const root = try self.normalizeRoot();
        defer self.allocator.free(root);

        var truncated = false;
        try self.searchDirectory(root, root, input.query, @max(input.max_results, 1), &matches, &truncated);
        return .{
            .matches = try matches.toOwnedSlice(self.allocator),
            .truncated = truncated,
        };
    }

    fn searchDirectory(
        self: *AgentToolExecutor,
        root: []const u8,
        dir_path: []const u8,
        query: []const u8,
        max_results: usize,
        matches: *std.ArrayListUnmanaged(tools.SearchMatch),
        truncated: *bool,
    ) !void {
        if (matches.items.len >= max_results) {
            truncated.* = true;
            return;
        }

        var dir = std.Io.Dir.cwd().openDir(self.io, dir_path, .{ .iterate = true }) catch return;
        defer dir.close(self.io);

        var it = dir.iterate();
        while (true) {
            const maybe_entry = it.next(self.io) catch return;
            const entry = maybe_entry orelse break;
            if (shouldIgnoreName(entry.name)) continue;

            const absolute_path = try std.fs.path.join(self.allocator, &.{ dir_path, entry.name });
            defer self.allocator.free(absolute_path);
            if (!guard.isPathInsideRoot(absolute_path, root) or guard.hasGitSegment(guard.relativePath(root, absolute_path))) continue;

            switch (entry.kind) {
                .directory => {
                    try self.searchDirectory(root, absolute_path, query, max_results, matches, truncated);
                    if (truncated.*) return;
                },
                .file => {
                    try self.searchFile(root, absolute_path, query, max_results, matches, truncated);
                    if (truncated.*) return;
                },
                else => {},
            }
        }
    }

    fn searchFile(
        self: *AgentToolExecutor,
        root: []const u8,
        absolute_path: []const u8,
        query: []const u8,
        max_results: usize,
        matches: *std.ArrayListUnmanaged(tools.SearchMatch),
        truncated: *bool,
    ) !void {
        const stat = std.Io.Dir.cwd().statFile(self.io, absolute_path, .{}) catch return;
        if (stat.kind != .file or stat.size > tools.max_search_file_bytes) return;

        const contents = std.Io.Dir.cwd().readFileAlloc(
            self.io,
            absolute_path,
            self.allocator,
            std.Io.Limit.limited(tools.max_search_file_bytes),
        ) catch return;
        defer self.allocator.free(contents);
        if (global_search.isLikelyBinary(contents)) return;

        const rel = guard.relativePath(root, absolute_path);
        var line_no: usize = 1;
        var lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |raw_line| : (line_no += 1) {
            if (matches.items.len >= max_results) {
                truncated.* = true;
                return;
            }
            var line = raw_line;
            if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
            if (!global_search.matchesLiteralAsciiInsensitive(line, query)) continue;
            try matches.append(self.allocator, .{
                .path = try self.allocator.dupe(u8, rel),
                .line = line_no,
                .preview = try self.allocator.dupe(u8, line[0..@min(line.len, tools.max_line_preview_bytes)]),
            });
        }
    }

    fn getGitStatus(self: *AgentToolExecutor) !tools.GitStatusOutput {
        const root = try self.normalizeRoot();
        defer self.allocator.free(root);

        var snapshot = try git_status.Snapshot.loadFromRoot(self.allocator, self.io, root);
        defer snapshot.deinit();

        var entries = std.ArrayListUnmanaged(tools.GitStatusEntry).empty;
        errdefer {
            for (entries.items) |*entry| entry.deinit(self.allocator);
            entries.deinit(self.allocator);
        }

        var it = snapshot.entries.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* == .ignored) continue;
            try entries.append(self.allocator, .{
                .path = try self.allocator.dupe(u8, entry.key_ptr.*),
                .state = entry.value_ptr.*,
            });
        }

        return .{
            .branch = if (snapshot.branch) |branch| try self.allocator.dupe(u8, branch) else null,
            .entries = try entries.toOwnedSlice(self.allocator),
            .non_git = snapshot.root_path == null,
        };
    }

    fn getGitDiffSummary(self: *AgentToolExecutor) !tools.GitDiffSummaryOutput {
        const root = try self.normalizeRoot();
        defer self.allocator.free(root);

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        const diff = workspace_diff.loadWorkspaceDiff(arena.allocator(), self.allocator, self.io, root) catch |err| switch (err) {
            error.NotGitRepository => return .{
                .entries = try self.allocator.alloc(tools.GitDiffSummaryEntry, 0),
                .non_git = true,
            },
            else => return err,
        };

        var entries = std.ArrayListUnmanaged(tools.GitDiffSummaryEntry).empty;
        errdefer {
            for (entries.items) |*entry| entry.deinit(self.allocator);
            entries.deinit(self.allocator);
        }
        for (diff.files.items) |file| {
            var added: usize = 0;
            var removed: usize = 0;
            for (file.hunks.items) |hunk| {
                for (hunk.lines.items) |line| switch (line.kind) {
                    .added => added += 1,
                    .removed => removed += 1,
                    else => {},
                };
            }
            try entries.append(self.allocator, .{
                .path = try self.allocator.dupe(u8, file.path),
                .kind = file.kind,
                .hunks = file.hunks.items.len,
                .added = added,
                .removed = removed,
                .binary = file.binary,
            });
        }

        return .{
            .entries = try entries.toOwnedSlice(self.allocator),
            .truncated = diff.truncated,
        };
    }
};

fn policyRequestFromCall(call: tools.AgentToolCall) policy.AgentPolicyRequest {
    return switch (call.input) {
        .list_files => |input| .{
            .session_id = call.session_id,
            .capability = .list_files,
            .tool_name = .list_files,
            .path = input.root_relative_path orelse ".",
        },
        .read_file => |input| .{
            .session_id = call.session_id,
            .capability = .read_file,
            .tool_name = .read_file,
            .path = input.path,
        },
        .search_text => .{
            .session_id = call.session_id,
            .capability = .search_text,
            .tool_name = .search_text,
        },
        .get_git_status => .{
            .session_id = call.session_id,
            .capability = .get_git_status,
            .tool_name = .get_git_status,
        },
        .get_git_diff_summary => .{
            .session_id = call.session_id,
            .capability = .get_git_diff_summary,
            .tool_name = .get_git_diff_summary,
        },
    };
}

fn auditEvent(self: *AgentToolExecutor, session_id: u64, kind: audit.AgentAuditEventKind, message: []const u8) void {
    const queue = self.audit_queue orelse return;
    const owned = self.allocator.dupe(u8, message) catch return;
    queue.push(.{ .agent_audit_event = .{
        .id = session_id,
        .kind = kind,
        .message = owned,
        .timestamp_ms = session.nowMs(self.io),
    } }) catch self.allocator.free(owned);
}

fn shouldIgnoreName(name: []const u8) bool {
    if (global_search.shouldIgnoreName(name)) return true;
    const ignored = [_][]const u8{ "dist", "build" };
    for (ignored) |candidate| {
        if (std.mem.eql(u8, name, candidate)) return true;
    }
    return false;
}

test "agent read_file rejects git internals" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, ".git");
    try tmp.dir.writeFile(io, .{ .sub_path = ".git/config", .data = "" });

    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);

    var executor = AgentToolExecutor.init(allocator, io, root);
    var result = executor.execute(.{
        .id = 1,
        .session_id = 1,
        .input = .{ .read_file = .{ .path = ".git/config" } },
    });
    defer result.deinit(allocator);

    try std.testing.expect(!result.ok);
}

test "agent read_file applies line cap" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "notes.txt", .data = "one\ntwo\nthree\n" });
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);

    var executor = AgentToolExecutor.init(allocator, io, root);
    var result = executor.execute(.{
        .id = 1,
        .session_id = 1,
        .input = .{ .read_file = .{ .path = "notes.txt", .start_line = 2, .max_lines = 1 } },
    });
    defer result.deinit(allocator);

    try std.testing.expect(result.ok);
    const output = result.output.?.read_file;
    try std.testing.expectEqual(@as(usize, 2), output.start_line);
    try std.testing.expectEqual(@as(usize, 1), output.line_count);
    try std.testing.expectEqualStrings("two", output.content);
    try std.testing.expect(output.truncated_lines);
}

test "agent read_file applies byte cap" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const bytes = try allocator.alloc(u8, tools.max_file_read_bytes + 1);
    defer allocator.free(bytes);
    @memset(bytes, 'a');
    try tmp.dir.writeFile(io, .{ .sub_path = "large.txt", .data = bytes });

    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);

    var executor = AgentToolExecutor.init(allocator, io, root);
    var result = executor.execute(.{
        .id = 1,
        .session_id = 1,
        .input = .{ .read_file = .{ .path = "large.txt" } },
    });
    defer result.deinit(allocator);

    try std.testing.expect(!result.ok);
}

test "agent search_text caps results" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "needle\nneedle\nneedle\n" });
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);

    var executor = AgentToolExecutor.init(allocator, io, root);
    var result = executor.execute(.{
        .id = 1,
        .session_id = 1,
        .input = .{ .search_text = .{ .query = "needle", .max_results = 2 } },
    });
    defer result.deinit(allocator);

    try std.testing.expect(result.ok);
    const output = result.output.?.search_text;
    try std.testing.expectEqual(@as(usize, 2), output.matches.len);
    try std.testing.expect(output.truncated);
}

test "agent get_git_status handles non-git workspace gracefully" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = ".git", .data = "not a git repository\n" });

    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);

    var executor = AgentToolExecutor.init(allocator, io, root);
    var result = executor.execute(.{
        .id = 1,
        .session_id = 1,
        .input = .{ .get_git_status = .{} },
    });
    defer result.deinit(allocator);

    try std.testing.expect(result.ok);
    try std.testing.expect(result.output.?.get_git_status.non_git);
}
