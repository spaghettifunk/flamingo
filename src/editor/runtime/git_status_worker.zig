const std = @import("std");
const logz = @import("logz");
const event_queue = @import("event_queue.zig");
const git_status = @import("../git_status.zig");

const refresh_interval_ns = 2 * std.time.ns_per_s;

pub const GitStatusWorker = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    queue: *event_queue.EventQueue,
    quit: std.atomic.Value(bool),
    thread: std.Thread = undefined,

    pub fn start(allocator: std.mem.Allocator, io: std.Io, queue: *event_queue.EventQueue) !*GitStatusWorker {
        const worker = try allocator.create(GitStatusWorker);
        errdefer allocator.destroy(worker);

        worker.* = .{
            .allocator = allocator,
            .io = io,
            .queue = queue,
            .quit = std.atomic.Value(bool).init(false),
        };
        worker.thread = try std.Thread.spawn(.{}, run, .{worker});
        return worker;
    }

    pub fn stop(self: *GitStatusWorker) void {
        self.quit.store(true, .seq_cst);
        self.thread.join();
        self.allocator.destroy(self);
    }

    fn run(self: *GitStatusWorker) void {
        while (!self.quit.load(.seq_cst)) {
            var snapshot = git_status.Snapshot.load(self.allocator, self.io) catch |err| blk: {
                logz.debug().fmt("msg", "git status refresh failed: {any}", .{err}).log();
                break :blk git_status.Snapshot.init(self.allocator);
            };

            self.queue.push(.{ .git_status_snapshot = snapshot }) catch |err| {
                logz.debug().fmt("msg", "dropping git status snapshot: {any}", .{err}).log();
                snapshot.deinit();
            };

            var slept: u64 = 0;
            while (slept < refresh_interval_ns and !self.quit.load(.seq_cst)) {
                const step = @min(@as(u64, 100 * std.time.ns_per_ms), refresh_interval_ns - slept);
                sleepNs(step);
                slept += step;
            }
        }
    }
};

fn sleepNs(ns: u64) void {
    var req = std.c.timespec{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
    _ = std.c.nanosleep(&req, null);
}
