const std = @import("std");
const logz = @import("logz");
const agent = @import("../agent/session.zig");
const event_queue = @import("event_queue.zig");

pub const StartError = error{AgentSessionAlreadyRunning} || std.mem.Allocator.Error || std.Thread.SpawnError;

const StartRequest = struct {
    id: u64,
    mode: agent.AgentMode,
    prompt: []u8,

    fn deinit(self: *StartRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.prompt);
        self.* = undefined;
    }
};

const ScriptStep = struct {
    kind: agent.AgentEventKind,
    text: []const u8,
};

pub const MockAgentWorker = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    queue: *event_queue.EventQueue,
    mutex: std.Io.Mutex = .init,
    running: bool = false,
    cancelled: bool = false,
    thread: ?std.Thread = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, queue: *event_queue.EventQueue) MockAgentWorker {
        return .{
            .allocator = allocator,
            .io = io,
            .queue = queue,
        };
    }

    pub fn deinit(self: *MockAgentWorker) void {
        self.cancelRunning();
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
    }

    pub fn startSession(self: *MockAgentWorker, id: u64, mode: agent.AgentMode, prompt: []const u8) StartError!void {
        try self.prepareForStart();

        var request = StartRequest{
            .id = id,
            .mode = mode,
            .prompt = try self.allocator.dupe(u8, prompt),
        };
        errdefer request.deinit(self.allocator);

        self.mutex.lockUncancelable(self.io);
        self.running = true;
        self.cancelled = false;
        self.mutex.unlock(self.io);

        self.thread = std.Thread.spawn(.{}, run, .{ self, request }) catch |err| {
            self.mutex.lockUncancelable(self.io);
            self.running = false;
            self.mutex.unlock(self.io);
            return err;
        };
    }

    pub fn cancelRunning(self: *MockAgentWorker) void {
        self.mutex.lockUncancelable(self.io);
        self.cancelled = true;
        self.mutex.unlock(self.io);
    }

    pub fn hasRunningSession(self: *MockAgentWorker) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.running;
    }

    fn prepareForStart(self: *MockAgentWorker) error{AgentSessionAlreadyRunning}!void {
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

    fn run(self: *MockAgentWorker, request: StartRequest) void {
        var owned_request = request;
        defer owned_request.deinit(self.allocator);
        defer {
            self.mutex.lockUncancelable(self.io);
            self.running = false;
            self.mutex.unlock(self.io);
        }

        self.emit(.status, "User prompt received.", owned_request.id);
        if (self.pauseOrCancel(owned_request.id)) return;

        switch (owned_request.mode) {
            .plan => self.runPlanScript(owned_request.id),
            .implementation => self.runImplementationScript(owned_request.id),
        }
    }

    fn runPlanScript(self: *MockAgentWorker, id: u64) void {
        const script = [_]ScriptStep{
            .{ .kind = .assistant_message, .text = "Inspecting workspace structure..." },
            .{ .kind = .tool_call, .text = "search_files \"relevant files\"" },
            .{ .kind = .tool_result, .text = "Mock search returned candidate files." },
            .{ .kind = .assistant_message, .text = "Drafting implementation plan..." },
            .{ .kind = .status, .text = "Plan complete." },
        };
        self.emitScript(id, &script, .completed);
    }

    fn runImplementationScript(self: *MockAgentWorker, id: u64) void {
        const script = [_]ScriptStep{
            .{ .kind = .assistant_message, .text = "Preparing implementation session..." },
            .{ .kind = .tool_call, .text = "workspace_diff" },
            .{ .kind = .tool_result, .text = "Mock diff review complete." },
            .{ .kind = .tool_call, .text = "run_validation \"zig build test\"" },
            .{ .kind = .tool_result, .text = "Would run: zig build test" },
            .{ .kind = .status, .text = "Implementation mock complete." },
        };
        self.emitScript(id, &script, .completed);
    }

    fn emitScript(
        self: *MockAgentWorker,
        id: u64,
        script: []const ScriptStep,
        final_status: agent.AgentSessionStatus,
    ) void {
        for (script) |entry| {
            if (self.pauseOrCancel(id)) return;
            self.emit(entry.kind, entry.text, id);
        }
        if (self.pauseOrCancel(id)) return;
        self.finish(id, final_status);
    }

    fn pauseOrCancel(self: *MockAgentWorker, id: u64) bool {
        sleepMs(80);
        if (!self.isCancelled()) return false;
        self.emit(.status, "Agent session cancelled.", id);
        self.finish(id, .cancelled);
        return true;
    }

    fn isCancelled(self: *MockAgentWorker) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.cancelled;
    }

    fn emit(self: *MockAgentWorker, kind: agent.AgentEventKind, text: []const u8, id: u64) void {
        const owned = self.allocator.dupe(u8, text) catch return;
        self.queue.push(.{ .agent_event = .{
            .id = id,
            .kind = kind,
            .text = owned,
            .timestamp_ms = agent.nowMs(self.io),
        } }) catch |err| {
            self.allocator.free(owned);
            logz.debug().fmt("msg", "dropping agent event: {any}", .{err}).log();
        };
    }

    fn finish(self: *MockAgentWorker, id: u64, status: agent.AgentSessionStatus) void {
        self.queue.push(.{ .agent_session_finished = .{
            .id = id,
            .status = status,
            .finished_at_ms = agent.nowMs(self.io),
        } }) catch |err| {
            logz.debug().fmt("msg", "dropping agent finish event: {any}", .{err}).log();
        };
    }
};

fn sleepMs(ms: i64) void {
    const req = std.c.timespec{
        .sec = @intCast(@divTrunc(ms, std.time.ms_per_s)),
        .nsec = @intCast(@mod(ms, std.time.ms_per_s) * std.time.ns_per_ms),
    };
    _ = std.c.nanosleep(&req, null);
}
