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

pub const RenderKind = enum {
    none,
    fast_cursor,
    partial,
    full,
};

pub const FastCursorRejectReason = enum {
    mode,
    selection_active,
    multiple_cursors,
    tab_changed,
    viewport_changed,
    viewport_scrolled,
    explorer_focused,
    explorer_search_active,
    completion_active,
    search_active,
    no_active_tab,
    no_movement,
    cursor_outside_viewport,

    pub fn name(self: FastCursorRejectReason) []const u8 {
        return switch (self) {
            .mode => "mode",
            .selection_active => "selection",
            .multiple_cursors => "multi_cursor",
            .tab_changed => "tab_changed",
            .viewport_changed => "viewport_changed",
            .viewport_scrolled => "viewport_scrolled",
            .explorer_focused => "explorer_focused",
            .explorer_search_active => "explorer_search",
            .completion_active => "completion",
            .search_active => "search",
            .no_active_tab => "no_tab",
            .no_movement => "no_movement",
            .cursor_outside_viewport => "outside_viewport",
        };
    }
};

pub const FastCursorRejectReasonCount = @typeInfo(FastCursorRejectReason).@"enum".fields.len;

pub const FrameMetrics = struct {
    phases_ns: [PhaseCount]u64 = [_]u64{0} ** PhaseCount,
    rendered: bool = false,
    fast_cursor_move: bool = false,
    fast_cursor_rejects: [FastCursorRejectReasonCount]u64 = [_]u64{0} ** FastCursorRejectReasonCount,
    render_kind: RenderKind = .none,
    bytes_emitted: usize = 0,
    input_events: usize = 0,
    cursor_move_events: usize = 0,
    write_count: usize = 0,
    input_to_update_ns: u64 = 0,
    update_to_flush_ns: u64 = 0,

    pub fn add(self: *FrameMetrics, phase: Phase, duration_ns: u64) void {
        self.phases_ns[@intFromEnum(phase)] += duration_ns;
    }

    pub fn get(self: *const FrameMetrics, phase: Phase) u64 {
        return self.phases_ns[@intFromEnum(phase)];
    }

    pub fn recordFastCursorReject(self: *FrameMetrics, reason: FastCursorRejectReason) void {
        self.fast_cursor_rejects[@intFromEnum(reason)] += 1;
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
    sample_input_events: u64 = 0,
    sample_cursor_move_events: u64 = 0,
    sample_write_count: u64 = 0,
    sample_render_kinds: [@typeInfo(RenderKind).@"enum".fields.len]u64 = [_]u64{0} ** @typeInfo(RenderKind).@"enum".fields.len,
    sample_fast_cursor_rejects: [FastCursorRejectReasonCount]u64 = [_]u64{0} ** FastCursorRejectReasonCount,
    total_input_to_update_ns: u128 = 0,
    total_update_to_flush_ns: u128 = 0,
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
        self.sample_input_events += metrics.input_events;
        self.sample_cursor_move_events += metrics.cursor_move_events;
        self.sample_write_count += metrics.write_count;
        self.sample_render_kinds[@intFromEnum(metrics.render_kind)] += 1;
        inline for (@typeInfo(FastCursorRejectReason).@"enum".fields) |field| {
            self.sample_fast_cursor_rejects[field.value] += metrics.fast_cursor_rejects[field.value];
        }
        self.total_input_to_update_ns += metrics.input_to_update_ns;
        self.total_update_to_flush_ns += metrics.update_to_flush_ns;

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

        const avg_input_to_update: u64 = @intCast(self.total_input_to_update_ns / self.sample_loop_ticks);
        const avg_update_to_flush: u64 = @intCast(self.total_update_to_flush_ns / self.sample_loop_ticks);

        logz.info()
            .fmt(
                "msg",
                "perf loops={d} rendered={d} fast_cursor={d} render_kind none={d} fast={d} partial={d} full={d} input_events={d} cursor_moves={d} writes={d} bytes={d} avg_ns input_to_update={d} update_to_flush={d} {s}={d} {s}={d} {s}={d} {s}={d} {s}={d} {s}={d} {s}={d}",
                .{
                    self.sample_loop_ticks,
                    self.sample_rendered_frames,
                    self.sample_fast_cursor_moves,
                    self.sample_render_kinds[@intFromEnum(RenderKind.none)],
                    self.sample_render_kinds[@intFromEnum(RenderKind.fast_cursor)],
                    self.sample_render_kinds[@intFromEnum(RenderKind.partial)],
                    self.sample_render_kinds[@intFromEnum(RenderKind.full)],
                    self.sample_input_events,
                    self.sample_cursor_move_events,
                    self.sample_write_count,
                    self.sample_bytes,
                    avg_input_to_update,
                    avg_update_to_flush,
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

        logz.info()
            .fmt(
                "msg",
                "perf fast_cursor_reject {s}={d} {s}={d} {s}={d} {s}={d} {s}={d} {s}={d} {s}={d} {s}={d} {s}={d} {s}={d} {s}={d} {s}={d} {s}={d}",
                .{
                    FastCursorRejectReason.mode.name(),
                    self.sample_fast_cursor_rejects[@intFromEnum(FastCursorRejectReason.mode)],
                    FastCursorRejectReason.selection_active.name(),
                    self.sample_fast_cursor_rejects[@intFromEnum(FastCursorRejectReason.selection_active)],
                    FastCursorRejectReason.multiple_cursors.name(),
                    self.sample_fast_cursor_rejects[@intFromEnum(FastCursorRejectReason.multiple_cursors)],
                    FastCursorRejectReason.tab_changed.name(),
                    self.sample_fast_cursor_rejects[@intFromEnum(FastCursorRejectReason.tab_changed)],
                    FastCursorRejectReason.viewport_changed.name(),
                    self.sample_fast_cursor_rejects[@intFromEnum(FastCursorRejectReason.viewport_changed)],
                    FastCursorRejectReason.viewport_scrolled.name(),
                    self.sample_fast_cursor_rejects[@intFromEnum(FastCursorRejectReason.viewport_scrolled)],
                    FastCursorRejectReason.explorer_focused.name(),
                    self.sample_fast_cursor_rejects[@intFromEnum(FastCursorRejectReason.explorer_focused)],
                    FastCursorRejectReason.explorer_search_active.name(),
                    self.sample_fast_cursor_rejects[@intFromEnum(FastCursorRejectReason.explorer_search_active)],
                    FastCursorRejectReason.completion_active.name(),
                    self.sample_fast_cursor_rejects[@intFromEnum(FastCursorRejectReason.completion_active)],
                    FastCursorRejectReason.search_active.name(),
                    self.sample_fast_cursor_rejects[@intFromEnum(FastCursorRejectReason.search_active)],
                    FastCursorRejectReason.no_active_tab.name(),
                    self.sample_fast_cursor_rejects[@intFromEnum(FastCursorRejectReason.no_active_tab)],
                    FastCursorRejectReason.no_movement.name(),
                    self.sample_fast_cursor_rejects[@intFromEnum(FastCursorRejectReason.no_movement)],
                    FastCursorRejectReason.cursor_outside_viewport.name(),
                    self.sample_fast_cursor_rejects[@intFromEnum(FastCursorRejectReason.cursor_outside_viewport)],
                },
            )
            .log();

        self.sample_rendered_frames = 0;
        self.sample_fast_cursor_moves = 0;
        self.sample_loop_ticks = 0;
        self.sample_bytes = 0;
        self.sample_input_events = 0;
        self.sample_cursor_move_events = 0;
        self.sample_write_count = 0;
        self.sample_render_kinds = [_]u64{0} ** @typeInfo(RenderKind).@"enum".fields.len;
        self.sample_fast_cursor_rejects = [_]u64{0} ** FastCursorRejectReasonCount;
        self.total_input_to_update_ns = 0;
        self.total_update_to_flush_ns = 0;
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
