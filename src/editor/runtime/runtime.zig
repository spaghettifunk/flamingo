const std = @import("std");
const builtin = @import("builtin");
const event_queue = @import("event_queue.zig");
const syntax_worker = @import("syntax_worker.zig");
const git_status_worker = @import("git_status_worker.zig");
const git_diff_worker = @import("git_diff_worker.zig");
const task_worker = @import("task_worker.zig");
const mock_agent_worker = @import("mock_agent_worker.zig");
const lsp_manager = @import("../../lsp/manager.zig");
const perf = @import("../../perf/perf.zig");

pub const EditorRuntime = struct {
    pub const Options = struct {
        enable_git_worker: bool = true,
    };

    event_queue: *event_queue.EventQueue,
    syntax_parse_worker: *syntax_worker.SyntaxParseWorker,
    git_worker: ?*git_status_worker.GitStatusWorker = null,
    git_diff_worker: ?*git_diff_worker.GitDiffWorker = null,
    task_worker: task_worker.TaskWorker,
    mock_agent_worker: mock_agent_worker.MockAgentWorker,
    lsp_mgr: ?lsp_manager.LspManager = null,
    fps_sample_start_ns: ?i96 = null,
    fps_frame_count: usize = 0,
    fps: u32 = 0,
    perf_sampler: perf.PerfSampler = .{},

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !EditorRuntime {
        return initWithOptions(allocator, io, .{});
    }

    pub fn initWithOptions(allocator: std.mem.Allocator, io: std.Io, options: Options) !EditorRuntime {
        const queue = try allocator.create(event_queue.EventQueue);
        queue.* = event_queue.EventQueue.init(allocator, io);
        errdefer {
            queue.deinit();
            allocator.destroy(queue);
        }

        const mgr = try lsp_manager.LspManager.init(allocator, io, queue);
        errdefer {
            var owned_mgr = mgr;
            owned_mgr.deinit();
        }

        const parser_worker = try syntax_worker.SyntaxParseWorker.start(allocator, io, queue);
        errdefer parser_worker.stop();

        const git_worker = if (builtin.is_test or !options.enable_git_worker)
            null
        else
            try git_status_worker.GitStatusWorker.start(allocator, io, queue);
        errdefer if (git_worker) |worker| worker.stop();

        const diff_worker = if (builtin.is_test or !options.enable_git_worker)
            null
        else
            try git_diff_worker.GitDiffWorker.start(allocator, io, queue);
        errdefer if (diff_worker) |worker| worker.stop();

        return .{
            .event_queue = queue,
            .syntax_parse_worker = parser_worker,
            .git_worker = git_worker,
            .git_diff_worker = diff_worker,
            .task_worker = task_worker.TaskWorker.init(allocator, io, queue),
            .mock_agent_worker = mock_agent_worker.MockAgentWorker.init(allocator, io, queue),
            .lsp_mgr = mgr,
            .perf_sampler = perf.PerfSampler.initFromEnv(),
        };
    }

    pub fn deinit(self: *EditorRuntime, allocator: std.mem.Allocator) void {
        if (self.git_worker) |worker| {
            worker.stop();
            self.git_worker = null;
        }
        if (self.git_diff_worker) |worker| {
            worker.stop();
            self.git_diff_worker = null;
        }
        self.mock_agent_worker.deinit();
        self.task_worker.deinit();
        self.syntax_parse_worker.stop();

        if (self.lsp_mgr) |*mgr| {
            mgr.deinit();
            self.lsp_mgr = null;
        }

        self.event_queue.close();
        self.event_queue.deinit();
        allocator.destroy(self.event_queue);
    }

    pub fn updateFps(self: *EditorRuntime, io: std.Io) void {
        const now = std.Io.Timestamp.now(io, .awake).nanoseconds;

        if (self.fps_sample_start_ns == null) {
            self.fps_sample_start_ns = now;
            self.fps_frame_count = 0;
            self.fps = 0;
            return;
        }

        self.fps_frame_count += 1;
        const elapsed_ns = now - self.fps_sample_start_ns.?;
        if (elapsed_ns >= std.time.ns_per_s) {
            const frames: i128 = @intCast(self.fps_frame_count);
            self.fps = @intCast(@divTrunc(frames * std.time.ns_per_s, @as(i128, elapsed_ns)));
            self.fps_sample_start_ns = now;
            self.fps_frame_count = 0;
        }
    }

    pub fn updateFrameCapacityFps(self: *EditorRuntime, frame_ns: u64) void {
        if (frame_ns == 0) return;
        const fps = std.time.ns_per_s / frame_ns;
        self.fps = @intCast(@min(fps, 999));
    }
};

test "EditorRuntime frame capacity FPS clamps and ignores zero" {
    var runtime: EditorRuntime = undefined;
    runtime.fps = 12;

    runtime.updateFrameCapacityFps(0);
    try std.testing.expectEqual(@as(u32, 12), runtime.fps);

    runtime.updateFrameCapacityFps(1);
    try std.testing.expectEqual(@as(u32, 999), runtime.fps);

    runtime.updateFrameCapacityFps(std.time.ns_per_s / 60);
    try std.testing.expectEqual(@as(u32, 60), runtime.fps);
}
