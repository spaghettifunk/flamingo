const std = @import("std");
const logz = @import("logz");
const event_queue = @import("event_queue.zig");
const diff_service = @import("../git/diff_service.zig");

const RefreshRequest = struct {
    absolute_path: []u8,
    line_count: usize,
    explicit: bool,

    fn deinit(self: *RefreshRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.absolute_path);
        self.* = undefined;
    }
};

pub const GitDiffWorker = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    queue: *event_queue.EventQueue,
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    pending: ?RefreshRequest = null,
    quit: bool = false,
    thread: std.Thread = undefined,

    pub fn start(allocator: std.mem.Allocator, io: std.Io, queue: *event_queue.EventQueue) !*GitDiffWorker {
        const worker = try allocator.create(GitDiffWorker);
        errdefer allocator.destroy(worker);

        worker.* = .{
            .allocator = allocator,
            .io = io,
            .queue = queue,
        };
        worker.thread = try std.Thread.spawn(.{}, run, .{worker});
        return worker;
    }

    pub fn stop(self: *GitDiffWorker) void {
        self.mutex.lockUncancelable(self.io);
        self.quit = true;
        if (self.pending) |*request| {
            request.deinit(self.allocator);
            self.pending = null;
        }
        self.cond.signal(self.io);
        self.mutex.unlock(self.io);

        self.thread.join();
        self.allocator.destroy(self);
    }

    pub fn requestRefresh(self: *GitDiffWorker, absolute_path: []const u8, line_count: usize, explicit: bool) !void {
        const owned_path = try self.allocator.dupe(u8, absolute_path);
        errdefer self.allocator.free(owned_path);

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.quit) {
            self.allocator.free(owned_path);
            return;
        }
        if (self.pending) |*old| old.deinit(self.allocator);
        self.pending = .{
            .absolute_path = owned_path,
            .line_count = line_count,
            .explicit = explicit,
        };
        self.cond.signal(self.io);
    }

    fn run(self: *GitDiffWorker) void {
        while (true) {
            var request = self.takeRequest() orelse break;
            defer request.deinit(self.allocator);

            var result = diff_service.computeFileDiff(
                self.allocator,
                self.io,
                request.absolute_path,
                request.line_count,
                request.explicit,
            ) catch |err| blk: {
                logz.debug().fmt("msg", "git diff refresh failed: {any}", .{err}).log();
                break :blk diff_service.RefreshResult{
                    .absolute_path = self.allocator.dupe(u8, request.absolute_path) catch return,
                    .status = .command_failed,
                    .explicit = request.explicit,
                };
            };

            self.queue.push(.{ .git_diff_result = result }) catch |err| {
                logz.debug().fmt("msg", "dropping git diff result: {any}", .{err}).log();
                result.deinit(self.allocator);
            };
        }
    }

    fn takeRequest(self: *GitDiffWorker) ?RefreshRequest {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        while (self.pending == null and !self.quit) {
            self.cond.waitUncancelable(self.io, &self.mutex);
        }

        if (self.pending) |request| {
            self.pending = null;
            return request;
        }
        return null;
    }
};
