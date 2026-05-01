const std = @import("std");
const logz = @import("logz");

pub const Phase = enum {
    input_poll,
    event_processing,
    update_state,
    highlight_viewport,
    build_frame,
    flush_output,
    total_loop,

    fn name(self: Phase) []const u8 {
        return switch (self) {
            .input_poll => "input_poll",
            .event_processing => "event_processing",
            .update_state => "update_state",
            .highlight_viewport => "highlight_viewport",
            .build_frame => "build_frame",
            .flush_output => "flush_output",
            .total_loop => "total_loop",
        };
    }
};

pub const PhaseCount = @typeInfo(Phase).@"enum".fields.len;

pub const FrameMetrics = struct {
    phases_ns: [PhaseCount]u64 = [_]u64{0} ** PhaseCount,
    rendered: bool = false,
    fast_cursor_move: bool = false,
    bytes_emitted: usize = 0,

    pub fn add(self: *FrameMetrics, phase: Phase, duration_ns: u64) void {
        self.phases_ns[@intFromEnum(phase)] += duration_ns;
    }

    pub fn get(self: *const FrameMetrics, phase: Phase) u64 {
        return self.phases_ns[@intFromEnum(phase)];
    }
};

pub const PerfSampler = struct {
    enabled: bool = false,
    loop_ticks: u64 = 0,
    rendered_frames: u64 = 0,
    sample_rendered_frames: u64 = 0,
    sample_fast_cursor_moves: u64 = 0,
    sample_loop_ticks: u64 = 0,
    sample_bytes: u64 = 0,
    totals_ns: [PhaseCount]u128 = [_]u128{0} ** PhaseCount,

    pub fn initFromEnv() PerfSampler {
        var sampler = PerfSampler{};
        if (std.c.getenv("FLAMINGO_PERF")) |value_z| {
            const value = std.mem.span(value_z);
            sampler.enabled = value.len == 0 or
                std.mem.eql(u8, value, "1") or
                std.mem.eql(u8, value, "true") or
                std.mem.eql(u8, value, "yes");
        }
        return sampler;
    }

    pub fn observe(self: *PerfSampler, metrics: FrameMetrics) void {
        if (!self.enabled) return;

        self.loop_ticks += 1;
        self.sample_loop_ticks += 1;
        if (metrics.rendered) {
            self.rendered_frames += 1;
            self.sample_rendered_frames += 1;
        }
        if (metrics.fast_cursor_move) {
            self.sample_fast_cursor_moves += 1;
        }
        self.sample_bytes += metrics.bytes_emitted;

        inline for (@typeInfo(Phase).@"enum".fields) |field| {
            const phase: Phase = @enumFromInt(field.value);
            self.totals_ns[@intFromEnum(phase)] += metrics.get(phase);
        }

        if (self.sample_rendered_frames >= 60) {
            self.flush();
        }
    }

    pub fn flush(self: *PerfSampler) void {
        if (!self.enabled or self.sample_loop_ticks == 0) return;

        var averages: [PhaseCount]u64 = [_]u64{0} ** PhaseCount;
        inline for (@typeInfo(Phase).@"enum".fields) |field| {
            const phase: Phase = @enumFromInt(field.value);
            averages[@intFromEnum(phase)] = @intCast(self.totals_ns[@intFromEnum(phase)] / self.sample_loop_ticks);
        }

        logz.info()
            .fmt("msg",
                "perf loops={d} rendered={d} fast_cursor={d} bytes={d} avg_ns {s}={d} {s}={d} {s}={d} {s}={d} {s}={d} {s}={d} {s}={d}",
                .{
                    self.sample_loop_ticks,
                    self.sample_rendered_frames,
                    self.sample_fast_cursor_moves,
                    self.sample_bytes,
                    Phase.input_poll.name(),
                    averages[@intFromEnum(Phase.input_poll)],
                    Phase.event_processing.name(),
                    averages[@intFromEnum(Phase.event_processing)],
                    Phase.update_state.name(),
                    averages[@intFromEnum(Phase.update_state)],
                    Phase.highlight_viewport.name(),
                    averages[@intFromEnum(Phase.highlight_viewport)],
                    Phase.build_frame.name(),
                    averages[@intFromEnum(Phase.build_frame)],
                    Phase.flush_output.name(),
                    averages[@intFromEnum(Phase.flush_output)],
                    Phase.total_loop.name(),
                    averages[@intFromEnum(Phase.total_loop)],
                },
            )
            .log();

        self.sample_rendered_frames = 0;
        self.sample_fast_cursor_moves = 0;
        self.sample_loop_ticks = 0;
        self.sample_bytes = 0;
        self.totals_ns = [_]u128{0} ** PhaseCount;
    }
};

pub inline fn nowNs() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) {
        return 0;
    }
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

pub inline fn elapsedNs(start_ns: u64) u64 {
    return nowNs() - start_ns;
}

pub fn sleepNs(ns: u64) void {
    const req = std.c.timespec{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
    _ = std.c.nanosleep(&req, null);
}

test "frame metrics records named phases" {
    var metrics = FrameMetrics{};
    metrics.add(.input_poll, 10);
    metrics.add(.input_poll, 5);
    metrics.add(.build_frame, 7);

    try std.testing.expectEqual(@as(u64, 15), metrics.get(.input_poll));
    try std.testing.expectEqual(@as(u64, 7), metrics.get(.build_frame));
    try std.testing.expectEqual(@as(u64, 0), metrics.get(.flush_output));
}
