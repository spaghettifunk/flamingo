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
    partial,
    full,
};

pub const KeypressRenderKind = enum {
    none,
    virtual,

    pub fn name(self: KeypressRenderKind) []const u8 {
        return switch (self) {
            .none => "none",
            .virtual => "virtual",
        };
    }
};

pub const KeypressDirtyState = enum {
    clean,
    partial,
    full,

    pub fn name(self: KeypressDirtyState) []const u8 {
        return switch (self) {
            .clean => "clean",
            .partial => "partial",
            .full => "full",
        };
    }
};

pub const KeypressTrace = struct {
    key: []const u8 = "Unknown",
    mode: []const u8 = "Unknown",
    batch_count: usize = 1,
    coalesced: bool = false,
    pending_key_stored: bool = false,
    coalesce_stop_reason: []const u8 = "not_eligible",
    before_row: usize = 0,
    before_col: usize = 0,
    after_row: usize = 0,
    after_col: usize = 0,
    before_scroll_row: usize = 0,
    after_scroll_row: usize = 0,
    scroll_delta: i64 = 0,
    movement_handled: bool = false,
    cursor_moved: bool = false,
    viewport_scrolled: bool = false,
    dirty: KeypressDirtyState = .clean,
    render: KeypressRenderKind = .none,
    render_path_reason: []const u8 = "none",
    reject: []const u8 = "none",
    explorer_visible: bool = false,
    explorer_focused: bool = false,
    completion_active: bool = false,
    search_active: bool = false,
    selection_active: bool = false,
    bytes_emitted: usize = 0,
    virtual_emit_bytes: usize = 0,
    visible_rows: usize = 0,
    visible_chars: usize = 0,
    line_byte_reads: usize = 0,
    line_slice_calls: usize = 0,
    syntax_cache: []const u8 = "unknown",
    read_ns: u64 = 0,
    dispatch_ns: u64 = 0,
    decision_ns: u64 = 0,
    highlight_ns: u64 = 0,
    tabs_ns: u64 = 0,
    visible_lines_ns: u64 = 0,
    status_ns: u64 = 0,
    popup_ns: u64 = 0,
    virtual_emit_ns: u64 = 0,
    render_ns: u64 = 0,
    write_ns: u64 = 0,
    total_ns: u64 = 0,
};

pub const KeypressProfiler = struct {
    const log_path = "/tmp/flamingo-perf-keys.log";

    io: std.Io,
    enabled: bool = false,
    file: ?std.Io.File = null,

    pub fn initFromEnv(io: std.Io) KeypressProfiler {
        var profiler = KeypressProfiler{ .io = io };
        if (std.c.getenv("FLAMINGO_PERF_KEYS")) |value_z| {
            const value = std.mem.span(value_z);
            profiler.enabled = value.len == 0 or
                std.mem.eql(u8, value, "1") or
                std.mem.eql(u8, value, "true") or
                std.mem.eql(u8, value, "yes");
        }
        return profiler;
    }

    pub fn deinit(self: *KeypressProfiler) void {
        if (self.file) |file| {
            file.close(self.io);
            self.file = null;
        }
    }

    pub fn observe(self: *KeypressProfiler, trace: KeypressTrace) void {
        if (!self.enabled) return;
        const file = self.ensureFile() orelse return;

        var buf: [2048]u8 = undefined;
        const part1 = std.fmt.bufPrint(
            &buf,
            "key={s} mode={s} before={d}:{d} after={d}:{d} scroll={d}:0->{d}:0 handled={d} moved={d} scrolled={d} viewport_scrolled={d} scroll_delta={d} batch_count={d} coalesced={d} pending_key_stored={d} coalesce_stop_reason={s} dirty={s} render={s} render_path={s} reason={s} reject={s} explorer=visible:{d}/focused:{d} completion={d} search={d} selection={d} ",
            .{
                trace.key,
                trace.mode,
                trace.before_row,
                trace.before_col,
                trace.after_row,
                trace.after_col,
                trace.before_scroll_row,
                trace.after_scroll_row,
                boolBit(trace.movement_handled),
                boolBit(trace.cursor_moved),
                boolBit(trace.viewport_scrolled),
                boolBit(trace.viewport_scrolled),
                trace.scroll_delta,
                trace.batch_count,
                boolBit(trace.coalesced),
                boolBit(trace.pending_key_stored),
                trace.coalesce_stop_reason,
                trace.dirty.name(),
                trace.render.name(),
                trace.render.name(),
                trace.render_path_reason,
                trace.reject,
                boolBit(trace.explorer_visible),
                boolBit(trace.explorer_focused),
                boolBit(trace.completion_active),
                boolBit(trace.search_active),
                boolBit(trace.selection_active),
            },
        ) catch return;
        if (!self.writeLogPart(file, part1)) return;

        const part2 = std.fmt.bufPrint(
            &buf,
            "bytes={d} visible_rows={d} visible_chars={d} line_byte_reads={d} line_slice_calls={d} syntax_cache={s} highlight_us={d} tabs_us={d} visible_lines_us={d} status_us={d} popup_us={d} virtual_emit_us={d} ",
            .{
                trace.bytes_emitted,
                trace.visible_rows,
                trace.visible_chars,
                trace.line_byte_reads,
                trace.line_slice_calls,
                trace.syntax_cache,
                nsToUs(trace.highlight_ns),
                nsToUs(trace.tabs_ns),
                nsToUs(trace.visible_lines_ns),
                nsToUs(trace.status_ns),
                nsToUs(trace.popup_ns),
                nsToUs(trace.virtual_emit_ns),
            },
        ) catch return;
        if (!self.writeLogPart(file, part2)) return;

        const part3 = std.fmt.bufPrint(
            &buf,
            "read_us={d} dispatch_us={d} decision_us={d} render_us={d} write_us={d} total_us={d}\n",
            .{
                nsToUs(trace.read_ns),
                nsToUs(trace.dispatch_ns),
                nsToUs(trace.decision_ns),
                nsToUs(trace.render_ns),
                nsToUs(trace.write_ns),
                nsToUs(trace.total_ns),
            },
        ) catch return;
        _ = self.writeLogPart(file, part3);
    }

    fn writeLogPart(self: *KeypressProfiler, file: std.Io.File, text: []const u8) bool {
        file.writeStreamingAll(self.io, text) catch {
            self.disable();
            return false;
        };
        return true;
    }

    fn ensureFile(self: *KeypressProfiler) ?std.Io.File {
        if (self.file) |file| return file;
        const file = std.Io.Dir.createFileAbsolute(self.io, log_path, .{ .truncate = true }) catch {
            self.disable();
            return null;
        };
        self.file = file;
        return file;
    }

    fn disable(self: *KeypressProfiler) void {
        if (self.file) |file| {
            file.close(self.io);
            self.file = null;
        }
        self.enabled = false;
    }
};

fn boolBit(value: bool) u8 {
    return if (value) 1 else 0;
}

fn nsToUs(ns: u64) u64 {
    return ns / std.time.ns_per_us;
}

pub const FrameMetrics = struct {
    phases_ns: [PhaseCount]u64 = [_]u64{0} ** PhaseCount,
    rendered: bool = false,
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
};

pub const PerfSampler = struct {
    enabled: bool = false,
    loop_ticks: u64 = 0,
    rendered_frames: u64 = 0,
    sample_rendered_frames: u64 = 0,
    sample_loop_ticks: u64 = 0,
    sample_bytes: u64 = 0,
    sample_input_events: u64 = 0,
    sample_cursor_move_events: u64 = 0,
    sample_write_count: u64 = 0,
    sample_render_kinds: [@typeInfo(RenderKind).@"enum".fields.len]u64 = [_]u64{0} ** @typeInfo(RenderKind).@"enum".fields.len,
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
        self.sample_bytes += metrics.bytes_emitted;
        self.sample_input_events += metrics.input_events;
        self.sample_cursor_move_events += metrics.cursor_move_events;
        self.sample_write_count += metrics.write_count;
        self.sample_render_kinds[@intFromEnum(metrics.render_kind)] += 1;
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
                "perf loops={d} rendered={d} render_kind none={d} partial={d} full={d} input_events={d} cursor_moves={d} writes={d} bytes={d} avg_ns input_to_update={d} update_to_flush={d} {s}={d} {s}={d} {s}={d} {s}={d} {s}={d} {s}={d} {s}={d}",
                .{
                    self.sample_loop_ticks,
                    self.sample_rendered_frames,
                    self.sample_render_kinds[@intFromEnum(RenderKind.none)],
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

        self.sample_rendered_frames = 0;
        self.sample_loop_ticks = 0;
        self.sample_bytes = 0;
        self.sample_input_events = 0;
        self.sample_cursor_move_events = 0;
        self.sample_write_count = 0;
        self.sample_render_kinds = [_]u64{0} ** @typeInfo(RenderKind).@"enum".fields.len;
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
