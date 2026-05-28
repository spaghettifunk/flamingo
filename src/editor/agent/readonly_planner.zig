const std = @import("std");
const session = @import("session.zig");
const tools = @import("tools.zig");
const executor_mod = @import("tool_executor.zig");

pub const PlannerError = error{Cancelled} || std.mem.Allocator.Error;

pub const ReadOnlyPlanner = struct {
    allocator: std.mem.Allocator,
    executor: *executor_mod.AgentToolExecutor,
    session_id: u64,
    next_call_id: u64 = 1,

    pub fn init(
        allocator: std.mem.Allocator,
        executor: *executor_mod.AgentToolExecutor,
        session_id: u64,
    ) ReadOnlyPlanner {
        return .{
            .allocator = allocator,
            .executor = executor,
            .session_id = session_id,
        };
    }

    pub fn run(self: *ReadOnlyPlanner, prompt: []const u8, emitter: anytype) PlannerError!void {
        try self.emit(emitter, .status, "Starting plan session.");

        var status_result = try self.callTool(emitter, .{ .get_git_status = .{} });
        defer status_result.deinit(self.allocator);

        var files_result = try self.callTool(emitter, .{ .list_files = .{
            .root_relative_path = null,
            .max_results = 200,
        } });
        defer files_result.deinit(self.allocator);

        const query = bestSearchQuery(prompt);
        var search_result = try self.callTool(emitter, .{ .search_text = .{
            .query = query,
            .max_results = 20,
        } });
        defer search_result.deinit(self.allocator);

        var read_results = std.ArrayListUnmanaged(tools.AgentToolResult).empty;
        defer {
            for (read_results.items) |*result| result.deinit(self.allocator);
            read_results.deinit(self.allocator);
        }
        try self.readTopSearchMatches(emitter, search_result, &read_results);

        var diff_result = try self.callTool(emitter, .{ .get_git_diff_summary = .{} });
        defer diff_result.deinit(self.allocator);

        const plan = try self.buildPlan(prompt, status_result, files_result, search_result, diff_result);
        defer self.allocator.free(plan);
        try self.emit(emitter, .assistant_message, "Plan complete.");
        try self.emit(emitter, .final_plan, plan);
    }

    fn callTool(
        self: *ReadOnlyPlanner,
        emitter: anytype,
        input: tools.AgentToolInput,
    ) PlannerError!tools.AgentToolResult {
        const call = tools.AgentToolCall{
            .id = self.next_call_id,
            .session_id = self.session_id,
            .input = input,
        };
        self.next_call_id +%= 1;

        const call_text = try tools.formatToolCall(self.allocator, call);
        defer self.allocator.free(call_text);
        try self.emit(emitter, .tool_call, call_text);

        var result = self.executor.execute(call);
        errdefer result.deinit(self.allocator);

        const result_text = try tools.formatToolResult(self.allocator, result);
        defer self.allocator.free(result_text);
        try self.emit(emitter, if (result.ok) .tool_result else .agent_error, result_text);
        return result;
    }

    fn readTopSearchMatches(
        self: *ReadOnlyPlanner,
        emitter: anytype,
        search_result: tools.AgentToolResult,
        read_results: *std.ArrayListUnmanaged(tools.AgentToolResult),
    ) PlannerError!void {
        if (!search_result.ok) return;
        const output = search_result.output orelse return;
        if (std.meta.activeTag(output) != .search_text) return;

        var read_count: usize = 0;
        for (output.search_text.matches) |match| {
            if (read_count >= 2) break;
            if (alreadyRead(read_results.items, match.path)) continue;
            const result = try self.callTool(emitter, .{ .read_file = .{
                .path = match.path,
                .start_line = if (match.line > 5) match.line - 5 else 1,
                .max_lines = 80,
            } });
            try read_results.append(self.allocator, result);
            read_count += 1;
        }
    }

    fn buildPlan(
        self: *ReadOnlyPlanner,
        prompt: []const u8,
        status_result: tools.AgentToolResult,
        files_result: tools.AgentToolResult,
        search_result: tools.AgentToolResult,
        diff_result: tools.AgentToolResult,
    ) ![]u8 {
        var likely_files = std.ArrayListUnmanaged([]const u8).empty;
        defer likely_files.deinit(self.allocator);

        collectLikelyFiles(self.allocator, &likely_files, search_result) catch {};
        if (likely_files.items.len == 0) collectLikelyFilesFromList(self.allocator, &likely_files, files_result) catch {};

        const changed_count = changedFileCount(status_result);
        const diff_count = diffFileCount(diff_result);

        var out = std.ArrayListUnmanaged(u8).empty;
        errdefer out.deinit(self.allocator);

        try appendFmt(self.allocator, &out,
            \\Plan
            \\
            \\Summary:
            \\Use the inspected workspace context to implement: {s}
            \\
            \\Workspace context:
            \\- Git status changed files: {d}
            \\- Git diff summary files: {d}
            \\
            \\Likely files:
            \\
        , .{ prompt, changed_count, diff_count });

        if (likely_files.items.len == 0) {
            try out.appendSlice(self.allocator, "- No obvious files found from the read-only scan.\n");
        } else {
            for (likely_files.items[0..@min(likely_files.items.len, 6)]) |path| {
                try appendFmt(self.allocator, &out, "- {s}\n", .{path});
            }
        }

        try out.appendSlice(self.allocator,
            \\
            \\Steps:
            \\1. Review the likely files and adjacent modules before editing.
            \\2. Add or update the smallest module boundaries that fit the request.
            \\3. Wire the behavior through existing commands, state, or renderer paths as needed.
            \\4. Add focused tests for safety, ordering, and user-visible behavior.
            \\5. Run repository validation.
            \\
            \\Validation:
            \\- zig build test
            \\- zig build
            \\
            \\Risks:
            \\- The deterministic planner may miss relevant files when the prompt terms do not appear literally.
            \\- Large or binary files are intentionally summarized instead of read.
            \\
        );
        return out.toOwnedSlice(self.allocator);
    }

    fn emit(self: *ReadOnlyPlanner, emitter: anytype, kind: session.AgentEventKind, text: []const u8) PlannerError!void {
        _ = self;
        const keep_running = emitter.emit(kind, text) catch return error.OutOfMemory;
        if (!keep_running) return error.Cancelled;
    }
};

fn appendFmt(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    comptime fmt: []const u8,
    args: anytype,
) !void {
    const text = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(text);
    try out.appendSlice(allocator, text);
}

fn bestSearchQuery(prompt: []const u8) []const u8 {
    const ignored = [_][]const u8{
        "the", "and", "for", "with", "from", "into", "this", "that", "implement", "add", "fix", "update", "mode",
    };
    var best: []const u8 = prompt;
    var best_len: usize = 0;
    var it = std.mem.tokenizeAny(u8, prompt, " \t\r\n,.;:()[]{}<>\"'");
    while (it.next()) |word| {
        if (word.len < 3) continue;
        var skip = false;
        for (ignored) |candidate| {
            if (std.ascii.eqlIgnoreCase(word, candidate)) {
                skip = true;
                break;
            }
        }
        if (skip) continue;
        if (word.len > best_len) {
            best = word;
            best_len = word.len;
        }
    }
    return best;
}

fn alreadyRead(results: []const tools.AgentToolResult, path: []const u8) bool {
    for (results) |result| {
        if (!result.ok) continue;
        const output = result.output orelse continue;
        if (std.meta.activeTag(output) != .read_file) continue;
        if (std.mem.eql(u8, output.read_file.path, path)) return true;
    }
    return false;
}

fn collectLikelyFiles(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged([]const u8), result: tools.AgentToolResult) !void {
    if (!result.ok) return;
    const output = result.output orelse return;
    if (std.meta.activeTag(output) != .search_text) return;
    for (output.search_text.matches) |match| {
        if (containsPath(out.items, match.path)) continue;
        try out.append(allocator, match.path);
    }
}

fn collectLikelyFilesFromList(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged([]const u8), result: tools.AgentToolResult) !void {
    if (!result.ok) return;
    const output = result.output orelse return;
    if (std.meta.activeTag(output) != .list_files) return;
    for (output.list_files.entries) |entry| {
        if (entry.kind != .file) continue;
        if (!(std.mem.endsWith(u8, entry.path, ".zig") or std.mem.endsWith(u8, entry.path, ".md"))) continue;
        if (containsPath(out.items, entry.path)) continue;
        try out.append(allocator, entry.path);
        if (out.items.len >= 6) return;
    }
}

fn containsPath(paths: []const []const u8, path: []const u8) bool {
    for (paths) |candidate| {
        if (std.mem.eql(u8, candidate, path)) return true;
    }
    return false;
}

fn changedFileCount(result: tools.AgentToolResult) usize {
    if (!result.ok) return 0;
    const output = result.output orelse return 0;
    if (std.meta.activeTag(output) != .get_git_status) return 0;
    return output.get_git_status.entries.len;
}

fn diffFileCount(result: tools.AgentToolResult) usize {
    if (!result.ok) return 0;
    const output = result.output orelse return 0;
    if (std.meta.activeTag(output) != .get_git_diff_summary) return 0;
    return output.get_git_diff_summary.entries.len;
}

test "read-only planner emits tool events and final plan in order" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "src/editor/agent");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/editor/agent/session.zig", .data = "pub const Agent = struct {};\n" });

    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);

    var executor = executor_mod.AgentToolExecutor.init(allocator, io, root);
    var planner = ReadOnlyPlanner.init(allocator, &executor, 1);
    var sink = TestSink{ .allocator = allocator };
    defer sink.deinit();

    try planner.run("implement agent tools", &sink);

    const inspected_path = try std.fs.path.join(allocator, &.{ root, "src/editor/agent/session.zig" });
    defer allocator.free(inspected_path);
    const after = try std.Io.Dir.cwd().readFileAlloc(io, inspected_path, allocator, std.Io.Limit.limited(1024));
    defer allocator.free(after);
    try std.testing.expectEqualStrings("pub const Agent = struct {};\n", after);

    try std.testing.expect(sink.events.items.len >= 8);
    try std.testing.expectEqual(session.AgentEventKind.status, sink.events.items[0].kind);
    try std.testing.expectEqual(session.AgentEventKind.tool_call, sink.events.items[1].kind);
    try std.testing.expectEqual(session.AgentEventKind.tool_result, sink.events.items[2].kind);
    try std.testing.expectEqual(session.AgentEventKind.final_plan, sink.events.items[sink.events.items.len - 1].kind);
}

const TestEvent = struct {
    kind: session.AgentEventKind,
    text: []u8,
};

const TestSink = struct {
    allocator: std.mem.Allocator,
    events: std.ArrayListUnmanaged(TestEvent) = .empty,

    fn deinit(self: *TestSink) void {
        for (self.events.items) |event| self.allocator.free(event.text);
        self.events.deinit(self.allocator);
    }

    pub fn emit(self: *TestSink, kind: session.AgentEventKind, text: []const u8) !bool {
        try self.events.append(self.allocator, .{
            .kind = kind,
            .text = try self.allocator.dupe(u8, text),
        });
        return true;
    }
};
