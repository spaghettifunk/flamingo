const std = @import("std");
const logz = @import("logz");
const config = @import("../../../config.zig");
const backend = @import("../backend.zig");
const agent = @import("../session.zig");
const openai_client = @import("../openai_client.zig");
const proposal = @import("../proposal.zig");
const tools = @import("../tools.zig");
const tool_executor = @import("../tool_executor.zig");
const guard = @import("../workspace_guard.zig");
const event_queue = @import("../../runtime/event_queue.zig");

pub const OpenAIBackend = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    queue: *event_queue.EventQueue,
    model: []u8,
    api_key_env: []u8,
    api_key: ?[]u8 = null,
    limits: config.AgentLimitsConfig = .{},
    mutex: std.Io.Mutex = .init,
    running: bool = false,
    cancelled: bool = false,
    thread: ?std.Thread = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, queue: *event_queue.EventQueue) OpenAIBackend {
        return .{
            .allocator = allocator,
            .io = io,
            .queue = queue,
            .model = &.{},
            .api_key_env = &.{},
        };
    }

    pub fn configure(self: *OpenAIBackend, cfg: config.AgentConfig, env: anytype) !void {
        if (self.model.len > 0) self.allocator.free(self.model);
        if (self.api_key_env.len > 0) self.allocator.free(self.api_key_env);
        if (self.api_key) |key| self.allocator.free(key);
        self.model = try self.allocator.dupe(u8, cfg.openai.model);
        self.api_key_env = try self.allocator.dupe(u8, cfg.openai.api_key_env);
        self.limits = cfg.limits;
        self.api_key = if (env.get(cfg.openai.api_key_env)) |value|
            if (value.len > 0) try self.allocator.dupe(u8, value) else null
        else
            null;
    }

    pub fn deinit(self: *OpenAIBackend) void {
        self.cancelRunning();
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
        if (self.model.len > 0) self.allocator.free(self.model);
        if (self.api_key_env.len > 0) self.allocator.free(self.api_key_env);
        if (self.api_key) |key| self.allocator.free(key);
        self.* = undefined;
    }

    pub fn asBackend(self: *OpenAIBackend) backend.AgentBackend {
        return .{
            .ctx = self,
            .kind_value = .openai_codex,
            .startSessionFn = startSessionThunk,
            .cancelSessionFn = cancelSessionThunk,
            .hasRunningSessionFn = hasRunningSessionThunk,
            .availabilityMessageFn = availabilityMessageThunk,
        };
    }

    pub fn startSession(self: *OpenAIBackend, request: backend.AgentRequest) backend.AgentBackendError!void {
        if (self.api_key == null or self.model.len == 0) return error.AgentBackendUnavailable;
        try self.prepareForStart();

        var owned = StartRequest{
            .session_id = request.session_id,
            .mode = request.mode,
            .prompt = try self.allocator.dupe(u8, request.prompt),
            .workspace_root = try self.allocator.dupe(u8, request.workspace_root),
        };
        errdefer owned.deinit(self.allocator);

        self.mutex.lockUncancelable(self.io);
        self.running = true;
        self.cancelled = false;
        self.mutex.unlock(self.io);

        self.thread = std.Thread.spawn(.{}, run, .{ self, owned }) catch |err| {
            self.mutex.lockUncancelable(self.io);
            self.running = false;
            self.mutex.unlock(self.io);
            return err;
        };
    }

    pub fn cancelRunning(self: *OpenAIBackend) void {
        self.mutex.lockUncancelable(self.io);
        self.cancelled = true;
        self.mutex.unlock(self.io);
    }

    pub fn hasRunningSession(self: *OpenAIBackend) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.running;
    }

    pub fn availabilityMessage(self: *OpenAIBackend) ?[]const u8 {
        if (self.model.len == 0) return "OpenAI model is not configured";
        if (self.api_key == null) return "OpenAI API key environment variable is missing";
        return null;
    }

    fn prepareForStart(self: *OpenAIBackend) error{AgentSessionAlreadyRunning}!void {
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

    fn run(self: *OpenAIBackend, request: StartRequest) void {
        var owned = request;
        defer owned.deinit(self.allocator);
        defer {
            self.mutex.lockUncancelable(self.io);
            self.running = false;
            self.mutex.unlock(self.io);
        }

        self.emit(.status, "Starting OpenAI Codex session.", owned.session_id);
        if (self.isCancelled()) return self.finish(owned.session_id, .cancelled);

        var client = openai_client.OpenAIClient.init(self.allocator, self.io, self.api_key.?, self.model);
        const stream = client.fetchResponseStream(.{ .mode = owned.mode, .prompt = owned.prompt }) catch |err| {
            self.emitFmt(.agent_error, owned.session_id, "OpenAI request failed: {s}", .{@errorName(err)});
            self.finish(owned.session_id, .failed);
            return;
        };
        defer self.allocator.free(stream);

        var sink = StreamSink{
            .backend = self,
            .session_id = owned.session_id,
            .workspace_root = owned.workspace_root,
        };
        openai_client.parseSseEvents(self.allocator, stream, &sink) catch |err| {
            if (err != error.OpenAIToolLimitReached) {
                self.emitFmt(.agent_error, owned.session_id, "OpenAI stream failed: {s}", .{@errorName(err)});
            }
            self.finish(owned.session_id, .failed);
            return;
        };
        if (self.isCancelled()) return self.finish(owned.session_id, .cancelled);
        self.finish(owned.session_id, .completed);
    }

    fn isCancelled(self: *OpenAIBackend) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.cancelled;
    }

    fn emit(self: *OpenAIBackend, kind: agent.AgentEventKind, text: []const u8, id: u64) void {
        const owned = self.allocator.dupe(u8, text) catch return;
        self.queue.push(.{ .agent_event = .{
            .id = id,
            .kind = kind,
            .text = owned,
            .timestamp_ms = agent.nowMs(self.io),
        } }) catch |err| {
            self.allocator.free(owned);
            logz.debug().fmt("msg", "dropping OpenAI agent event: {any}", .{err}).log();
        };
    }

    fn emitFmt(self: *OpenAIBackend, kind: agent.AgentEventKind, id: u64, comptime fmt: []const u8, args: anytype) void {
        const owned = std.fmt.allocPrint(self.allocator, fmt, args) catch return;
        self.queue.push(.{ .agent_event = .{
            .id = id,
            .kind = kind,
            .text = owned,
            .timestamp_ms = agent.nowMs(self.io),
        } }) catch |err| {
            self.allocator.free(owned);
            logz.debug().fmt("msg", "dropping OpenAI agent event: {any}", .{err}).log();
        };
    }

    fn finish(self: *OpenAIBackend, id: u64, status: agent.AgentSessionStatus) void {
        self.queue.push(.{ .agent_session_finished = .{
            .id = id,
            .status = status,
            .finished_at_ms = agent.nowMs(self.io),
        } }) catch |err| {
            logz.debug().fmt("msg", "dropping OpenAI finish event: {any}", .{err}).log();
        };
    }
};

const StartRequest = struct {
    session_id: u64,
    mode: agent.AgentMode,
    prompt: []u8,
    workspace_root: []u8,

    fn deinit(self: *StartRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.prompt);
        allocator.free(self.workspace_root);
        self.* = undefined;
    }
};

const StreamSink = struct {
    backend: *OpenAIBackend,
    session_id: u64,
    workspace_root: []const u8,
    next_tool_call_id: u64 = 1,
    tool_call_count: usize = 0,
    file_read_count: usize = 0,
    search_result_count: usize = 0,

    pub fn emit(self: *StreamSink, event: openai_client.OpenAIStreamEvent) !void {
        if (self.backend.isCancelled()) return;
        switch (event.kind) {
            .message_delta => if (event.text.len > 0) self.backend.emit(.assistant_message, event.text, self.session_id),
            .tool_call => try self.handleToolCall(event.tool_name, event.tool_arguments),
            .completed => self.backend.emit(.status, "OpenAI stream complete.", self.session_id),
            .error_message => self.backend.emit(.agent_error, event.text, self.session_id),
        }
    }

    fn handleToolCall(self: *StreamSink, name: []const u8, arguments: []const u8) !void {
        self.tool_call_count += 1;
        if (self.tool_call_count > self.backend.limits.max_tool_calls) {
            self.backend.emit(.agent_error, "Session aborted: tool limit reached.", self.session_id);
            return error.OpenAIToolLimitReached;
        }

        if (std.mem.eql(u8, name, "propose_patch")) {
            try self.handlePatchProposal(arguments);
            return;
        }

        const call = parseToolCall(self.backend.allocator, self.session_id, self.next_tool_call_id, name, arguments) catch |err| {
            self.backend.emitFmt(.agent_error, self.session_id, "Rejected tool call {s}: {s}", .{ name, @errorName(err) });
            return;
        };
        defer deinitToolCall(self.backend.allocator, call);
        self.next_tool_call_id += 1;

        if (std.meta.activeTag(call.input) == .read_file) {
            self.file_read_count += 1;
            if (self.file_read_count > self.backend.limits.max_file_reads) {
                self.backend.emit(.agent_error, "Session aborted: file read limit reached.", self.session_id);
                return error.OpenAIToolLimitReached;
            }
        }

        const call_text = tools.formatToolCall(self.backend.allocator, call) catch name;
        defer if (call_text.ptr != name.ptr) self.backend.allocator.free(call_text);
        self.backend.emit(.tool_call, call_text, self.session_id);

        var executor = tool_executor.AgentToolExecutor.init(self.backend.allocator, self.backend.io, self.workspace_root);
        var result = executor.execute(call);
        defer result.deinit(self.backend.allocator);

        if (result.output) |output| {
            if (std.meta.activeTag(output) == .search_text) {
                self.search_result_count += output.search_text.matches.len;
                if (self.search_result_count > self.backend.limits.max_search_results) {
                    self.backend.emit(.agent_error, "Session aborted: search result limit reached.", self.session_id);
                    return error.OpenAIToolLimitReached;
                }
            }
        }

        const result_text = tools.formatToolResult(self.backend.allocator, result) catch {
            self.backend.emit(.tool_result, "tool result unavailable", self.session_id);
            return;
        };
        defer self.backend.allocator.free(result_text);
        self.backend.emit(.tool_result, result_text, self.session_id);
    }

    fn handlePatchProposal(self: *StreamSink, arguments: []const u8) !void {
        self.backend.emit(.status, "Preparing OpenAI patch proposal.", self.session_id);
        var draft = buildProposalDraftFromArguments(
            self.backend.allocator,
            self.backend.io,
            self.workspace_root,
            self.session_id,
            arguments,
            agent.nowMs(self.backend.io),
        ) catch |err| {
            self.backend.emitFmt(.agent_error, self.session_id, "Rejected patch proposal: {s}", .{@errorName(err)});
            return;
        };
        errdefer draft.deinit(self.backend.allocator);
        self.backend.queue.push(.{ .agent_proposal_created = draft }) catch |err| {
            draft.deinit(self.backend.allocator);
            logz.debug().fmt("msg", "dropping OpenAI proposal event: {any}", .{err}).log();
        };
    }
};

fn parseToolCall(
    allocator: std.mem.Allocator,
    session_id: u64,
    id: u64,
    name: []const u8,
    arguments: []const u8,
) !tools.AgentToolCall {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, arguments, .{}) catch return error.InvalidToolArguments;
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidToolArguments,
    };

    const input: tools.AgentToolInput = if (std.mem.eql(u8, name, "list_files"))
        .{ .list_files = .{
            .root_relative_path = if (jsonString(object.get("root_relative_path"))) |path|
                try allocator.dupe(u8, path)
            else
                null,
            .max_results = jsonUsize(object.get("max_results")) orelse 200,
        } }
    else if (std.mem.eql(u8, name, "read_file"))
        .{ .read_file = .{
            .path = try allocator.dupe(u8, jsonString(object.get("path")) orelse return error.InvalidToolArguments),
            .start_line = jsonUsize(object.get("start_line")),
            .max_lines = jsonUsize(object.get("max_lines")),
        } }
    else if (std.mem.eql(u8, name, "search_text"))
        .{ .search_text = .{
            .query = try allocator.dupe(u8, jsonString(object.get("query")) orelse return error.InvalidToolArguments),
            .max_results = jsonUsize(object.get("max_results")) orelse 50,
        } }
    else if (std.mem.eql(u8, name, "get_git_status"))
        .{ .get_git_status = .{} }
    else if (std.mem.eql(u8, name, "get_git_diff_summary"))
        .{ .get_git_diff_summary = .{} }
    else
        return error.UnknownTool;

    return .{
        .id = id,
        .session_id = session_id,
        .input = input,
    };
}

fn deinitToolCall(allocator: std.mem.Allocator, call: tools.AgentToolCall) void {
    switch (call.input) {
        .list_files => |input| if (input.root_relative_path) |path| allocator.free(path),
        .read_file => |input| allocator.free(input.path),
        .search_text => |input| allocator.free(input.query),
        .get_git_status, .get_git_diff_summary => {},
    }
}

fn buildProposalDraftFromArguments(
    allocator: std.mem.Allocator,
    io: std.Io,
    workspace_root: []const u8,
    session_id: u64,
    arguments: []const u8,
    created_at_ms: i64,
) !proposal.PatchProposalDraft {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, arguments, .{}) catch return error.InvalidProposalArguments;
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidProposalArguments,
    };
    const file_path = jsonString(object.get("file_path")) orelse return error.InvalidProposalArguments;
    const description = jsonString(object.get("description")) orelse return error.InvalidProposalArguments;
    const unified_diff = jsonString(object.get("unified_diff")) orelse return error.InvalidProposalArguments;

    const checked_path = try guard.resolveWorkspacePath(allocator, io, workspace_root, file_path);
    allocator.free(checked_path);

    const content = try extractCreateFileContent(allocator, file_path, unified_diff);
    errdefer allocator.free(content);
    const owned_path = try allocator.dupe(u8, file_path);
    errdefer allocator.free(owned_path);
    const owned_description = try allocator.dupe(u8, description);
    errdefer allocator.free(owned_description);
    const owned_diff = try allocator.dupe(u8, unified_diff);
    errdefer allocator.free(owned_diff);

    return .{
        .session_id = session_id,
        .file_path = owned_path,
        .description = owned_description,
        .unified_diff = owned_diff,
        .edit = .{ .create_file = .{ .content = content } },
        .created_at_ms = created_at_ms,
    };
}

fn extractCreateFileContent(allocator: std.mem.Allocator, file_path: []const u8, unified_diff: []const u8) ![]u8 {
    if (std.mem.indexOf(u8, unified_diff, "--- /dev/null") == null) return error.UnsupportedPatchProposal;
    const to_header = try std.fmt.allocPrint(allocator, "+++ b/{s}", .{file_path});
    defer allocator.free(to_header);
    if (std.mem.indexOf(u8, unified_diff, to_header) == null) return error.UnsupportedPatchProposal;

    var content = std.ArrayListUnmanaged(u8).empty;
    errdefer content.deinit(allocator);
    var in_hunk = false;
    var saw_added = false;
    var lines = std.mem.splitScalar(u8, unified_diff, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, "\r");
        if (std.mem.startsWith(u8, line, "@@")) {
            in_hunk = true;
            continue;
        }
        if (!in_hunk) continue;
        if (std.mem.startsWith(u8, line, "+++") or line.len == 0 or line[0] != '+') continue;
        try content.appendSlice(allocator, line[1..]);
        try content.append(allocator, '\n');
        saw_added = true;
    }
    if (!saw_added) return error.UnsupportedPatchProposal;
    return content.toOwnedSlice(allocator);
}

fn jsonString(value: ?std.json.Value) ?[]const u8 {
    return switch (value orelse return null) {
        .string => |text| text,
        else => null,
    };
}

fn jsonUsize(value: ?std.json.Value) ?usize {
    return switch (value orelse return null) {
        .integer => |n| if (n >= 0) @intCast(n) else null,
        .float => |n| if (n >= 0 and @floor(n) == n) @intFromFloat(n) else null,
        else => null,
    };
}

fn startSessionThunk(ctx: *anyopaque, request: backend.AgentRequest) backend.AgentBackendError!void {
    const self: *OpenAIBackend = @ptrCast(@alignCast(ctx));
    return self.startSession(request);
}

fn cancelSessionThunk(ctx: *anyopaque, session_id: u64) void {
    _ = session_id;
    const self: *OpenAIBackend = @ptrCast(@alignCast(ctx));
    self.cancelRunning();
}

fn hasRunningSessionThunk(ctx: *anyopaque) bool {
    const self: *OpenAIBackend = @ptrCast(@alignCast(ctx));
    return self.hasRunningSession();
}

fn availabilityMessageThunk(ctx: *anyopaque) ?[]const u8 {
    const self: *OpenAIBackend = @ptrCast(@alignCast(ctx));
    return self.availabilityMessage();
}

test "openai backend reports missing key unavailable" {
    const Env = struct {
        pub fn get(_: @This(), _: []const u8) ?[]const u8 {
            return null;
        }
    };
    var queue = event_queue.EventQueue.init(std.testing.allocator, std.testing.io);
    defer queue.deinit();
    var backend_impl = OpenAIBackend.init(std.testing.allocator, std.testing.io, &queue);
    defer backend_impl.deinit();
    try backend_impl.configure(.{}, Env{});
    try std.testing.expect(backend_impl.availabilityMessage() != null);
}

test "openai backend parses create-file proposal arguments" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);

    var args = std.Io.Writer.Allocating.init(allocator);
    defer args.deinit();
    try std.json.Stringify.value(.{
        .file_path = "docs/demo.md",
        .description = "Create demo",
        .unified_diff =
        \\--- /dev/null
        \\+++ b/docs/demo.md
        \\@@ -0,0 +1,2 @@
        \\+# Demo
        \\+body
        \\
        ,
    }, .{}, &args.writer);

    var draft = try buildProposalDraftFromArguments(allocator, io, root, 9, args.written(), 12);
    defer draft.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 9), draft.session_id);
    try std.testing.expectEqualStrings("docs/demo.md", draft.file_path);
    try std.testing.expectEqualStrings("# Demo\nbody\n", draft.edit.create_file.content);
}
