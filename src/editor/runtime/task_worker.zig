const std = @import("std");
const logz = @import("logz");
const event_queue = @import("event_queue.zig");
const task_mod = @import("../tasks/task.zig");

pub const StartError = error{TaskAlreadyRunning} || std.mem.Allocator.Error || std.Thread.SpawnError;

const StartRequest = struct {
    id: u64,
    argv: [][]u8,
    cwd: []u8,

    fn deinit(self: *StartRequest, allocator: std.mem.Allocator) void {
        for (self.argv) |arg| allocator.free(arg);
        allocator.free(self.argv);
        allocator.free(self.cwd);
        self.* = undefined;
    }
};

const ReaderContext = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    queue: *event_queue.EventQueue,
    task_id: u64,
    kind: task_mod.TaskOutputKind,
    file: std.Io.File,
};

pub const TaskWorker = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    queue: *event_queue.EventQueue,
    mutex: std.Io.Mutex = .init,
    running: bool = false,
    cancelled: bool = false,
    child: ?*std.process.Child = null,
    thread: ?std.Thread = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, queue: *event_queue.EventQueue) TaskWorker {
        return .{
            .allocator = allocator,
            .io = io,
            .queue = queue,
        };
    }

    pub fn deinit(self: *TaskWorker) void {
        self.cancelRunning();
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
    }

    pub fn startTask(self: *TaskWorker, id: u64, argv: []const []const u8, cwd: []const u8) StartError!void {
        try self.prepareForStart();

        var request = StartRequest{
            .id = id,
            .argv = try cloneArgv(self.allocator, argv),
            .cwd = try self.allocator.dupe(u8, cwd),
        };
        errdefer request.deinit(self.allocator);

        self.mutex.lockUncancelable(self.io);
        self.running = true;
        self.cancelled = false;
        self.child = null;
        self.mutex.unlock(self.io);

        self.thread = std.Thread.spawn(.{}, run, .{ self, request }) catch |err| {
            self.mutex.lockUncancelable(self.io);
            self.running = false;
            self.mutex.unlock(self.io);
            return err;
        };
    }

    pub fn cancelRunning(self: *TaskWorker) void {
        self.mutex.lockUncancelable(self.io);
        self.cancelled = true;
        if (self.child) |child| {
            child.kill(self.io);
        }
        self.mutex.unlock(self.io);
    }

    pub fn hasRunningTask(self: *TaskWorker) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.running;
    }

    fn prepareForStart(self: *TaskWorker) error{TaskAlreadyRunning}!void {
        while (true) {
            self.mutex.lockUncancelable(self.io);
            if (self.running) {
                self.mutex.unlock(self.io);
                return error.TaskAlreadyRunning;
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

    fn run(self: *TaskWorker, request: StartRequest) void {
        var owned_request = request;
        defer owned_request.deinit(self.allocator);
        defer {
            self.mutex.lockUncancelable(self.io);
            self.child = null;
            self.running = false;
            self.mutex.unlock(self.io);
        }

        var child = std.process.spawn(self.io, .{
            .argv = @ptrCast(owned_request.argv),
            .cwd = .{ .path = owned_request.cwd },
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .pipe,
            .create_no_window = true,
        }) catch |err| {
            self.pushFailedToStart(owned_request.id, err);
            return;
        };
        defer child.kill(self.io);

        self.mutex.lockUncancelable(self.io);
        self.child = &child;
        self.mutex.unlock(self.io);

        self.pushStarted(owned_request.id);

        const stdout_thread = if (child.stdout) |file|
            std.Thread.spawn(.{}, readerLoop, .{ReaderContext{
                .allocator = self.allocator,
                .io = self.io,
                .queue = self.queue,
                .task_id = owned_request.id,
                .kind = .stdout,
                .file = file,
            }}) catch null
        else
            null;
        const stderr_thread = if (child.stderr) |file|
            std.Thread.spawn(.{}, readerLoop, .{ReaderContext{
                .allocator = self.allocator,
                .io = self.io,
                .queue = self.queue,
                .task_id = owned_request.id,
                .kind = .stderr,
                .file = file,
            }}) catch null
        else
            null;

        if (stdout_thread == null and child.stdout != null) {
            self.pushOutput(owned_request.id, .system, "Unable to start stdout reader.");
        }
        if (stderr_thread == null and child.stderr != null) {
            self.pushOutput(owned_request.id, .system, "Unable to start stderr reader.");
        }

        if (stdout_thread) |thread| thread.join();
        if (stderr_thread) |thread| thread.join();

        var cancelled = false;
        var term: ?std.process.Child.Term = null;
        var wait_error: ?anyerror = null;
        self.mutex.lockUncancelable(self.io);
        cancelled = self.cancelled;
        if (child.id != null) {
            term = child.wait(self.io) catch |err| blk: {
                wait_error = err;
                break :blk null;
            };
        } else {
            cancelled = true;
        }
        self.child = null;
        self.mutex.unlock(self.io);

        if (wait_error) |err| {
            self.pushOutputFmt(owned_request.id, .system, "Task wait failed: {s}", .{@errorName(err)});
            self.markIdleBeforeFinishedEvent();
            self.pushFinished(owned_request.id, .failed, null);
            return;
        }
        if (cancelled) {
            self.markIdleBeforeFinishedEvent();
            self.pushFinished(owned_request.id, .cancelled, null);
            return;
        }

        const exit_code = exitCode(term.?);
        const status: task_mod.TaskStatus = if (exit_code != null and exit_code.? == 0) .success else .failed;
        self.markIdleBeforeFinishedEvent();
        self.pushFinished(owned_request.id, status, exit_code);
    }

    fn markIdleBeforeFinishedEvent(self: *TaskWorker) void {
        self.mutex.lockUncancelable(self.io);
        self.child = null;
        self.running = false;
        self.mutex.unlock(self.io);
    }

    fn pushStarted(self: *TaskWorker, id: u64) void {
        self.queue.push(.{ .task_started = .{
            .id = id,
            .started_at_ms = task_mod.nowMs(self.io),
        } }) catch |err| {
            logz.debug().fmt("msg", "dropping task_started event: {any}", .{err}).log();
        };
    }

    fn pushFailedToStart(self: *TaskWorker, id: u64, err: anyerror) void {
        const message = std.fmt.allocPrint(self.allocator, "Unable to start task: {s}", .{@errorName(err)}) catch return;
        self.queue.push(.{ .task_failed_to_start = .{
            .id = id,
            .message = message,
            .finished_at_ms = task_mod.nowMs(self.io),
        } }) catch {
            self.allocator.free(message);
        };
    }

    fn pushOutput(self: *TaskWorker, id: u64, kind: task_mod.TaskOutputKind, bytes: []const u8) void {
        const owned = self.allocator.dupe(u8, bytes) catch return;
        self.queue.push(.{ .task_output = .{
            .id = id,
            .kind = kind,
            .bytes = owned,
        } }) catch {
            self.allocator.free(owned);
        };
    }

    fn pushOutputFmt(self: *TaskWorker, id: u64, kind: task_mod.TaskOutputKind, comptime fmt: []const u8, args: anytype) void {
        const owned = std.fmt.allocPrint(self.allocator, fmt, args) catch return;
        self.queue.push(.{ .task_output = .{
            .id = id,
            .kind = kind,
            .bytes = owned,
        } }) catch {
            self.allocator.free(owned);
        };
    }

    fn pushFinished(self: *TaskWorker, id: u64, status: task_mod.TaskStatus, code: ?i32) void {
        self.queue.push(.{ .task_finished = .{
            .id = id,
            .status = status,
            .exit_code = code,
            .finished_at_ms = task_mod.nowMs(self.io),
        } }) catch |err| {
            logz.debug().fmt("msg", "dropping task_finished event: {any}", .{err}).log();
        };
    }
};

fn readerLoop(context: ReaderContext) void {
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = context.file.readStreaming(context.io, &.{buf[0..]}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => {
                const message = std.fmt.allocPrint(context.allocator, "Task output read failed: {s}", .{@errorName(err)}) catch break;
                context.queue.push(.{ .task_output = .{
                    .id = context.task_id,
                    .kind = .system,
                    .bytes = message,
                } }) catch {
                    context.allocator.free(message);
                };
                break;
            },
        };
        if (n == 0) continue;
        const owned = context.allocator.dupe(u8, buf[0..n]) catch break;
        context.queue.push(.{ .task_output = .{
            .id = context.task_id,
            .kind = context.kind,
            .bytes = owned,
        } }) catch {
            context.allocator.free(owned);
            break;
        };
    }
}

fn cloneArgv(allocator: std.mem.Allocator, argv: []const []const u8) ![][]u8 {
    const owned = try allocator.alloc([]u8, argv.len);
    var initialized: usize = 0;
    errdefer {
        for (owned[0..initialized]) |item| allocator.free(item);
        allocator.free(owned);
    }
    for (argv) |arg| {
        owned[initialized] = try allocator.dupe(u8, arg);
        initialized += 1;
    }
    return owned;
}

fn exitCode(term: std.process.Child.Term) ?i32 {
    return switch (term) {
        .exited => |code| @intCast(code),
        .signal, .stopped, .unknown => null,
    };
}
