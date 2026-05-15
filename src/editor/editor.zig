const std = @import("std");
const logz = @import("logz");
const config = @import("../config.zig");
const terminal = @import("../terminal.zig");
const buffer = @import("model/buffer.zig");
const input = @import("input_router/router.zig");
const search = @import("search.zig");
const global_search = @import("global_search.zig");
const syntax = @import("syntax.zig");
const perf = @import("../perf/perf.zig");
const render_mod = @import("renderer/virtual_screen.zig");
const lsp_manager = @import("../lsp/manager.zig");
const logger = @import("../logger.zig");
const tab_mod = @import("model/tab.zig");
const state_mod = @import("state/state.zig");
const runtime_mod = @import("runtime/runtime.zig");
const renderer_mod = @import("renderer/renderer.zig");
const keybindings = @import("input_router/keybindings.zig");
const filesystem_picker = @import("filesystem_picker.zig");
const prompt_popup = @import("prompt_popup.zig");
const terminal_panel_mod = @import("terminal_panel.zig");

const max_fifo_events_per_idle_tick = 8;
const syntax_parse_idle_delay_ns = 50 * std.time.ns_per_ms;
const max_tab_name_width = 15;
const tab_prefix_width = 2;
const tab_separator = " | ";

pub const EditorMode = state_mod.EditorMode;
pub const Pos = tab_mod.Pos;
pub const Cursor = tab_mod.Cursor;
pub const Tab = tab_mod.Tab;
pub const ResolvedKeybindings = keybindings.ResolvedKeybindings;
const FastCursorRejectReason = perf.FastCursorRejectReason;
const max_movement_coalesce_batch_count = 64;

const CoalescedMovement = enum {
    up,
    down,
    left,
    right,
};

const MovementCoalesceStopReason = enum {
    none,
    not_eligible,
    no_pending_input,
    different_key,
    mode_changed,
    overlay_active,
    selection_active,
    max_batch,
    pending_sequence,
    read_error,
    unknown,

    fn name(self: MovementCoalesceStopReason) []const u8 {
        return switch (self) {
            .none => "none",
            .not_eligible => "not_eligible",
            .no_pending_input => "no_pending_input",
            .different_key => "different_key",
            .mode_changed => "mode_changed",
            .overlay_active => "overlay_active",
            .selection_active => "selection_active",
            .max_batch => "max_batch",
            .pending_sequence => "pending_sequence",
            .read_error => "read_error",
            .unknown => "unknown",
        };
    }
};

const MovementCoalesceSnapshot = struct {
    mode: EditorMode,
    active_tab_index: usize,
    tab_count: usize,
    buffer_ptr: *const buffer.Buffer,
    buffer_revision: u64,
    cursor_count: usize,
};

const CoalescingCandidate = struct {
    movement: CoalescedMovement,
    event: terminal.KeyEvent,
    snapshot: MovementCoalesceSnapshot,
};

const MovementCoalesceEligibility = union(enum) {
    eligible: CoalescingCandidate,
    blocked: MovementCoalesceStopReason,
};

const InputKeyRead = struct {
    event: terminal.KeyEvent,
    read_start_ns: u64,
    read_elapsed_ns: u64,
    from_pending: bool = false,
};

const RuntimeKeyDispatch = struct {
    update_end_ns: u64,
    update_elapsed_ns: u64,
    movement_handled: bool,
};

pub const HorizontalScrollCommand = enum {
    left_small,
    right_small,
    left_half,
    right_half,
    cursor_start,
    cursor_end,
};

const CursorMoveState = struct {
    row: usize,
    col: usize,
    scroll_row: usize,
    scroll_col: usize,
    mode: EditorMode,
    cursor_count: usize,
    had_selection: bool,
    active_tab_index: usize,
    tab_count: usize,
    buffer_ptr: *const buffer.Buffer,
    width: usize,
    height: usize,
    buf_start_col: usize,
    buf_width: usize,
    visible_rows: usize,
    gutter_width: usize,
};

const StatusFieldCache = struct {
    terminal_col: usize = 0,
    width: usize = 0,
    valid: bool = false,
};

const StatusLayoutCache = struct {
    width: usize = 0,
    height: usize = 0,
    cursor: StatusFieldCache = .{},
    percent: StatusFieldCache = .{},
    last_cursor_row: usize = 0,
    last_cursor_col: usize = 0,
    last_percent: usize = 0,
    valid: bool = false,

    fn invalidate(self: *StatusLayoutCache) void {
        self.* = .{};
    }
};

const TabBarLayout = struct {
    total_width: usize,
    scroll_col: usize,
    content_start_col: usize,
    content_width: usize,
    has_hidden_left: bool,
    has_hidden_right: bool,
};

const RightStatusLayout = struct {
    text: []const u8,
    cursor_offset: usize = 0,
    cursor_width: usize = 0,
    cursor_valid: bool = false,
    percent_offset: usize = 0,
    percent_width: usize = 0,
    percent_valid: bool = false,
    cursor_row: usize = 0,
    cursor_col: usize = 0,
    percent: usize = 0,
};

const RenderContext = struct {
    tab: ?*Tab,
    buf_start_col: usize,
    buf_width: usize,
    gutter_width: usize,
    visible_rows: usize,
};

const CommandPopupGeometry = struct {
    row: usize,
    col: usize,
    width: usize,
    suggestion_count: usize,
};

const command_popup_title = " Cmdline ";
const global_search_popup_title = " Search ";
const filesystem_picker_border_ansi = "\x1b[48;5;235m\x1b[38;5;117m";
const prompt_popup_border_ansi = "\x1b[48;5;235m\x1b[38;5;204m";
const command_popup_border_ansi = "\x1b[48;5;235m\x1b[38;5;121m";
const global_search_popup_border_ansi = "\x1b[48;5;235m\x1b[38;5;220m";

const GlobalSearchRenderRow = union(enum) {
    header: []const u8,
    path: usize,
    content: usize,
};

const SelectionRange = struct {
    start_col: usize,
    end_col: usize,

    fn contains(self: SelectionRange, col: usize) bool {
        return col >= self.start_col and col < self.end_col;
    }
};

const LineRenderState = struct {
    line: *const buffer.Line,
    content_width: usize,
    syntax_cursor: syntax.HighlightRunCursor,
    search_match: ?search.Match,
    active_match_col: ?usize,
    selection_ranges: []const SelectionRange,

    fn syntaxStyleAt(self: *LineRenderState, col: usize) ?syntax.Style {
        return self.syntax_cursor.styleAt(col);
    }

    fn isSelected(self: *const LineRenderState, col: usize) bool {
        for (self.selection_ranges) |range| {
            if (range.contains(col)) return true;
        }
        return false;
    }
};

const TextSnapshot = struct {
    revision: u64,
    text: []u8,
};

const KeypressProfilePosition = struct {
    row: usize = 0,
    col: usize = 0,
    scroll_row: usize = 0,
    selection_active: bool = false,
};

pub const Editor = struct {
    config: config.Config,
    keys: ResolvedKeybindings,
    allocator: std.mem.Allocator,
    io: std.Io,
    state: state_mod.EditorState,
    terminal_panel: terminal_panel_mod.TerminalPanel,
    runtime: runtime_mod.EditorRuntime,
    renderer: renderer_mod.EditorRenderer,
    keypress_profiler: perf.KeypressProfiler,
    active_keypress_trace: ?*perf.KeypressTrace = null,
    pending_key: ?terminal.KeyEvent = null,
    last_input_movement_handled: bool = false,
    width: usize = 0,
    height: usize = 0,
    should_quit: bool = false,
    is_deinitialized: bool = false,
    last_status_minute: i64 = -1,
    status_cache: StatusLayoutCache = .{},

    pub fn init(allocator: std.mem.Allocator, io: std.Io, cfg: config.Config) !Editor {
        return initWithRuntimeOptions(allocator, io, cfg, .{});
    }

    pub fn initWithRuntimeOptions(allocator: std.mem.Allocator, io: std.Io, cfg: config.Config, runtime_options: runtime_mod.EditorRuntime.Options) !Editor {
        var runtime = try runtime_mod.EditorRuntime.initWithOptions(allocator, io, runtime_options);
        errdefer runtime.deinit(allocator);

        return Editor{
            .allocator = allocator,
            .io = io,
            .config = cfg,
            .keys = ResolvedKeybindings.init(cfg.keybindings),
            .state = state_mod.EditorState.init(allocator),
            .terminal_panel = terminal_panel_mod.TerminalPanel.init(allocator),
            .runtime = runtime,
            .renderer = renderer_mod.EditorRenderer.init(allocator),
            .keypress_profiler = perf.KeypressProfiler.initFromEnv(io),
        };
    }

    pub fn deinit(self: *Editor) void {
        if (self.is_deinitialized) return;
        self.is_deinitialized = true;

        self.terminal_panel.deinit();
        self.runtime.deinit(self.allocator);
        self.state.deinit(self.allocator);
        self.renderer.deinit(self.allocator);
        self.keypress_profiler.deinit();
    }

    pub fn currentTab(self: *Editor) ?*Tab {
        return self.state.currentTab();
    }

    pub fn refreshKeybindings(self: *Editor) void {
        self.keys = ResolvedKeybindings.init(self.config.keybindings);
    }

    pub fn addTab(self: *Editor, buf: buffer.Buffer) !void {
        const added = try self.state.addTab(self.allocator, buf);
        self.markDirty(.full);
        if (!added) return;

        if (self.runtime.lsp_mgr) |*mgr| {
            if (self.currentTab()) |tab| if (tab.buf.filename) |fname| {
                mgr.startLspForFile(fname) catch |err| {
                    logz.err().fmt("msg", "Failed to start LSP: {any}", .{err}).log();
                };

                const content = try tab.buf.toOwnedTextSnapshot(self.allocator);
                defer self.allocator.free(content);

                mgr.notifyOpen(fname, content) catch |err| {
                    logz.err().fmt("msg", "Failed to notify open: {any}", .{err}).log();
                };
            };
        }
    }

    pub fn closeTab(self: *Editor) void {
        self.state.closeTab(self.allocator);
        self.markDirty(.full);
    }

    pub fn nextTab(self: *Editor) void {
        self.state.nextTab();
        self.markDirty(.full);
    }

    pub fn prevTab(self: *Editor) void {
        self.state.prevTab();
        self.markDirty(.full);
    }

    pub fn closeAllTabs(self: *Editor) void {
        self.state.closeAllTabs(self.allocator);
        self.markDirty(.full);
    }

    pub fn markDirty(self: *Editor, invalidation: render_mod.RenderInvalidation) void {
        self.state.render_dirty = true;
        if (invalidation == .full) {
            self.state.force_full_render = true;
            self.status_cache.invalidate();
        }
        self.renderer.screen_renderer.invalidate(invalidation);
    }

    pub fn renderBenchmarkFrame(self: *Editor, writer: anytype) !void {
        var metrics = perf.FrameMetrics{};
        try terminal.hideCursor(writer);
        if (self.canUseVirtualRenderer()) {
            try self.renderVirtual(writer, &metrics);
        } else {
            try self.render(writer);
            try self.renderCompletionMenu(writer);
        }
        try terminal.showCursor(writer);
    }

    pub fn renderBenchmarkCursorMove(self: *Editor, writer: anytype, event: terminal.KeyEvent) !bool {
        const before = self.captureCursorMoveState() orelse return false;
        try self.handleRuntimeKey(event);
        if (!self.canFastRenderCursorMove(before)) return false;
        try self.renderFastCursorMove(writer, before);
        self.state.render_dirty = false;
        self.state.force_full_render = true;
        self.renderer.screen_renderer.invalidate(.full);
        return true;
    }

    pub fn run(self: *Editor) !void {
        const stdout = std.Io.File.stdout();
        const stdin = std.Io.File.stdin();
        var stdout_buf: [0]u8 = .{};
        var stdin_buf: [1]u8 = undefined;
        var stdout_writer = stdout.writerStreaming(self.io, &stdout_buf);
        var stdin_reader = stdin.readerStreaming(self.io, &stdin_buf);

        try terminal.enableRawMode(self.io);
        defer terminal.disableRawMode();

        const size = try terminal.getSize();
        self.width = size.cols;
        self.height = size.rows;

        try self.runWithIO(&stdin_reader.interface, &stdout_writer.interface);
    }

    /// Run the editor event loop with explicit reader/writer.
    /// Using generic I/O allows tests to inject a `fixedBufferStream` reader
    /// (synthetic key bytes) and an `ArrayList` writer (capture render output)
    /// without touching a real TTY.
    pub fn runWithIO(self: *Editor, reader: anytype, raw_writer: anytype) !void {
        var render_buffer = std.ArrayListUnmanaged(u8).empty;
        var aw = std.Io.Writer.Allocating.fromArrayList(self.allocator, &render_buffer);
        defer aw.deinit();
        const writer = &aw.writer;
        var last_input_ns: ?u64 = null;

        while (!self.should_quit) {
            const loop_start = perf.nowNs();
            var metrics = perf.FrameMetrics{};

            var handled_input = false;
            var first_fast_cursor_before: ?CursorMoveState = null;
            var fast_cursor_candidate = true;
            var last_update_end_ns: ?u64 = null;
            var key_trace_storage = perf.KeypressTrace{};
            var key_trace: ?*perf.KeypressTrace = null;
            var key_start_ns: u64 = 0;
            var key_name_buf: [32]u8 = undefined;
            var input_count: usize = 0;
            while (input_count < 128) : (input_count += 1) {
                const key_read = try self.readInputKey(reader, &metrics);
                const event = key_read.event;
                if (event.key == .None) break;
                handled_input = true;
                metrics.input_events += 1;

                var batch_count: usize = 1;
                var pending_key_stored = false;
                var coalesce_stop_reason: MovementCoalesceStopReason = .not_eligible;
                var coalescing_candidate: ?CoalescingCandidate = null;
                switch (self.movementCoalescingEligibilityBefore(event)) {
                    .eligible => |candidate| {
                        coalescing_candidate = candidate;
                        coalesce_stop_reason = .none;
                    },
                    .blocked => |reason| coalesce_stop_reason = reason,
                }

                if (self.keypress_profiler.enabled) {
                    key_start_ns = key_read.read_start_ns;
                    const key_name = formatKeyName(event, &key_name_buf);
                    key_trace_storage = self.initKeypressTrace(event, key_name);
                    key_trace_storage.read_ns = key_read.read_elapsed_ns;
                    key_trace = &key_trace_storage;
                }

                const render_after_event = self.shouldRenderAfterInputEvent(event);
                if (render_after_event) {
                    metrics.cursor_move_events += 1;
                    if (first_fast_cursor_before == null) {
                        first_fast_cursor_before = self.captureCursorMoveState();
                    }
                } else {
                    fast_cursor_candidate = false;
                }

                const dispatch = try self.dispatchRuntimeKeyForLoop(event, key_trace, &metrics);
                metrics.input_to_update_ns += dispatch.update_end_ns - key_read.read_start_ns;
                last_update_end_ns = dispatch.update_end_ns;
                last_input_ns = dispatch.update_end_ns;

                if (coalescing_candidate) |candidate| {
                    if (!dispatch.movement_handled) {
                        coalesce_stop_reason = .not_eligible;
                    } else if (self.coalescingStopReasonAfterMovement(candidate.snapshot)) |reason| {
                        coalesce_stop_reason = reason;
                    } else {
                        while (batch_count < max_movement_coalesce_batch_count and !self.should_quit) {
                            const drain_read_start = perf.nowNs();
                            const next_event = terminal.readKey(reader) catch |err| {
                                coalesce_stop_reason = .read_error;
                                if (key_trace) |trace| trace.coalesce_stop_reason = coalesce_stop_reason.name();
                                return err;
                            };
                            const drain_read_elapsed = perf.elapsedNs(drain_read_start);
                            metrics.add(.input_poll, drain_read_elapsed);
                            if (key_trace) |trace| trace.read_ns += drain_read_elapsed;

                            if (self.coalescingStopReasonForNext(candidate, next_event, batch_count)) |reason| {
                                coalesce_stop_reason = reason;
                                if (next_event.key != .None) {
                                    std.debug.assert(self.pending_key == null);
                                    self.pending_key = next_event;
                                    pending_key_stored = true;
                                }
                                break;
                            }

                            batch_count += 1;
                            metrics.input_events += 1;

                            const next_render_after_event = self.shouldRenderAfterInputEvent(next_event);
                            if (next_render_after_event) {
                                metrics.cursor_move_events += 1;
                                if (first_fast_cursor_before == null) {
                                    first_fast_cursor_before = self.captureCursorMoveState();
                                }
                            } else {
                                fast_cursor_candidate = false;
                            }

                            const next_dispatch = try self.dispatchRuntimeKeyForLoop(next_event, key_trace, &metrics);
                            metrics.input_to_update_ns += next_dispatch.update_end_ns - drain_read_start;
                            last_update_end_ns = next_dispatch.update_end_ns;
                            last_input_ns = next_dispatch.update_end_ns;

                            if (!next_dispatch.movement_handled) {
                                coalesce_stop_reason = .not_eligible;
                                break;
                            }
                            if (self.coalescingStopReasonAfterMovement(candidate.snapshot)) |reason| {
                                coalesce_stop_reason = reason;
                                break;
                            }
                        }
                        if (batch_count >= max_movement_coalesce_batch_count and coalesce_stop_reason == .none) {
                            coalesce_stop_reason = .max_batch;
                        } else if (coalesce_stop_reason == .none) {
                            coalesce_stop_reason = .no_pending_input;
                        }
                    }
                }

                if (key_trace) |trace| {
                    trace.batch_count = batch_count;
                    trace.coalesced = batch_count > 1;
                    trace.pending_key_stored = pending_key_stored;
                    trace.coalesce_stop_reason = coalesce_stop_reason.name();
                }

                if (self.should_quit) break;
                // Paint after the first input event, or after a bounded coalesced
                // movement batch when repeated movement keys were already queued.
                break;
            }

            if (!handled_input) {
                const events_start = perf.nowNs();
                try self.processBackgroundEvents(max_fifo_events_per_idle_tick);
                metrics.add(.event_processing, perf.elapsedNs(events_start));

                const update_start = perf.nowNs();
                try self.flushPendingLspChanges(false);
                self.updateStatusClockDirty();
                metrics.add(.update_state, perf.elapsedNs(update_start));
            }

            self.refreshTerminalSize();

            if (self.state.render_dirty) {
                if (key_trace) |trace| {
                    trace.dirty = self.keypressDirtyState();
                }
                aw.clearRetainingCapacity();

                var rendered_fast_cursor = false;
                var fast_cursor_render_before: ?CursorMoveState = null;
                var fast_reject_reason: ?FastCursorRejectReason = null;
                const decision_start = if (key_trace != null) perf.nowNs() else 0;
                if (fast_cursor_candidate) {
                    if (first_fast_cursor_before) |before| {
                        if (self.fastCursorMoveRejectReason(before)) |reason| {
                            fast_reject_reason = reason;
                            metrics.recordFastCursorReject(reason);
                        } else {
                            rendered_fast_cursor = true;
                            fast_cursor_render_before = before;
                        }
                    } else if (metrics.cursor_move_events > 0) {
                        fast_reject_reason = .no_active_tab;
                        metrics.recordFastCursorReject(.no_active_tab);
                    }
                }
                if (key_trace) |trace| {
                    const decision_elapsed = perf.elapsedNs(decision_start);
                    trace.decision_ns += decision_elapsed;
                    trace.can_use_virtual_renderer = self.canUseVirtualRenderer();
                    if (fast_reject_reason) |reason| {
                        trace.reject = reason.name();
                    } else {
                        trace.reject = "none";
                    }
                }

                const previous_render_trace = self.active_keypress_trace;
                self.active_keypress_trace = key_trace;
                defer self.active_keypress_trace = previous_render_trace;

                if (rendered_fast_cursor) {
                    const frame_start = perf.nowNs();
                    try self.renderFastCursorMove(writer, fast_cursor_render_before.?);
                    const render_elapsed = perf.elapsedNs(frame_start);
                    metrics.add(.build_frame, render_elapsed);
                    metrics.fast_cursor_move = true;
                    metrics.render_kind = .fast_cursor;
                    if (key_trace) |trace| {
                        trace.render = .fast_cursor;
                        trace.render_path_reason = self.renderPathReason(.fast_cursor, null);
                        trace.render_ns += render_elapsed;
                    }
                }

                if (!rendered_fast_cursor) {
                    const frame_start = perf.nowNs();
                    try terminal.hideCursor(writer);
                    const use_virtual_renderer = self.canUseVirtualRenderer();
                    if (key_trace) |trace| {
                        trace.can_use_virtual_renderer = use_virtual_renderer;
                        trace.render = if (use_virtual_renderer) .virtual else .legacy;
                        trace.render_path_reason = self.renderPathReason(trace.render, fast_reject_reason);
                    }
                    if (use_virtual_renderer) {
                        try self.renderVirtual(writer, &metrics);
                    } else {
                        try self.render(writer);
                        const completion_start = if (key_trace != null) perf.nowNs() else 0;
                        try self.renderCompletionMenu(writer);
                        if (key_trace) |trace| trace.popup_ns += perf.elapsedNs(completion_start);
                    }
                    try terminal.showCursor(writer);
                    const render_elapsed = perf.elapsedNs(frame_start);
                    metrics.add(.build_frame, render_elapsed);
                    if (key_trace) |trace| {
                        trace.render_ns += render_elapsed;
                    }
                    metrics.render_kind = if (self.state.force_full_render) .full else .partial;
                }

                const flush_start = perf.nowNs();
                if (last_update_end_ns) |update_end| {
                    metrics.update_to_flush_ns += flush_start - update_end;
                }
                const bytes = aw.written().len;
                try raw_writer.writeAll(aw.written());
                const write_elapsed = perf.elapsedNs(flush_start);
                metrics.add(.flush_output, write_elapsed);
                self.runtime.updateFrameCapacityFps(metrics.get(.build_frame) + metrics.get(.flush_output));
                metrics.rendered = true;
                metrics.bytes_emitted = bytes;
                metrics.write_count = 1;
                if (key_trace) |trace| {
                    trace.write_ns += write_elapsed;
                    trace.bytes_emitted = bytes;
                    trace.direct_write_bytes = bytes -| trace.virtual_emit_bytes;
                    trace.total_ns = perf.elapsedNs(key_start_ns);
                }
                self.state.render_dirty = false;
                if (!rendered_fast_cursor) {
                    self.state.force_full_render = false;
                }
            }

            if (!handled_input) {
                const syntax_request_start = perf.nowNs();
                const can_queue_syntax = if (last_input_ns) |last_input|
                    syntax_request_start - last_input >= syntax_parse_idle_delay_ns
                else
                    true;
                if (can_queue_syntax) {
                    try self.queueSyntaxParseForCurrentTab();
                }
                metrics.add(.update_state, perf.elapsedNs(syntax_request_start));
            }

            metrics.add(.total_loop, perf.elapsedNs(loop_start));
            self.runtime.perf_sampler.observe(metrics);

            if (handled_input) {
                if (key_trace) |trace| {
                    if (trace.total_ns == 0 and key_start_ns != 0) {
                        trace.total_ns = perf.elapsedNs(key_start_ns);
                    }
                    self.keypress_profiler.observe(trace.*);
                }
            }

            if (!self.state.render_dirty and !handled_input) {
                perf.sleepNs(1 * std.time.ns_per_ms);
            }
        }

        try self.flushPendingLspChanges(true);
        self.runtime.perf_sampler.flush();
        aw.clearRetainingCapacity();
        try terminal.clearScreen(writer);
        try terminal.moveCursor(writer, 1, 1);
        try raw_writer.writeAll(aw.written());
    }

    fn readInputKey(self: *Editor, reader: anytype, metrics: *perf.FrameMetrics) !InputKeyRead {
        const read_start = perf.nowNs();
        if (self.pending_key) |event| {
            self.pending_key = null;
            return .{
                .event = event,
                .read_start_ns = read_start,
                .read_elapsed_ns = 0,
                .from_pending = true,
            };
        }

        const event = try terminal.readKey(reader);
        const read_elapsed = perf.elapsedNs(read_start);
        metrics.add(.input_poll, read_elapsed);
        return .{
            .event = event,
            .read_start_ns = read_start,
            .read_elapsed_ns = read_elapsed,
        };
    }

    fn refreshTerminalSize(self: *Editor) void {
        const size = terminal.getSize() catch return;
        if (self.width == size.cols and self.height == size.rows) return;
        self.width = size.cols;
        self.height = size.rows;
        self.clampScroll();
        self.markDirty(.full);
    }

    fn dispatchRuntimeKeyForLoop(
        self: *Editor,
        event: terminal.KeyEvent,
        key_trace: ?*perf.KeypressTrace,
        metrics: *perf.FrameMetrics,
    ) !RuntimeKeyDispatch {
        const input_handle_start = perf.nowNs();
        self.last_input_movement_handled = false;
        {
            const previous_trace = self.active_keypress_trace;
            self.active_keypress_trace = key_trace;
            defer self.active_keypress_trace = previous_trace;
            try self.handleRuntimeKey(event);
        }
        const update_elapsed = perf.elapsedNs(input_handle_start);
        const update_end = perf.nowNs();
        if (key_trace) |trace| {
            trace.dispatch_ns += update_elapsed;
            self.updateKeypressTraceAfterDispatch(trace);
        }
        metrics.add(.update_state, update_elapsed);
        return .{
            .update_end_ns = update_end,
            .update_elapsed_ns = update_elapsed,
            .movement_handled = self.last_input_movement_handled,
        };
    }

    fn movementCoalescingEligibilityBefore(self: *Editor, event: terminal.KeyEvent) MovementCoalesceEligibility {
        if (self.state.mode != .Normal and self.state.mode != .Insert) return .{ .blocked = .overlay_active };
        if (self.state.error_message != null) return .{ .blocked = .not_eligible };
        if (self.state.explorer_focused) return .{ .blocked = .overlay_active };
        if (self.state.lsp_ui.completion_active) return .{ .blocked = .overlay_active };
        if (self.state.search_buffer.items.len > 0) return .{ .blocked = .overlay_active };
        if (self.state.tree) |tree| {
            if (tree.search_active) return .{ .blocked = .overlay_active };
        }
        if (self.state.mode == .Normal and self.state.pending_normal_sequence.len > 0) {
            return .{ .blocked = .pending_sequence };
        }
        if (event.shift) return .{ .blocked = .selection_active };

        const movement = self.coalescedMovementForEvent(event) orelse return .{ .blocked = .not_eligible };
        if (self.matchesNonSimpleMovement(event)) return .{ .blocked = .not_eligible };
        const tab = self.currentTab() orelse return .{ .blocked = .not_eligible };
        if (tab.cursors.items.len != 1) return .{ .blocked = .not_eligible };
        if (hasActiveSelection(tab)) return .{ .blocked = .selection_active };

        return .{ .eligible = .{
            .movement = movement,
            .event = event,
            .snapshot = .{
                .mode = self.state.mode,
                .active_tab_index = self.state.active_tab_index,
                .tab_count = self.state.tabs.items.len,
                .buffer_ptr = &tab.buf,
                .buffer_revision = tab.buf.revision,
                .cursor_count = tab.cursors.items.len,
            },
        } };
    }

    fn coalescedMovementForEvent(self: *Editor, event: terminal.KeyEvent) ?CoalescedMovement {
        if (event.ctrl or event.alt or event.shift) return null;

        const allowed_key = switch (event.key) {
            .Up, .Down, .Left, .Right => true,
            .Char => self.state.mode == .Normal and
                (event.char == 'h' or event.char == 'j' or event.char == 'k' or event.char == 'l'),
            else => false,
        };
        if (!allowed_key) return null;

        if (event.eql(self.keys.move_up)) return .up;
        if (event.eql(self.keys.move_down)) return .down;
        if (event.eql(self.keys.move_left)) return .left;
        if (event.eql(self.keys.move_right)) return .right;
        return null;
    }

    fn matchesNonSimpleMovement(self: *Editor, event: terminal.KeyEvent) bool {
        return event.eql(self.keys.line_start) or
            event.eql(self.keys.line_end) or
            event.eql(self.keys.word_left) or
            event.eql(self.keys.word_right);
    }

    fn coalescingStopReasonAfterMovement(self: *Editor, snapshot: MovementCoalesceSnapshot) ?MovementCoalesceStopReason {
        if (self.state.mode != snapshot.mode) return .mode_changed;
        if (self.state.mode != .Normal and self.state.mode != .Insert) return .mode_changed;
        if (self.state.explorer_focused) return .overlay_active;
        if (self.state.lsp_ui.completion_active) return .overlay_active;
        if (self.state.search_buffer.items.len > 0) return .overlay_active;
        if (self.state.tree) |tree| {
            if (tree.search_active) return .overlay_active;
        }
        if (self.state.mode == .Normal and self.state.pending_normal_sequence.len > 0) return .pending_sequence;
        if (self.state.tabs.items.len != snapshot.tab_count) return .unknown;
        if (self.state.active_tab_index != snapshot.active_tab_index) return .unknown;

        const tab = self.currentTab() orelse return .unknown;
        if (&tab.buf != snapshot.buffer_ptr) return .unknown;
        if (tab.buf.revision != snapshot.buffer_revision) return .unknown;
        if (tab.cursors.items.len != snapshot.cursor_count) return .unknown;
        if (hasActiveSelection(tab)) return .selection_active;
        return null;
    }

    fn coalescingStopReasonForNext(
        self: *Editor,
        candidate: CoalescingCandidate,
        event: terminal.KeyEvent,
        batch_count: usize,
    ) ?MovementCoalesceStopReason {
        if (batch_count >= max_movement_coalesce_batch_count) return .max_batch;
        if (event.key == .None) return .no_pending_input;
        if (self.coalescingStopReasonAfterMovement(candidate.snapshot)) |reason| return reason;
        const movement = self.coalescedMovementForEvent(event) orelse return .different_key;
        if (movement != candidate.movement or !event.eql(candidate.event)) return .different_key;
        return null;
    }

    fn hasActiveSelection(tab: *const Tab) bool {
        for (tab.cursors.items) |cursor| {
            if (cursor.selection_start != null) return true;
        }
        return false;
    }

    fn processBackgroundEvents(self: *Editor, max_fifo_events: usize) !void {
        var fifo_events_processed: usize = 0;
        while (fifo_events_processed < max_fifo_events) : (fifo_events_processed += 1) {
            const ev = self.runtime.event_queue.tryPop() orelse break;
            const event = ev;
            switch (event) {
                .lsp_message => |msg| {
                    defer self.allocator.free(msg.plugin_name);
                    defer self.allocator.free(msg.message);
                    try self.handleLspEvent(msg.plugin_name, msg.message);
                },
                .git_status_snapshot => |snapshot| {
                    if (self.state.git_snapshot) |*old| {
                        if (old.eql(&snapshot)) {
                            var duplicate = snapshot;
                            duplicate.deinit();
                            continue;
                        }
                    }
                    if (self.state.git_snapshot) |*old| old.deinit();
                    self.state.git_snapshot = snapshot;
                    self.markDirty(.partial);
                },
                .terminal_output => |output| {
                    defer self.allocator.free(output.bytes);
                    self.terminal_panel.appendOutput(output.bytes) catch |err| {
                        logz.err().fmt("msg", "failed to append terminal output: {any}", .{err}).log();
                    };
                    if (self.terminal_panel.visible) self.markDirty(.partial);
                },
                .terminal_exit => |exit| {
                    self.terminal_panel.markExited(exit.code) catch |err| {
                        logz.err().fmt("msg", "failed to record terminal exit: {any}", .{err}).log();
                    };
                    if (self.terminal_panel.visible) self.markDirty(.partial);
                },
                .syntax_parse_result => unreachable,
            }
        }

        var syntax_results = std.ArrayList(syntax.ParseResult).empty;
        defer syntax_results.deinit(self.allocator);
        self.runtime.event_queue.drainSyntaxResults(&syntax_results) catch |err| {
            logz.err().fmt("msg", "failed to drain syntax parse results: {any}", .{err}).log();
        };
        for (syntax_results.items) |*result| {
            defer result.deinit(self.allocator);
            self.handleSyntaxParseResult(result) catch |err| {
                logz.err().fmt("msg", "failed to install syntax parse result: {any}", .{err}).log();
            };
        }
    }

    fn updateStatusClockDirty(self: *Editor) void {
        const minute = self.currentMinute();
        if (minute != self.last_status_minute) {
            self.last_status_minute = minute;
            self.markDirty(.partial);
        }
    }

    fn handleLspEvent(self: *Editor, plugin_name: []const u8, message: []const u8) !void {
        if (self.runtime.lsp_mgr) |*mgr| {
            const res = mgr.handleMessage(plugin_name, message) catch |err| blk: {
                logz.err().fmt("msg", "Error handling LSP msg: {any}", .{err}).log();
                break :blk lsp_manager.LspManager.HandleResult.none;
            };

            switch (res) {
                .initialized => {
                    for (self.state.tabs.items) |tab| {
                        if (tab.buf.filename) |fname| {
                            const ext = std.fs.path.extension(fname);
                            if (mgr.plugin_mgr.getPluginForExtension(ext)) |p| {
                                if (std.mem.eql(u8, p.name, plugin_name)) {
                                    const content = try tab.buf.toOwnedTextSnapshot(self.allocator);
                                    defer self.allocator.free(content);
                                    mgr.notifyOpen(fname, content) catch {};
                                }
                            }
                        }
                    }
                },
                .completion => |items| {
                    if (!isValidCompletionValue(items)) {
                        mgr.freeValue(items);
                        return;
                    }
                    self.state.lsp_ui.replaceCompletion(items);
                    self.markDirty(.partial);
                },
                .diagnostics => |diag_val| {
                    var diagnostics_stored = false;
                    errdefer if (!diagnostics_stored) mgr.freeValue(diag_val);

                    const uri = diagnosticUri(diag_val) orelse return;
                    const fname = if (std.mem.startsWith(u8, uri, "file://")) uri[7..] else uri;
                    try self.state.lsp_ui.replaceDiagnostics(fname, diag_val);
                    diagnostics_stored = true;
                    self.markDirty(.partial);
                },
                .none => {},
            }
        }
    }

    pub fn noteKeypressMovementHandled(self: *Editor, handled: bool) void {
        if (!handled) return;
        self.last_input_movement_handled = true;
        if (self.active_keypress_trace) |trace| {
            trace.movement_handled = true;
        }
    }

    fn captureKeypressProfilePosition(self: *Editor) KeypressProfilePosition {
        const tab = self.currentTab() orelse return .{};
        if (tab.cursors.items.len == 0) return .{ .scroll_row = tab.scroll_row };
        const mc = tab.mainCursor();
        return .{
            .row = mc.row,
            .col = mc.col,
            .scroll_row = tab.scroll_row,
            .selection_active = mc.selection_start != null,
        };
    }

    fn initKeypressTrace(self: *Editor, event: terminal.KeyEvent, key_name: []const u8) perf.KeypressTrace {
        const pos = self.captureKeypressProfilePosition();
        return .{
            .key = key_name,
            .mode = @tagName(self.state.mode),
            .before_row = pos.row,
            .before_col = pos.col,
            .after_row = pos.row,
            .after_col = pos.col,
            .before_scroll_row = pos.scroll_row,
            .after_scroll_row = pos.scroll_row,
            .dirty = self.keypressDirtyState(),
            .can_use_virtual_renderer = self.canUseVirtualRenderer(),
            .explorer_visible = self.state.explorer_visible,
            .explorer_focused = self.state.explorer_focused,
            .completion_active = self.state.lsp_ui.completion_active,
            .search_active = self.state.search_buffer.items.len > 0,
            .selection_active = pos.selection_active or event.shift,
        };
    }

    fn updateKeypressTraceAfterDispatch(self: *Editor, trace: *perf.KeypressTrace) void {
        const pos = self.captureKeypressProfilePosition();
        trace.after_row = pos.row;
        trace.after_col = pos.col;
        trace.after_scroll_row = pos.scroll_row;
        trace.scroll_delta = signedDelta(trace.before_scroll_row, pos.scroll_row);
        trace.cursor_moved = trace.before_row != pos.row or trace.before_col != pos.col;
        trace.viewport_scrolled = trace.viewport_scrolled or trace.before_scroll_row != pos.scroll_row;
        trace.can_use_virtual_renderer = self.canUseVirtualRenderer();
        trace.explorer_visible = self.state.explorer_visible;
        trace.explorer_focused = self.state.explorer_focused;
        trace.completion_active = self.state.lsp_ui.completion_active;
        trace.search_active = self.state.search_buffer.items.len > 0;
        trace.selection_active = trace.selection_active or pos.selection_active;
    }

    fn signedDelta(before: usize, after: usize) i64 {
        if (after >= before) return @intCast(after - before);
        return -@as(i64, @intCast(before - after));
    }

    fn keypressDirtyState(self: *const Editor) perf.KeypressDirtyState {
        if (!self.state.render_dirty) return .clean;
        if (self.state.force_full_render) return .full;
        return .partial;
    }

    fn renderPathReason(self: *const Editor, render_kind: perf.KeypressRenderKind, fast_reject_reason: ?FastCursorRejectReason) []const u8 {
        switch (render_kind) {
            .none => return "none",
            .fast_cursor => return "fast_cursor",
            .virtual => {
                if (fast_reject_reason) |reason| {
                    if (reason == .viewport_scrolled) return "viewport_scrolled";
                }
                return "virtual_allowed";
            },
            .legacy => {
                if (self.state.mode == .Dashboard or self.state.mode == .OpenFilePrompt) return "legacy_dashboard";
                if (self.state.mode == .FilesystemPicker) return "legacy_picker";
                if (self.state.mode == .Prompt) return "legacy_prompt";
                if (self.state.explorer_visible) return "legacy_explorer_visible";
                if (self.state.lsp_ui.completion_active) return "legacy_completion_active";
                return "legacy_unknown";
            },
        }
    }

    fn formatKeyName(event: terminal.KeyEvent, buf: *[32]u8) []const u8 {
        var idx: usize = 0;
        idx = appendKeyPart(buf, idx, event.ctrl, "Ctrl+");
        idx = appendKeyPart(buf, idx, event.alt, "Alt+");
        idx = appendKeyPart(buf, idx, event.shift, "Shift+");

        const base = switch (event.key) {
            .None => "None",
            .Backspace => "Backspace",
            .Enter => "Enter",
            .Esc => "Esc",
            .Up => "Up",
            .Down => "Down",
            .Right => "Right",
            .Left => "Left",
            .Delete => "Delete",
            .Home => "Home",
            .End => "End",
            .PageUp => "PageUp",
            .PageDown => "PageDown",
            .Char => blk: {
                if (event.char == '\t') break :blk "Tab";
                if (event.char == ' ') break :blk "Space";
                if (event.char >= 0x21 and event.char <= 0x7e and idx + 1 <= buf.len) {
                    buf[idx] = event.char;
                    return buf[0 .. idx + 1];
                }
                break :blk "Char";
            },
        };

        idx = appendKeyBytes(buf, idx, base);
        return buf[0..idx];
    }

    fn appendKeyPart(buf: *[32]u8, idx: usize, enabled: bool, text: []const u8) usize {
        if (!enabled) return idx;
        return appendKeyBytes(buf, idx, text);
    }

    fn appendKeyBytes(buf: *[32]u8, start: usize, text: []const u8) usize {
        var idx = start;
        for (text) |ch| {
            if (idx >= buf.len) break;
            buf[idx] = ch;
            idx += 1;
        }
        return idx;
    }

    fn shouldRenderAfterInputEvent(self: *const Editor, event: terminal.KeyEvent) bool {
        if (event.key == .PageUp or event.key == .PageDown) return true;

        return movementEventMatches(event, self.keys.move_up) or
            movementEventMatches(event, self.keys.move_down) or
            movementEventMatches(event, self.keys.move_left) or
            movementEventMatches(event, self.keys.move_right) or
            movementEventMatches(event, self.keys.line_start) or
            movementEventMatches(event, self.keys.line_end) or
            movementEventMatches(event, self.keys.word_left) or
            movementEventMatches(event, self.keys.word_right) or
            movementEventMatches(event, self.keys.explorer_up) or
            movementEventMatches(event, self.keys.explorer_down);
    }

    fn movementEventMatches(event: terminal.KeyEvent, expected: terminal.KeyEvent) bool {
        if (event.eql(expected)) return true;

        var without_shift = event;
        without_shift.shift = false;
        return event.shift and without_shift.eql(expected);
    }

    fn captureCursorMoveState(self: *Editor) ?CursorMoveState {
        const tab = self.currentTab() orelse return null;
        if (tab.cursors.items.len == 0) return null;
        const mc = tab.mainCursor();
        const visible_rows = self.editorVisibleRows();
        const viewport = self.bufferViewportGeometry();
        return .{
            .row = mc.row,
            .col = mc.col,
            .scroll_row = tab.scroll_row,
            .scroll_col = tab.scroll_col,
            .mode = self.state.mode,
            .cursor_count = tab.cursors.items.len,
            .had_selection = mc.selection_start != null,
            .active_tab_index = self.state.active_tab_index,
            .tab_count = self.state.tabs.items.len,
            .buffer_ptr = &tab.buf,
            .width = self.width,
            .height = self.height,
            .buf_start_col = viewport.start_col,
            .buf_width = viewport.width,
            .visible_rows = visible_rows,
            .gutter_width = self.calculateGutterWidth(tab.buf.lines.items.len),
        };
    }

    fn bufferViewportGeometry(self: *const Editor) struct { start_col: usize, width: usize } {
        var buf_start_col: usize = 1;
        var buf_width: usize = self.width;

        if (self.state.explorer_visible and self.state.tree != null) {
            const exp_width = (self.width * @as(usize, self.config.explorer.width_percentage)) / 100;
            if (exp_width > 0) {
                buf_start_col = exp_width + 2;
                buf_width = self.width -| (exp_width + 1);
            }
        }

        return .{ .start_col = buf_start_col, .width = buf_width };
    }

    pub fn terminalPanelHeight(self: *const Editor) usize {
        if (!self.terminal_panel.visible) return 0;
        return terminal_panel_mod.panelHeight(self.height);
    }

    fn statusRowIndex(self: *const Editor) usize {
        const panel_height = self.terminalPanelHeight();
        if (self.height == 0) return 0;
        return self.height - panel_height - 1;
    }

    fn statusTerminalRow(self: *const Editor) usize {
        return self.statusRowIndex() + 1;
    }

    pub fn editorVisibleRows(self: *const Editor) usize {
        const top_reserved = 2;
        const bot_reserved = 1 + self.terminalPanelHeight();
        return if (self.height > top_reserved + bot_reserved) self.height - (top_reserved + bot_reserved) else 0;
    }

    fn terminalCursorScreenPosition(self: *Editor) struct { row: usize, col: usize } {
        const panel_height = self.terminalPanelHeight();
        if (panel_height <= 1 or self.height == 0 or self.width == 0) return .{ .row = self.height, .col = self.width };
        const body_height = panel_height - 1;
        self.terminal_panel.clampScroll(body_height);
        const total_lines = self.terminal_panel.renderLineCount();
        const end = total_lines -| @min(self.terminal_panel.scroll_offset, total_lines);
        const shown = @min(body_height, end);
        const first = end - shown;
        const cursor_index = self.terminal_panel.cursorRenderIndex();
        if (cursor_index < first or cursor_index >= first + shown) return .{ .row = self.height, .col = self.width };

        const row = self.height - panel_height + 2 + (cursor_index - first);
        const col = @min(self.terminal_panel.cursor_col + 1, self.width);
        return .{ .row = row, .col = col };
    }

    fn buildRenderContext(self: *Editor, status_buf: *[160]u8) RenderContext {
        const tab = self.currentTab();
        const viewport = self.bufferViewportGeometry();
        const gutter_width: usize = if (tab) |t|
            self.calculateGutterWidth(t.buf.lines.items.len)
        else
            0;
        const visible_rows = self.editorVisibleRows();

        _ = status_buf;

        return .{
            .tab = tab,
            .buf_start_col = viewport.start_col,
            .buf_width = viewport.width,
            .gutter_width = gutter_width,
            .visible_rows = visible_rows,
        };
    }

    fn buildStatusText(self: *Editor, tab: ?*Tab, buf: *[160]u8) ![]const u8 {
        if (self.state.mode == .Search) {
            if (self.state.search_system) |s| {
                if (s.matches.items.len > 0) {
                    return try std.fmt.bufPrint(buf, "/{s} ({d}/{d})", .{ self.state.search_buffer.items, (s.active_match_idx orelse 0) + 1, s.matches.items.len });
                }
                return try std.fmt.bufPrint(buf, "/{s} (no matches)", .{self.state.search_buffer.items});
            }
            return try std.fmt.bufPrint(buf, "/{s}", .{self.state.search_buffer.items});
        }
        if (self.state.error_message) |err_msg| {
            return try std.fmt.bufPrint(buf, "{s}", .{err_msg});
        }

        const mode_str = switch (self.state.mode) {
            .Command => "COMMAND",
            .GlobalSearch => "GLOBAL SEARCH",
            .FilesystemPicker => "FILES",
            .Prompt => "PROMPT",
            .Insert => "INSERT",
            .Search => "SEARCH",
            .Terminal => "TERMINAL",
            else => "NORMAL",
        };
        if (tab) |t| {
            const diag_count = if (t.buf.filename) |fname| self.state.lsp_ui.diagnosticCountForFile(fname) else 0;
            if (diag_count > 0) {
                return try std.fmt.bufPrint(buf, " {s}   {d}  {d}:{d} ", .{ mode_str, diag_count, t.mainCursor().row + 1, t.mainCursor().col + 1 });
            }
            return try std.fmt.bufPrint(buf, " {s}  {d}:{d} ", .{ mode_str, t.mainCursor().row + 1, t.mainCursor().col + 1 });
        }
        return try std.fmt.bufPrint(buf, " {s}  No file open ", .{mode_str});
    }

    fn canFastRenderCursorMove(self: *Editor, before: CursorMoveState) bool {
        return self.fastCursorMoveRejectReason(before) == null;
    }

    fn fastCursorMoveRejectReason(self: *Editor, before: CursorMoveState) ?FastCursorRejectReason {
        if (before.mode != .Normal and before.mode != .Insert) return .mode;
        if (self.state.mode != .Normal and self.state.mode != .Insert) return .mode;
        if (before.cursor_count != 1) return .multiple_cursors;
        if (before.had_selection) return .selection_active;
        if (self.state.tabs.items.len != before.tab_count) return .tab_changed;
        if (self.state.active_tab_index != before.active_tab_index) return .tab_changed;
        if (self.width != before.width or self.height != before.height) return .viewport_changed;
        if (self.state.explorer_focused) return .explorer_focused;
        if (self.state.tree) |tree| {
            if (tree.search_active) return .explorer_search_active;
        }
        if (self.state.lsp_ui.completion_active) return .completion_active;
        if (self.state.search_buffer.items.len > 0) return .search_active;

        const tab = self.currentTab() orelse return .no_active_tab;
        if (&tab.buf != before.buffer_ptr) return .tab_changed;
        if (tab.scroll_row != before.scroll_row) return .viewport_scrolled;
        if (tab.scroll_col != before.scroll_col) return .viewport_scrolled;
        if (tab.cursors.items.len != 1) return .multiple_cursors;
        if (tab.main_cursor_idx != 0) return .multiple_cursors;

        const mc = tab.mainCursor();
        const viewport = self.bufferViewportGeometry();
        if (viewport.start_col != before.buf_start_col or viewport.width != before.buf_width) return .viewport_changed;
        if (mc.selection_start != null) return .selection_active;
        if (mc.row == before.row and mc.col == before.col) return .no_movement;
        if (before.row < tab.scroll_row or before.row >= tab.scroll_row + before.visible_rows) return .cursor_outside_viewport;
        if (mc.row < tab.scroll_row or mc.row >= tab.scroll_row + before.visible_rows) return .cursor_outside_viewport;

        return null;
    }

    fn renderFastCursorMove(self: *Editor, writer: anytype, before: CursorMoveState) !void {
        const tab = self.currentTab() orelse return;
        const mc = tab.mainCursor();

        if (before.row == mc.row) {
            try self.renderLineNumberGutterAt(writer, tab, mc.row, true, before);
        } else {
            try self.renderLineNumberGutterAt(writer, tab, before.row, false, before);
            try self.renderLineNumberGutterAt(writer, tab, mc.row, true, before);
        }

        try self.renderFastStatusRightLegacy(writer, tab);

        const content_width = before.buf_width -| before.gutter_width;
        const vis_col = visibleCursorCol(mc.col, before.scroll_col, content_width);
        const vis_row = mc.row - tab.scroll_row + 3;
        try terminal.moveCursor(writer, vis_row, before.buf_start_col + before.gutter_width + vis_col);
    }

    fn renderFastStatusRightLegacy(self: *Editor, writer: anytype, tab: ?*Tab) !void {
        if (self.height == 0 or self.width == 0) return;
        const t = tab orelse return;
        if (!self.status_cache.valid or
            self.status_cache.width != self.width or
            self.status_cache.height != self.height or
            !self.status_cache.cursor.valid)
        {
            try self.renderStatusLineLegacyStyle(writer, tab);
            return;
        }

        const mc = t.mainCursor();
        const total_lines = t.buf.lines.items.len;
        const pct = statusScrollPercent(mc.row, total_lines);

        if (self.status_cache.percent.valid and pct != self.status_cache.last_percent) {
            var pct_buf: [8]u8 = undefined;
            const pct_text = std.fmt.bufPrint(&pct_buf, "{d}%", .{pct}) catch "";
            try self.writeFastStatusField(writer, self.status_cache.percent, pct_text);
            self.status_cache.last_percent = pct;
        }

        var cursor_buf: [32]u8 = undefined;
        const cursor_text = std.fmt.bufPrint(&cursor_buf, "{d}:{d}", .{ mc.row + 1, mc.col + 1 }) catch "";
        try self.writeFastStatusField(writer, self.status_cache.cursor, cursor_text);
        self.status_cache.last_cursor_row = mc.row;
        self.status_cache.last_cursor_col = mc.col;
    }

    fn writeFastStatusField(self: *Editor, writer: anytype, field: StatusFieldCache, text: []const u8) !void {
        if (!field.valid or field.width == 0 or field.terminal_col == 0) return;
        try terminal.moveCursor(writer, self.statusTerminalRow(), field.terminal_col);
        try writer.writeAll(render_mod.RenderStyle.status_right.ansi());

        var written: usize = 0;
        var i: usize = 0;
        while (i < text.len and written < field.width) : (written += 1) {
            const len = @min(render_mod.utf8CellLen(text[i]), text.len - i);
            try writer.writeAll(text[i .. i + len]);
            i += len;
        }
        while (written < field.width) : (written += 1) {
            try writer.writeByte(' ');
        }
        try writer.writeAll("\x1b[0m");
    }

    fn renderLineNumberGutterAt(self: *Editor, writer: anytype, tab: *Tab, line_idx: usize, is_current: bool, state: CursorMoveState) !void {
        _ = self;
        if (state.visible_rows == 0) return;
        if (line_idx < tab.scroll_row or line_idx >= tab.scroll_row + state.visible_rows) return;

        const screen_row = line_idx - tab.scroll_row + 3;
        try terminal.moveCursor(writer, screen_row, state.buf_start_col);
        if (is_current) {
            try writer.writeAll("\x1b[33;1m");
        } else {
            try writer.writeAll("\x1b[2;37m");
        }

        const line_num = line_idx + 1;
        const num_digits = @max(buffer.countDigits(tab.buf.lines.items.len), 2);
        try writer.writeByte(' ');
        const num_used = buffer.countDigits(line_num);
        const pad = num_digits - num_used;
        for (0..pad) |_| try writer.writeByte(' ');
        try writer.print("{d} ", .{line_num});
        try writer.writeAll("\x1b[0m");
    }

    fn renderStatusLineLegacyStyle(self: *Editor, writer: anytype, tab: ?*Tab) !void {
        if (self.height == 0) return;
        try terminal.moveCursor(writer, self.statusTerminalRow(), 1);
        try terminal.clearLine(writer);

        var right_buf: [192]u8 = undefined;
        const right = self.buildRightStatusLayout(tab, &right_buf) catch RightStatusLayout{ .text = "" };
        const right_cells = render_mod.displayCellCount(right.text);
        const right_reserve = @min(self.width, right_cells + 1);
        const left_limit = self.width -| right_reserve;

        var cells: usize = 0;
        try self.writeStatusLeftLegacy(writer, tab, &cells, left_limit);
        try self.writeStatusRightLegacy(writer, right, cells);
        try writer.writeAll("\x1b[0m");
    }

    fn statusModeLabel(self: *const Editor) []const u8 {
        return switch (self.state.mode) {
            .Insert => "INSERT",
            .Command => "COMMAND",
            .Search => "SEARCH",
            .GlobalSearch => "GLOBAL",
            .FilesystemPicker => "FILES",
            .Prompt => "PROMPT",
            .Terminal => "TERM",
            else => "NORMAL",
        };
    }

    fn statusModeStyle(self: *const Editor) render_mod.RenderStyle {
        return switch (self.state.mode) {
            .Insert => .status_mode_insert,
            .Command, .FilesystemPicker, .Prompt, .Terminal => .status_mode_command,
            .Search, .GlobalSearch => .status_mode_search,
            else => .status_mode_normal,
        };
    }

    fn statusModeSepStyle(self: *const Editor) render_mod.RenderStyle {
        return switch (self.state.mode) {
            .Insert => .status_sep_insert,
            .Command, .FilesystemPicker, .Prompt, .Terminal => .status_sep_command,
            .Search, .GlobalSearch => .status_sep_search,
            else => .status_sep_normal,
        };
    }

    fn fileIconForName(name: []const u8) []const u8 {
        const ext = std.fs.path.extension(name);
        if (std.mem.eql(u8, ext, ".zig")) return "";
        if (std.mem.eql(u8, ext, ".toml") or std.mem.eql(u8, ext, ".json") or
            std.mem.eql(u8, ext, ".zon") or std.mem.eql(u8, ext, ".xml"))
            return "";
        if (std.mem.eql(u8, ext, ".md")) return "";
        if (std.ascii.eqlIgnoreCase(std.fs.path.basename(name), "LICENSE")) return "";
        return "";
    }

    fn statusFilePath(self: *const Editor, tab: ?*Tab) []const u8 {
        var filename = if (tab) |t| t.buf.filename orelse "unsaved" else "No file";
        if (self.state.git_snapshot) |snapshot| {
            if (snapshot.root_path) |root| {
                if (std.mem.startsWith(u8, filename, root)) {
                    var rel = filename[root.len..];
                    if (rel.len > 0 and (rel[0] == '/' or rel[0] == std.fs.path.sep)) rel = rel[1..];
                    if (rel.len > 0) return rel;
                }
            }
        }
        while (std.mem.startsWith(u8, filename, "./")) filename = filename[2..];
        return filename;
    }

    fn statusContext(self: *const Editor) ?[]const u8 {
        if (self.state.mode == .Prompt) return @tagName(self.state.prompt_popup.kind);
        if (self.state.mode == .Command) return "command";
        if (self.state.mode == .Search) return "search";
        if (self.state.mode == .GlobalSearch) return "global_search";
        if (self.terminal_panel.visible) return if (self.terminal_panel.focused) "terminal focused" else "terminal";
        return null;
    }

    fn currentMinute(self: *const Editor) i64 {
        const ns = std.Io.Timestamp.now(self.io, .real).nanoseconds;
        return @intCast(@divTrunc(ns, std.time.ns_per_min));
    }

    fn clockText(self: *const Editor, buf: *[16]u8) []const u8 {
        const ns = std.Io.Timestamp.now(self.io, .real).nanoseconds;
        const secs: u64 = @intCast(@max(@divTrunc(ns, std.time.ns_per_s), 0));
        const day = (std.time.epoch.EpochSeconds{ .secs = secs }).getDaySeconds();
        return std.fmt.bufPrint(buf, " {d:0>2}:{d:0>2}", .{ day.getHoursIntoDay(), day.getMinutesIntoHour() }) catch " --:--";
    }

    fn writeLegacyStyled(writer: anytype, style: render_mod.RenderStyle, text: []const u8, cells: *usize) !void {
        try writer.writeAll(style.ansi());
        try writer.writeAll(text);
        cells.* += render_mod.displayCellCount(text);
    }

    fn writeLegacyStyledClipped(writer: anytype, style: render_mod.RenderStyle, text: []const u8, cells: *usize, max_cells: usize) !void {
        if (cells.* >= max_cells) return;
        try writer.writeAll(style.ansi());
        try writeClippedLegacy(writer, text, max_cells - cells.*, cells);
    }

    fn writeStatusLeftLegacy(self: *Editor, writer: anytype, tab: ?*Tab, cells: *usize, max_cells: usize) !void {
        if (self.state.error_message) |err| {
            try writeLegacyStyledClipped(writer, .status_error, " ERROR ", cells, max_cells);
            try writeLegacyStyledClipped(writer, .status_sep_error, "", cells, max_cells);
            try writeLegacyStyledClipped(writer, .status_file, " ", cells, max_cells);
            try writeLegacyStyledClipped(writer, .status_file, err, cells, max_cells);
            return;
        }

        var mode_buf: [32]u8 = undefined;
        const mode = std.fmt.bufPrint(&mode_buf, " {s} ", .{self.statusModeLabel()}) catch " NORMAL ";
        try writeLegacyStyledClipped(writer, self.statusModeStyle(), mode, cells, max_cells);
        try writeLegacyStyledClipped(writer, self.statusModeSepStyle(), "", cells, max_cells);

        if (self.state.git_snapshot) |snapshot| {
            if (snapshot.branch) |branch| {
                var branch_buf: [96]u8 = undefined;
                const branch_text = std.fmt.bufPrint(&branch_buf, "  {s} ", .{branch}) catch "";
                try writeLegacyStyledClipped(writer, .status_branch, branch_text, cells, max_cells);
                try writeLegacyStyledClipped(writer, .status_sep_branch, "", cells, max_cells);
            }
        }

        var file_buf: [192]u8 = undefined;
        const file_path = self.statusFilePath(tab);
        const file_text = std.fmt.bufPrint(&file_buf, " {s} {s} ", .{ fileIconForName(file_path), file_path }) catch "";
        try writeLegacyStyledClipped(writer, .status_file, file_text, cells, max_cells);

        if (self.statusContext()) |context| {
            try writeLegacyStyledClipped(writer, .status_sep_file, "", cells, max_cells);
            var context_buf: [96]u8 = undefined;
            const context_text = std.fmt.bufPrint(&context_buf, " ◆ {s} ", .{context}) catch "";
            try writeLegacyStyledClipped(writer, .status_context, context_text, cells, max_cells);
        }
        try writeLegacyStyledClipped(writer, .status_sep_context, "", cells, max_cells);
    }

    fn writeStatusRightLegacy(self: *Editor, writer: anytype, right: RightStatusLayout, left_cells: usize) !void {
        if (left_cells >= self.width) {
            self.status_cache.invalidate();
            return;
        }
        const right_cells = render_mod.displayCellCount(right.text);
        const available = self.width - left_cells;
        const need = right_cells + 1;
        const gap = available -| need;
        try writer.writeAll(render_mod.RenderStyle.status_bg.ansi());
        for (0..gap) |_| try writer.writeAll(" ");
        var written: usize = left_cells + gap;
        if (written < self.width) {
            try writer.writeAll(render_mod.RenderStyle.status_sep_right.ansi());
            try writer.writeAll("");
            written += 1;
        }
        try writer.writeAll(render_mod.RenderStyle.status_right.ansi());
        const text_start_terminal_col = written + 1;
        const text_available = self.width - written;
        self.cacheRightStatusLayout(right, text_start_terminal_col, text_available);
        try writeClippedLegacy(writer, right.text, text_available, &written);
    }

    fn writeClippedLegacy(writer: anytype, text: []const u8, max_cells: usize, cells: *usize) !void {
        var written: usize = 0;
        var i: usize = 0;
        while (i < text.len and written < max_cells) : (written += 1) {
            const len = @min(render_mod.utf8CellLen(text[i]), text.len - i);
            try writer.writeAll(text[i .. i + len]);
            i += len;
        }
        cells.* += written;
    }

    fn cacheRightStatusLayout(self: *Editor, right: RightStatusLayout, text_start_terminal_col: usize, text_available: usize) void {
        self.status_cache = .{
            .width = self.width,
            .height = self.height,
            .last_cursor_row = right.cursor_row,
            .last_cursor_col = right.cursor_col,
            .last_percent = right.percent,
            .valid = true,
        };
        if (right.cursor_valid and right.cursor_offset + right.cursor_width <= text_available) {
            self.status_cache.cursor = .{
                .terminal_col = text_start_terminal_col + right.cursor_offset,
                .width = right.cursor_width,
                .valid = true,
            };
        }
        if (right.percent_valid and right.percent_offset + right.percent_width <= text_available) {
            self.status_cache.percent = .{
                .terminal_col = text_start_terminal_col + right.percent_offset,
                .width = right.percent_width,
                .valid = true,
            };
        }
    }

    fn buildRightStatus(self: *Editor, tab: ?*Tab, buf: *[192]u8) ![]const u8 {
        return (try self.buildRightStatusLayout(tab, buf)).text;
    }

    fn buildRightStatusLayout(self: *Editor, tab: ?*Tab, buf: *[192]u8) !RightStatusLayout {
        const cursor_field_width = 12;
        const percent_field_width = 4;

        var layout = RightStatusLayout{ .text = "" };
        var idx: usize = 0;
        var cells: usize = 0;

        var clock_buf: [16]u8 = undefined;
        const clock = self.clockText(&clock_buf);
        if (tab) |t| {
            const mc = t.mainCursor();
            const total_lines = t.buf.lines.items.len;
            const pct = statusScrollPercent(mc.row, total_lines);
            const diag_count = if (t.buf.filename) |fname| self.state.lsp_ui.diagnosticCountForFile(fname) else 0;
            if (diag_count > 0) {
                try appendStatusFmt(buf, &idx, &cells, "  {d}  ", .{diag_count});
            }
            try appendStatusFmt(buf, &idx, &cells, "◇ {d}  ", .{total_lines});

            layout.percent_offset = cells;
            layout.percent_width = percent_field_width;
            layout.percent_valid = true;
            layout.percent = pct;
            try appendStatusFieldFmt(buf, &idx, &cells, percent_field_width, "{d}%", .{pct});
            try appendStatusText(buf, &idx, &cells, "  ");

            layout.cursor_offset = cells;
            layout.cursor_width = cursor_field_width;
            layout.cursor_valid = true;
            layout.cursor_row = mc.row;
            layout.cursor_col = mc.col;
            try appendStatusFieldFmt(buf, &idx, &cells, cursor_field_width, "{d}:{d}", .{ mc.row + 1, mc.col + 1 });
            try appendStatusFmt(buf, &idx, &cells, "  {s} ", .{clock});

            layout.text = buf[0..idx];
            return layout;
        }
        try appendStatusFmt(buf, &idx, &cells, " {s} ", .{clock});
        layout.text = buf[0..idx];
        return layout;
    }

    fn appendStatusText(buf: *[192]u8, idx: *usize, cells: *usize, text: []const u8) !void {
        if (idx.* + text.len > buf.len) return error.NoSpaceLeft;
        @memcpy(buf[idx.* .. idx.* + text.len], text);
        idx.* += text.len;
        cells.* += render_mod.displayCellCount(text);
    }

    fn appendStatusFmt(buf: *[192]u8, idx: *usize, cells: *usize, comptime fmt: []const u8, args: anytype) !void {
        const part = try std.fmt.bufPrint(buf[idx.*..], fmt, args);
        idx.* += part.len;
        cells.* += render_mod.displayCellCount(part);
    }

    fn appendStatusFieldFmt(buf: *[192]u8, idx: *usize, cells: *usize, width: usize, comptime fmt: []const u8, args: anytype) !void {
        const part = try std.fmt.bufPrint(buf[idx.*..], fmt, args);
        idx.* += part.len;
        const part_cells = render_mod.displayCellCount(part);
        cells.* += part_cells;
        if (part_cells < width) {
            const pad = width - part_cells;
            if (idx.* + pad > buf.len) return error.NoSpaceLeft;
            @memset(buf[idx.* .. idx.* + pad], ' ');
            idx.* += pad;
            cells.* += pad;
        }
    }

    fn statusScrollPercent(row: usize, total_lines: usize) usize {
        if (total_lines <= 1) return 100;
        return @min(@as(usize, 100), ((row + 1) * 100) / total_lines);
    }

    fn handleRuntimeKey(self: *Editor, event: terminal.KeyEvent) !void {
        if (event.eql(self.keys.quit)) {
            self.should_quit = true;
            self.markDirty(.full);
            return;
        }

        if (self.state.lsp_ui.completion_active) {
            if (try self.handleCompletionInput(event)) {
                self.markDirty(.partial);
                self.notePendingLspChange();
                return;
            }
        }

        try input.handleInput(self, event);
        self.clampScroll();
        self.markDirty(.partial);

        if (self.currentTab()) |tab| {
            if (tab.needsLspChangeNotification()) {
                self.notePendingLspChange();
            }

            const is_completion_auto_trigger = event.eql(self.keys.completion_auto_trigger);
            const is_completion_trigger = event.eql(self.keys.completion_trigger);

            if ((is_completion_auto_trigger or is_completion_trigger) and self.modeAllowsCompletion()) {
                if (tab.buf.filename != null) {
                    if (self.runtime.lsp_mgr) |*mgr| {
                        const mc = tab.mainCursor();
                        mgr.requestCompletion(tab.buf.filename.?, mc.row, mc.col) catch |err| {
                            logz.err().fmt("msg", "Failed to request completion: {any}", .{err}).log();
                        };
                    }
                }
            }
        }
    }

    fn modeAllowsCompletion(self: *const Editor) bool {
        return self.state.mode == .Normal or self.state.mode == .Insert;
    }

    fn handleSyntaxParseResult(self: *Editor, result: *syntax.ParseResult) !void {
        const tab = self.findTabBySyntaxBufferId(result.buffer_id) orelse {
            logz.debug().fmt("msg", "dropping syntax result for closed buffer {d}", .{result.buffer_id}).log();
            return;
        };

        if (result.revision != tab.buf.revision) {
            logz.debug().fmt(
                "msg",
                "dropping stale syntax result for buffer {d}: result revision {d}, current revision {d}",
                .{ result.buffer_id, result.revision, tab.buf.revision },
            ).log();
            return;
        }

        const current_language = if (tab.buf.filename) |filename|
            syntax.languageFromFilename(filename)
        else
            null;
        if (current_language == null or current_language.? != result.language) {
            tab.syntax_requested_revision = null;
            logz.debug().fmt("msg", "dropping syntax result for changed language on buffer {d}", .{result.buffer_id}).log();
            return;
        }

        try tab.syntax_highlighter.installParseResult(result);
        tab.syntax_requested_revision = result.revision;
        self.markDirty(.partial);
    }

    fn findTabBySyntaxBufferId(self: *Editor, buffer_id: u64) ?*Tab {
        for (self.state.tabs.items) |*tab| {
            if (tab.syntax_buffer_id == buffer_id) return tab;
        }
        return null;
    }

    fn prepareSyntaxForViewport(self: *Editor, tab: *Tab, first_line: usize, last_line: usize, margin: usize) !void {
        _ = try tab.syntax_highlighter.prepareForAsyncBuffer(&tab.buf) orelse {
            tab.syntax_requested_revision = null;
            if (self.active_keypress_trace) |trace| {
                trace.syntax_cache = syntax.ViewportCacheStatus.none.name();
            }
            return;
        };

        if (self.active_keypress_trace) |trace| {
            trace.syntax_cache = tab.syntax_highlighter.viewportCacheStatusFromCommitted(first_line, last_line, margin).name();
        }
        try tab.syntax_highlighter.ensureViewportFromCommitted(first_line, last_line, margin);
    }

    fn takeTextSnapshot(self: *Editor, tab: *const Tab) !TextSnapshot {
        const revision = tab.buf.revision;
        const text = try tab.buf.toOwnedTextSnapshot(self.allocator);
        return .{ .revision = revision, .text = text };
    }

    fn buildLineRenderState(
        self: *Editor,
        tab: *Tab,
        buffer_line_idx: usize,
        content_width: usize,
        selection_storage: *[64]SelectionRange,
    ) LineRenderState {
        const search_match = if (self.state.search_buffer.items.len > 0)
            if (self.state.search_system) |s| s.matchForRow(buffer_line_idx) else null
        else
            null;
        const active_match_col = if (self.state.search_buffer.items.len > 0)
            if (self.state.search_system) |s|
                if (s.activeMatchRow()) |active_row|
                    if (active_row == buffer_line_idx) s.getActiveMatch().?.col else null
                else
                    null
            else
                null
        else
            null;

        const selection_ranges = buildSelectionRanges(tab, buffer_line_idx, selection_storage);
        return .{
            .line = &tab.buf.lines.items[buffer_line_idx],
            .content_width = content_width,
            .syntax_cursor = tab.syntax_highlighter.highlightRunCursor(buffer_line_idx),
            .search_match = search_match,
            .active_match_col = active_match_col,
            .selection_ranges = selection_ranges,
        };
    }

    fn buildSelectionRanges(tab: *const Tab, row: usize, storage: *[64]SelectionRange) []const SelectionRange {
        var count: usize = 0;
        for (tab.cursors.items) |cursor| {
            const range = selectionRangeForRow(cursor, row) orelse continue;
            if (count == storage.len) break;
            storage[count] = range;
            count += 1;
        }
        return storage[0..count];
    }

    fn selectionRangeForRow(cursor: Cursor, row: usize) ?SelectionRange {
        const ss = cursor.selection_start orelse return null;
        const s_row = @min(ss.row, cursor.row);
        const e_row = @max(ss.row, cursor.row);
        const s_col = if (ss.row < cursor.row) ss.col else if (ss.row > cursor.row) cursor.col else @min(ss.col, cursor.col);
        const e_col = if (ss.row < cursor.row) cursor.col else if (ss.row > cursor.row) ss.col else @max(ss.col, cursor.col);

        if (row > s_row and row < e_row) return .{ .start_col = 0, .end_col = std.math.maxInt(usize) };
        if (row == s_row and row == e_row) return .{ .start_col = s_col, .end_col = e_col };
        if (row == s_row) return .{ .start_col = s_col, .end_col = std.math.maxInt(usize) };
        if (row == e_row) return .{ .start_col = 0, .end_col = e_col };
        return null;
    }

    fn queueSyntaxParseForCurrentTab(self: *Editor) !void {
        const tab = self.currentTab() orelse return;
        const language = try tab.syntax_highlighter.prepareForAsyncBuffer(&tab.buf) orelse {
            tab.syntax_requested_revision = null;
            return;
        };

        if (tab.syntax_highlighter.parsed_revision != tab.buf.revision and
            tab.syntax_requested_revision != tab.buf.revision)
        {
            const snapshot = try self.takeTextSnapshot(tab);
            tab.syntax_requested_revision = snapshot.revision;
            self.runtime.syntax_parse_worker.requestParse(tab.syntax_buffer_id, snapshot.revision, language, snapshot.text);
        }
    }

    fn notePendingLspChange(self: *Editor) void {
        const tab = self.currentTab() orelse return;
        if (!tab.needsLspChangeNotification()) return;
        if (tab.lsp_pending_since_ns == null) {
            tab.lsp_pending_since_ns = perf.nowNs();
        }
    }

    fn flushPendingLspChanges(self: *Editor, force: bool) !void {
        const tab = self.currentTab() orelse return;
        if (!tab.needsLspChangeNotification()) {
            tab.lsp_pending_since_ns = null;
            return;
        }
        if (tab.lsp_pending_since_ns == null) return;
        if (!force and perf.nowNs() - tab.lsp_pending_since_ns.? < 250 * std.time.ns_per_ms) {
            return;
        }

        if (self.runtime.lsp_mgr) |*mgr| {
            const snapshot = try self.takeTextSnapshot(tab);
            defer self.allocator.free(snapshot.text);
            if (snapshot.revision != tab.buf.revision) return;
            if (mgr.notifyChange(tab.buf.filename.?, snapshot.text)) {
                tab.markLspChangeNotified();
            } else |err| {
                logz.err().fmt("msg", "Failed to notify change: {any}", .{err}).log();
            }
        }
    }

    fn textViewportWidthForTab(self: *const Editor, tab: *const Tab) usize {
        const viewport = self.bufferViewportGeometry();
        const gutter_width = self.calculateGutterWidth(tab.buf.lines.items.len);
        return viewport.width -| gutter_width;
    }

    fn horizontalScrollForCursor(cursor_col: usize, scroll_col: usize, visible_width: usize) usize {
        if (visible_width == 0) return scroll_col;
        if (cursor_col < scroll_col) return cursor_col;
        if (cursor_col >= scroll_col +| visible_width) return cursor_col - visible_width + 1;
        return scroll_col;
    }

    fn visibleCursorCol(cursor_col: usize, scroll_col: usize, visible_width: usize) usize {
        if (visible_width == 0 or cursor_col <= scroll_col) return 0;
        return @min(cursor_col - scroll_col, visible_width - 1);
    }

    fn maxVisibleLineLen(tab: *const Tab, visible_rows: usize) usize {
        const mc = tab.cursors.items[tab.main_cursor_idx];
        var max_len: usize = if (mc.row < tab.buf.lines.items.len) tab.buf.lines.items[mc.row].len() else 0;
        const end = @min(tab.buf.lines.items.len, tab.scroll_row + visible_rows);
        var row = tab.scroll_row;
        while (row < end) : (row += 1) {
            max_len = @max(max_len, tab.buf.lines.items[row].len());
        }
        return max_len;
    }

    fn clampHorizontalScrollToVisibleLines(self: *Editor, tab: *Tab, visible_width: usize) void {
        const visible_rows = @max(self.editorVisibleRows(), 1);
        const max_len = maxVisibleLineLen(tab, visible_rows);
        if (visible_width == 0) {
            tab.scroll_col = @min(tab.scroll_col, max_len);
            return;
        }
        const max_scroll = max_len -| (visible_width - 1);
        tab.scroll_col = @min(tab.scroll_col, max_scroll);
    }

    pub fn applyHorizontalScrollCommand(self: *Editor, command: HorizontalScrollCommand) void {
        const tab = self.currentTab() orelse return;
        const mc = tab.mainCursor();
        const visible_width = self.textViewportWidthForTab(tab);
        if (visible_width == 0) return;

        const small_step = @max(@as(usize, 1), visible_width / 8);
        const half_step = @max(@as(usize, 1), visible_width / 2);
        switch (command) {
            .left_small => tab.scroll_col -|= small_step,
            .right_small => tab.scroll_col +|= small_step,
            .left_half => tab.scroll_col -|= half_step,
            .right_half => tab.scroll_col +|= half_step,
            .cursor_start => tab.scroll_col = mc.col,
            .cursor_end => tab.scroll_col = mc.col -| (visible_width - 1),
        }
        self.clampHorizontalScrollToVisibleLines(tab, visible_width);
    }

    /// Adjust scroll state so the main cursor is always within the visible viewport.
    pub fn clampScroll(self: *Editor) void {
        const tab = self.currentTab() orelse return;
        const mc = tab.mainCursor();
        const before_scroll_row = tab.scroll_row;
        const before_scroll_col = tab.scroll_col;
        const visible_rows = @max(self.editorVisibleRows(), 1);
        if (mc.row < tab.scroll_row) {
            tab.scroll_row = mc.row;
        } else if (mc.row >= tab.scroll_row + visible_rows) {
            tab.scroll_row = mc.row - visible_rows + 1;
        }
        const visible_width = self.textViewportWidthForTab(tab);
        tab.scroll_col = horizontalScrollForCursor(mc.col, tab.scroll_col, visible_width);
        self.clampHorizontalScrollToVisibleLines(tab, visible_width);
        if (self.active_keypress_trace) |trace| {
            trace.viewport_scrolled = trace.viewport_scrolled or
                before_scroll_row != tab.scroll_row or
                before_scroll_col != tab.scroll_col;
        }
    }

    fn tabBasename(tab: *const Tab) []const u8 {
        const filename = tab.buf.filename orelse "unsaved";
        return std.fs.path.basename(filename);
    }

    fn tabNameLen(basename: []const u8) usize {
        return @min(basename.len, max_tab_name_width);
    }

    fn tabLabelWidth(tab: *const Tab) usize {
        const basename = tabBasename(tab);
        const name_len = tabNameLen(basename);
        return tab_prefix_width + name_len + (if (basename.len > name_len) @as(usize, 3) else @as(usize, 0)) + tab_separator.len;
    }

    fn totalTabBarWidth(tabs: []const Tab) usize {
        var total: usize = 0;
        for (tabs) |*tab| total += tabLabelWidth(tab);
        return total;
    }

    fn tabStartCol(tabs: []const Tab, index: usize) usize {
        var start: usize = 0;
        for (tabs[0..index]) |*tab| start += tabLabelWidth(tab);
        return start;
    }

    fn clampTabBarScroll(scroll_col: *usize, total_width: usize, available_width: usize) void {
        if (available_width == 0 or total_width <= available_width) {
            scroll_col.* = 0;
            return;
        }
        scroll_col.* = @min(scroll_col.*, total_width - available_width);
    }

    fn ensureActiveTabVisible(tabs: []const Tab, active_index: usize, available_width: usize, scroll_col: *usize) void {
        if (tabs.len == 0 or available_width == 0 or active_index >= tabs.len) {
            scroll_col.* = 0;
            return;
        }

        const total_width = totalTabBarWidth(tabs);
        clampTabBarScroll(scroll_col, total_width, available_width);

        const active_start = tabStartCol(tabs, active_index);
        const active_end = active_start + tabLabelWidth(&tabs[active_index]);
        if (active_start < scroll_col.*) {
            scroll_col.* = active_start;
        } else if (active_end > scroll_col.* + available_width) {
            scroll_col.* = active_end - available_width;
        }

        clampTabBarScroll(scroll_col, total_width, available_width);
    }

    fn prepareTabBarLayout(self: *Editor, width: usize) TabBarLayout {
        const tabs = self.state.tabs.items;
        const total_width = totalTabBarWidth(tabs);
        if (tabs.len == 0 or width == 0) {
            self.state.tab_bar_scroll_col = 0;
            return .{
                .total_width = total_width,
                .scroll_col = 0,
                .content_start_col = 0,
                .content_width = 0,
                .has_hidden_left = false,
                .has_hidden_right = false,
            };
        }

        var has_hidden_left = self.state.tab_bar_scroll_col > 0;
        var has_hidden_right = false;
        var content_width = width;

        for (0..4) |_| {
            const reserved = @as(usize, @intFromBool(has_hidden_left)) + @as(usize, @intFromBool(has_hidden_right));
            content_width = width -| reserved;
            ensureActiveTabVisible(tabs, self.state.active_tab_index, content_width, &self.state.tab_bar_scroll_col);

            const next_hidden_left = self.state.tab_bar_scroll_col > 0;
            const next_hidden_right = total_width > self.state.tab_bar_scroll_col + content_width;
            if (next_hidden_left == has_hidden_left and next_hidden_right == has_hidden_right) break;
            has_hidden_left = next_hidden_left;
            has_hidden_right = next_hidden_right;
        }

        const reserved = @as(usize, @intFromBool(has_hidden_left)) + @as(usize, @intFromBool(has_hidden_right));
        content_width = width -| reserved;
        ensureActiveTabVisible(tabs, self.state.active_tab_index, content_width, &self.state.tab_bar_scroll_col);
        has_hidden_left = self.state.tab_bar_scroll_col > 0;
        has_hidden_right = total_width > self.state.tab_bar_scroll_col + content_width;

        return .{
            .total_width = total_width,
            .scroll_col = self.state.tab_bar_scroll_col,
            .content_start_col = @intFromBool(has_hidden_left),
            .content_width = content_width,
            .has_hidden_left = has_hidden_left,
            .has_hidden_right = has_hidden_right,
        };
    }

    fn writeVirtualClippedText(self: *Editor, row: usize, dest_base_col: usize, text_start_col: usize, viewport_start: usize, viewport_end: usize, text: []const u8, style: render_mod.RenderStyle) void {
        const text_end_col = text_start_col + text.len;
        const draw_start = @max(text_start_col, viewport_start);
        const draw_end = @min(text_end_col, viewport_end);
        if (draw_start >= draw_end) return;

        const skip = draw_start - text_start_col;
        const len = draw_end - draw_start;
        self.renderer.screen.writeText(row, dest_base_col + draw_start - viewport_start, text[skip .. skip + len], style);
    }

    fn writeVirtualClippedTabLabel(self: *Editor, row: usize, dest_base_col: usize, label_start_col: usize, viewport_start: usize, viewport_end: usize, tab: *const Tab, active: bool) void {
        const style: render_mod.RenderStyle = if (active) .gutter_current else .dim;
        const prefix = if (active) "> " else "  ";
        const basename = tabBasename(tab);
        const name_len = tabNameLen(basename);
        var col = label_start_col;

        self.writeVirtualClippedText(row, dest_base_col, col, viewport_start, viewport_end, prefix, style);
        col += prefix.len;
        self.writeVirtualClippedText(row, dest_base_col, col, viewport_start, viewport_end, basename[0..name_len], style);
        col += name_len;
        if (basename.len > name_len) {
            self.writeVirtualClippedText(row, dest_base_col, col, viewport_start, viewport_end, "...", style);
            col += 3;
        }
        self.writeVirtualClippedText(row, dest_base_col, col, viewport_start, viewport_end, tab_separator, .dim);
    }

    fn writeAnsiClippedText(writer: anytype, start_col: usize, dest_base_col: usize, text_start_col: usize, viewport_start: usize, viewport_end: usize, text: []const u8) !void {
        const text_end_col = text_start_col + text.len;
        const draw_start = @max(text_start_col, viewport_start);
        const draw_end = @min(text_end_col, viewport_end);
        if (draw_start >= draw_end) return;

        const skip = draw_start - text_start_col;
        const len = draw_end - draw_start;
        try terminal.moveCursor(writer, 1, start_col + dest_base_col + draw_start - viewport_start);
        try writer.writeAll(text[skip .. skip + len]);
    }

    fn writeAnsiClippedTabLabel(writer: anytype, start_col: usize, dest_base_col: usize, label_start_col: usize, viewport_start: usize, viewport_end: usize, tab: *const Tab, active: bool) !void {
        const prefix = if (active) "> " else "  ";
        const basename = tabBasename(tab);
        const name_len = tabNameLen(basename);
        var col = label_start_col;

        try writer.writeAll(if (active) "\x1b[1;33m" else "\x1b[2;37m");
        try writeAnsiClippedText(writer, start_col, dest_base_col, col, viewport_start, viewport_end, prefix);
        col += prefix.len;
        try writeAnsiClippedText(writer, start_col, dest_base_col, col, viewport_start, viewport_end, basename[0..name_len]);
        col += name_len;
        if (basename.len > name_len) {
            try writeAnsiClippedText(writer, start_col, dest_base_col, col, viewport_start, viewport_end, "...");
            col += 3;
        }
        try writer.writeAll("\x1b[2;37m");
        try writeAnsiClippedText(writer, start_col, dest_base_col, col, viewport_start, viewport_end, tab_separator);
        try writer.writeAll("\x1b[0m");
    }

    fn renderTabs(self: *Editor, writer: anytype, start_col: usize, width: usize) !void {
        if (width == 0) return;
        try terminal.moveCursor(writer, 1, 1);
        try terminal.eraseToLineEnd(writer);
        try terminal.moveCursor(writer, 1, start_col);

        if (self.state.tabs.items.len == 0) return;

        const layout = self.prepareTabBarLayout(width);
        if (layout.has_hidden_left) {
            try writer.writeAll("\x1b[2;37m<\x1b[0m");
        }
        if (layout.content_width > 0) {
            const viewport_start = layout.scroll_col;
            const viewport_end = viewport_start + layout.content_width;
            var label_start: usize = 0;
            for (self.state.tabs.items, 0..) |*tab, i| {
                const label_width = tabLabelWidth(tab);
                if (label_start >= viewport_end) break;
                if (label_start + label_width > viewport_start) {
                    try writeAnsiClippedTabLabel(writer, start_col, layout.content_start_col, label_start, viewport_start, viewport_end, tab, i == self.state.active_tab_index);
                }
                label_start += label_width;
            }
        }
        if (layout.has_hidden_right) {
            try terminal.moveCursor(writer, 1, start_col + width - 1);
            try writer.writeAll("\x1b[2;37m>\x1b[0m");
        }

        // Render separator on row 2
        try terminal.moveCursor(writer, 2, start_col);
        try terminal.eraseToLineEnd(writer);
        try writer.writeAll("\x1b[2;37m"); // Dim Grey
        for (0..width) |_| try writer.writeAll("─");
        try writer.writeAll("\x1b[0m");
    }

    fn popupGeometry(self: *const Editor, visible: bool, item_count: usize, show_items: bool, max_visible_items: usize) ?CommandPopupGeometry {
        if (!visible or self.height < 6) return null;

        const viewport = self.bufferViewportGeometry();
        if (viewport.width < 16) return null;

        const max_width = viewport.width -| 2;
        const desired_width = @max(@as(usize, 40), (viewport.width * 9) / 10);
        const popup_width = @min(max_width, desired_width);
        if (popup_width < 16) return null;

        const row: usize = 2;
        const available_suggestions = self.height - row - 4;
        const suggestion_count = if (show_items)
            @min(item_count, @min(max_visible_items, available_suggestions))
        else
            0;
        const viewport_col = viewport.start_col -| 1;
        const col = viewport_col + (viewport.width - popup_width) / 2;
        return .{
            .row = row,
            .col = col,
            .width = popup_width,
            .suggestion_count = suggestion_count,
        };
    }

    fn commandPopupGeometry(self: *const Editor) ?CommandPopupGeometry {
        return self.popupGeometry(
            self.state.command_popup.visible,
            self.state.command_popup.suggestions.items.len,
            self.state.command_popup.input.items.len > 0,
            6,
        );
    }

    fn globalSearchPopupGeometry(self: *const Editor) ?CommandPopupGeometry {
        const render_row_count = globalSearchRenderRowCount(self.state.global_search.results.items);
        const max_visible_items: usize = if (render_row_count > 6) 12 else 6;
        return self.popupGeometry(
            self.state.global_search.visible,
            render_row_count,
            self.state.global_search.input.items.len > 0,
            max_visible_items,
        );
    }

    fn renderCommandPopup(self: *Editor, writer: anytype) !void {
        const geom = self.commandPopupGeometry() orelse return;
        const popup = &self.state.command_popup;
        const screen_row = geom.row + 1;
        const screen_col = geom.col + 1;
        const inner_width = geom.width - 2;
        const title_col = if (geom.width > command_popup_title.len)
            screen_col + (geom.width - command_popup_title.len) / 2
        else
            screen_col;

        try terminal.moveCursor(writer, screen_row, screen_col);
        try writer.writeAll(command_popup_border_ansi ++ "╭");
        for (0..inner_width) |_| try writer.writeAll("─");
        try writer.writeAll("╮\x1b[0m");
        if (command_popup_title.len + 2 < geom.width) {
            try terminal.moveCursor(writer, screen_row, title_col);
            try writer.writeAll(command_popup_border_ansi);
            try writer.writeAll(command_popup_title);
            try writer.writeAll("\x1b[0m");
        }

        try terminal.moveCursor(writer, screen_row + 1, screen_col);
        try writer.writeAll(command_popup_border_ansi ++ "│" ++ command_popup_border_ansi ++ " > " ++ "\x1b[48;5;235m\x1b[38;5;255m");
        const input_space = inner_width -| 3;
        const shown_input = popup.input.items[0..@min(popup.input.items.len, input_space)];
        try writer.writeAll(shown_input);
        for (shown_input.len..input_space) |_| try writer.writeByte(' ');
        try writer.writeAll(command_popup_border_ansi ++ "│\x1b[0m");

        for (0..geom.suggestion_count) |i| {
            const suggestion = popup.suggestions.items[i].name();
            const selected = popup.selected_index != null and popup.selected_index.? == i;
            try terminal.moveCursor(writer, screen_row + 2 + i, screen_col);
            if (selected) {
                try writer.writeAll("\x1b[48;5;238m\x1b[38;5;255m");
            } else {
                try writer.writeAll("\x1b[48;5;235m\x1b[38;5;250m");
            }
            try writer.writeAll(command_popup_border_ansi);
            try writer.writeAll("│");
            if (selected) {
                try writer.writeAll("\x1b[48;5;238m\x1b[38;5;255m");
            } else {
                try writer.writeAll("\x1b[48;5;235m\x1b[38;5;250m");
            }
            try writer.writeAll(" ");
            const shown = suggestion[0..@min(suggestion.len, inner_width -| 2)];
            try writer.writeAll(shown);
            for (shown.len..inner_width -| 1) |_| try writer.writeByte(' ');
            try writer.writeAll(command_popup_border_ansi);
            try writer.writeAll("│\x1b[0m");
        }

        try terminal.moveCursor(writer, screen_row + 2 + geom.suggestion_count, screen_col);
        try writer.writeAll(command_popup_border_ansi ++ "╰");
        for (0..inner_width) |_| try writer.writeAll("─");
        try writer.writeAll("╯\x1b[0m");
    }

    fn writeTruncated(writer: anytype, text: []const u8, remaining: *usize) !usize {
        if (remaining.* == 0) return 0;
        const shown = text[0..@min(text.len, remaining.*)];
        try writer.writeAll(shown);
        remaining.* -= shown.len;
        return shown.len;
    }

    fn globalSearchFileAnsi(selected: bool) []const u8 {
        return if (selected) "\x1b[48;5;238m\x1b[38;5;220m" else "\x1b[48;5;235m\x1b[38;5;220m";
    }

    fn globalSearchResultAnsi(selected: bool) []const u8 {
        return if (selected) "\x1b[48;5;238m\x1b[38;5;121m" else "\x1b[48;5;235m\x1b[38;5;121m";
    }

    fn globalSearchRowBaseAnsi(selected: bool) []const u8 {
        return if (selected) "\x1b[48;5;238m\x1b[38;5;255m" else "\x1b[48;5;235m\x1b[38;5;250m";
    }

    fn isSameContentDisplayPath(a: global_search.GlobalSearchResult, b: global_search.GlobalSearchResult) bool {
        return switch (a) {
            .content => |a_content| switch (b) {
                .content => |b_content| std.mem.eql(u8, a_content.display_path, b_content.display_path),
                .path => false,
            },
            .path => false,
        };
    }

    fn globalSearchRenderRowCount(results: []const global_search.GlobalSearchResult) usize {
        var count: usize = 0;
        var i: usize = 0;
        while (i < results.len) {
            switch (results[i]) {
                .path => {
                    count += 1;
                    i += 1;
                },
                .content => {
                    const group_start = i;
                    count += 1; // file header
                    while (i < results.len and isSameContentDisplayPath(results[i], results[group_start])) : (i += 1) {
                        count += 1;
                    }
                },
            }
        }
        return count;
    }

    fn globalSearchRenderRowAt(results: []const global_search.GlobalSearchResult, render_row: usize) ?GlobalSearchRenderRow {
        var row: usize = 0;
        var i: usize = 0;
        while (i < results.len) {
            switch (results[i]) {
                .path => {
                    if (row == render_row) return .{ .path = i };
                    row += 1;
                    i += 1;
                },
                .content => |content| {
                    const group_path = content.display_path;
                    if (row == render_row) return .{ .header = group_path };
                    row += 1;
                    while (i < results.len) : (i += 1) {
                        switch (results[i]) {
                            .content => |group_content| {
                                if (!std.mem.eql(u8, group_content.display_path, group_path)) break;
                                if (row == render_row) return .{ .content = i };
                                row += 1;
                            },
                            .path => break,
                        }
                    }
                },
            }
        }
        return null;
    }

    fn selectedGlobalSearchRenderRow(results: []const global_search.GlobalSearchResult, selected_index: ?usize) ?usize {
        const selected = selected_index orelse return null;
        var row: usize = 0;
        var i: usize = 0;
        while (i < results.len) {
            switch (results[i]) {
                .path => {
                    if (i == selected) return row;
                    row += 1;
                    i += 1;
                },
                .content => |content| {
                    const group_path = content.display_path;
                    row += 1; // header
                    while (i < results.len) : (i += 1) {
                        switch (results[i]) {
                            .content => |group_content| {
                                if (!std.mem.eql(u8, group_content.display_path, group_path)) break;
                                if (i == selected) return row;
                                row += 1;
                            },
                            .path => break,
                        }
                    }
                },
            }
        }
        return null;
    }

    fn adjustGlobalSearchRenderScroll(self: *Editor, view_height: usize) void {
        if (view_height == 0) return;
        const total_rows = globalSearchRenderRowCount(self.state.global_search.results.items);
        if (total_rows == 0) {
            self.state.global_search.scroll_offset = 0;
            return;
        }
        if (self.state.global_search.scroll_offset >= total_rows) {
            self.state.global_search.scroll_offset = total_rows - 1;
        }
        const selected_row = selectedGlobalSearchRenderRow(self.state.global_search.results.items, self.state.global_search.selected_index) orelse return;
        if (selected_row < self.state.global_search.scroll_offset) {
            self.state.global_search.scroll_offset = selected_row;
        } else if (selected_row >= self.state.global_search.scroll_offset + view_height) {
            self.state.global_search.scroll_offset = selected_row - view_height + 1;
        }
    }

    fn renderGlobalSearchRowText(writer: anytype, row: GlobalSearchRenderRow, results: []const global_search.GlobalSearchResult, max_width: usize, selected: bool) !usize {
        var remaining = max_width;
        var written: usize = 0;
        switch (row) {
            .header => |display_path| {
                try writer.writeAll(globalSearchFileAnsi(false));
                written += try writeTruncated(writer, display_path, &remaining);
            },
            .path => |result_index| {
                const path = results[result_index].path;
                try writer.writeAll(globalSearchFileAnsi(selected));
                written += try writeTruncated(writer, path.display_path, &remaining);
            },
            .content => |result_index| {
                const content = results[result_index].content;
                try writer.writeAll(globalSearchResultAnsi(selected));
                written += try writeTruncated(writer, "  ", &remaining);
                var location_buf: [48]u8 = undefined;
                const location = try std.fmt.bufPrint(&location_buf, "{d}:{d}  ", .{ content.row + 1, content.col + 1 });
                written += try writeTruncated(writer, location, &remaining);
                written += try writeTruncated(writer, content.snippet, &remaining);
            },
        }
        return written;
    }

    fn renderGlobalSearchPopup(self: *Editor, writer: anytype) !void {
        const geom = self.globalSearchPopupGeometry() orelse return;
        const popup = &self.state.global_search;
        const screen_row = geom.row + 1;
        const screen_col = geom.col + 1;
        const inner_width = geom.width - 2;
        const title_col = if (geom.width > global_search_popup_title.len)
            screen_col + (geom.width - global_search_popup_title.len) / 2
        else
            screen_col;

        try terminal.moveCursor(writer, screen_row, screen_col);
        try writer.writeAll(global_search_popup_border_ansi ++ "╭");
        for (0..inner_width) |_| try writer.writeAll("─");
        try writer.writeAll("╮\x1b[0m");
        if (global_search_popup_title.len + 2 < geom.width) {
            try terminal.moveCursor(writer, screen_row, title_col);
            try writer.writeAll(global_search_popup_border_ansi);
            try writer.writeAll(global_search_popup_title);
            try writer.writeAll("\x1b[0m");
        }

        try terminal.moveCursor(writer, screen_row + 1, screen_col);
        try writer.writeAll(global_search_popup_border_ansi ++ "│" ++ global_search_popup_border_ansi ++ " > " ++ "\x1b[48;5;235m\x1b[38;5;255m");
        const input_space = inner_width -| 3;
        const shown_input = popup.input.items[0..@min(popup.input.items.len, input_space)];
        try writer.writeAll(shown_input);
        for (shown_input.len..input_space) |_| try writer.writeByte(' ');
        try writer.writeAll(global_search_popup_border_ansi ++ "│\x1b[0m");

        self.adjustGlobalSearchRenderScroll(geom.suggestion_count);
        for (0..geom.suggestion_count) |offset| {
            const render_row_index = self.state.global_search.scroll_offset + offset;
            const render_row = globalSearchRenderRowAt(popup.results.items, render_row_index) orelse break;
            const selected = switch (render_row) {
                .path => |result_index| popup.selected_index != null and popup.selected_index.? == result_index,
                .content => |result_index| popup.selected_index != null and popup.selected_index.? == result_index,
                .header => false,
            };
            try terminal.moveCursor(writer, screen_row + 2 + offset, screen_col);
            try writer.writeAll(global_search_popup_border_ansi);
            try writer.writeAll("│");
            try writer.writeAll(globalSearchRowBaseAnsi(selected));
            try writer.writeAll(" ");
            const written = try renderGlobalSearchRowText(writer, render_row, popup.results.items, inner_width -| 2, selected);
            try writer.writeAll(globalSearchRowBaseAnsi(selected));
            for (written..inner_width -| 1) |_| try writer.writeByte(' ');
            try writer.writeAll(global_search_popup_border_ansi);
            try writer.writeAll("│\x1b[0m");
        }

        try terminal.moveCursor(writer, screen_row + 2 + geom.suggestion_count, screen_col);
        try writer.writeAll(global_search_popup_border_ansi ++ "╰");
        for (0..inner_width) |_| try writer.writeAll("─");
        try writer.writeAll("╯\x1b[0m");
    }

    fn pickerTitle(mode: filesystem_picker.PickerMode, phase: filesystem_picker.PickerPhase) []const u8 {
        return switch (mode) {
            .open_file => " Open File ",
            .open_folder => " Open Folder ",
            .new_file_location => if (phase == .entering_name) " New File " else " New File Location ",
        };
    }

    fn pickerFooter(mode: filesystem_picker.PickerMode, phase: filesystem_picker.PickerPhase) []const u8 {
        if (mode == .new_file_location and phase == .entering_name) {
            return "Enter create  Backspace edit  Esc cancel";
        }
        return switch (mode) {
            .open_file => "Up/Down move  Enter open  Backspace up  Esc cancel",
            .open_folder => "Up/Down move  Enter enter folder  Space select folder  Backspace up  Esc cancel",
            .new_file_location => "Up/Down move  Enter enter folder  Space choose location  Backspace up  Esc cancel",
        };
    }

    fn renderFilesystemPickerPopup(self: *Editor, writer: anytype) !void {
        if (!self.state.filesystem_picker.visible) return;
        const picker = &self.state.filesystem_picker;
        const item_count: usize = if (picker.phase == .browsing) picker.entries.items.len else 1;
        const geom = self.popupGeometry(true, item_count + 3, true, 12) orelse return;
        const screen_row = geom.row + 1;
        const screen_col = geom.col + 1;
        const inner_width = geom.width - 2;
        const title = pickerTitle(picker.mode, picker.phase);
        const title_col = if (geom.width > title.len)
            screen_col + (geom.width - title.len) / 2
        else
            screen_col;

        try terminal.moveCursor(writer, screen_row, screen_col);
        try writer.writeAll(filesystem_picker_border_ansi ++ "╭");
        for (0..inner_width) |_| try writer.writeAll("─");
        try writer.writeAll("╮\x1b[0m");
        if (title.len + 2 < geom.width) {
            try terminal.moveCursor(writer, screen_row, title_col);
            try writer.writeAll(filesystem_picker_border_ansi);
            try writer.writeAll(title);
            try writer.writeAll("\x1b[0m");
        }

        try terminal.moveCursor(writer, screen_row + 1, screen_col);
        try writer.writeAll(filesystem_picker_border_ansi ++ "│\x1b[48;5;235m\x1b[38;5;255m ");
        const shown_cwd = picker.cwd[0..@min(picker.cwd.len, inner_width -| 2)];
        try writer.writeAll(shown_cwd);
        for (shown_cwd.len..inner_width -| 1) |_| try writer.writeByte(' ');
        try writer.writeAll(filesystem_picker_border_ansi ++ "│\x1b[0m");

        var rows_written: usize = 0;
        if (picker.phase == .entering_name) {
            try terminal.moveCursor(writer, screen_row + 2, screen_col);
            try writer.writeAll(filesystem_picker_border_ansi ++ "│\x1b[48;5;235m\x1b[38;5;255m filename: ");
            const prefix_len = " filename: ".len;
            const input_space = inner_width -| prefix_len -| 1;
            const shown = picker.input.items[0..@min(picker.input.items.len, input_space)];
            try writer.writeAll(shown);
            for (shown.len..input_space) |_| try writer.writeByte(' ');
            try writer.writeAll(filesystem_picker_border_ansi ++ "│\x1b[0m");
            rows_written = 1;
        } else {
            var offset: usize = 0;
            if (geom.suggestion_count > 3) {
                const view_height = geom.suggestion_count - 3;
                if (picker.selected_index >= picker.scroll_offset + view_height) {
                    picker.scroll_offset = picker.selected_index - view_height + 1;
                } else if (picker.selected_index < picker.scroll_offset) {
                    picker.scroll_offset = picker.selected_index;
                }
                while (offset < view_height and picker.scroll_offset + offset < picker.entries.items.len) : (offset += 1) {
                    const index = picker.scroll_offset + offset;
                    const entry = picker.entries.items[index];
                    const selected = index == picker.selected_index;
                    try terminal.moveCursor(writer, screen_row + 2 + offset, screen_col);
                    try writer.writeAll(filesystem_picker_border_ansi ++ "│");
                    if (selected) {
                        try writer.writeAll("\x1b[48;5;238m\x1b[38;5;255m ");
                    } else {
                        try writer.writeAll("\x1b[48;5;235m\x1b[38;5;250m ");
                    }
                    const suffix = if (entry.kind == .directory) "/" else "";
                    var remaining = inner_width -| 1;
                    const shown_name = entry.name[0..@min(entry.name.len, remaining)];
                    try writer.writeAll(shown_name);
                    remaining -|= shown_name.len;
                    if (suffix.len > 0 and remaining > 0) {
                        try writer.writeAll(suffix);
                        remaining -|= suffix.len;
                    }
                    for (0..remaining) |_| try writer.writeByte(' ');
                    try writer.writeAll(filesystem_picker_border_ansi ++ "│\x1b[0m");
                }
            }
            rows_written = offset;
        }

        if (picker.error_message) |msg| {
            try terminal.moveCursor(writer, screen_row + 2 + rows_written, screen_col);
            try writer.writeAll(filesystem_picker_border_ansi ++ "│\x1b[48;5;235m\x1b[38;5;203m ");
            const shown = msg[0..@min(msg.len, inner_width -| 2)];
            try writer.writeAll(shown);
            for (shown.len..inner_width -| 1) |_| try writer.writeByte(' ');
            try writer.writeAll(filesystem_picker_border_ansi ++ "│\x1b[0m");
            rows_written += 1;
        }

        try terminal.moveCursor(writer, screen_row + 2 + rows_written, screen_col);
        try writer.writeAll(filesystem_picker_border_ansi ++ "│\x1b[48;5;235m\x1b[38;5;245m ");
        const footer = pickerFooter(picker.mode, picker.phase);
        const shown_footer = footer[0..@min(footer.len, inner_width -| 2)];
        try writer.writeAll(shown_footer);
        for (shown_footer.len..inner_width -| 1) |_| try writer.writeByte(' ');
        try writer.writeAll(filesystem_picker_border_ansi ++ "│\x1b[0m");

        try terminal.moveCursor(writer, screen_row + 3 + rows_written, screen_col);
        try writer.writeAll(filesystem_picker_border_ansi ++ "╰");
        for (0..inner_width) |_| try writer.writeAll("─");
        try writer.writeAll("╯\x1b[0m");
    }

    fn promptFooter(kind: prompt_popup.PromptKind) []const u8 {
        return switch (kind) {
            .explorer_new_file => "Enter create  Backspace edit  Esc cancel",
            .explorer_rename => "Enter rename  Backspace edit  Esc cancel",
            .explorer_delete_confirm => "Enter/y confirm  Esc/n cancel",
        };
    }

    fn renderPromptPopup(self: *Editor, writer: anytype) !void {
        if (!self.state.prompt_popup.visible) return;
        const popup = &self.state.prompt_popup;
        const geom = self.popupGeometry(true, 4, true, 4) orelse return;
        const screen_row = geom.row + 1;
        const screen_col = geom.col + 1;
        const inner_width = geom.width - 2;
        const title_col = if (geom.width > popup.title.len)
            screen_col + (geom.width - popup.title.len) / 2
        else
            screen_col;

        try terminal.moveCursor(writer, screen_row, screen_col);
        try writer.writeAll(prompt_popup_border_ansi ++ "╭");
        for (0..inner_width) |_| try writer.writeAll("─");
        try writer.writeAll("╮\x1b[0m");
        if (popup.title.len + 2 < geom.width) {
            try terminal.moveCursor(writer, screen_row, title_col);
            try writer.writeAll(prompt_popup_border_ansi);
            try writer.writeAll(popup.title);
            try writer.writeAll("\x1b[0m");
        }

        try terminal.moveCursor(writer, screen_row + 1, screen_col);
        try writer.writeAll(prompt_popup_border_ansi ++ "│\x1b[48;5;235m\x1b[38;5;255m ");
        if (popup.kind == .explorer_delete_confirm) {
            try writer.writeAll("Delete ");
            const shown = popup.context_path[0..@min(popup.context_path.len, inner_width -| 10)];
            try writer.writeAll(shown);
            try writer.writeAll("?");
            const used = " Delete ".len + shown.len + 1;
            for (used..inner_width -| 1) |_| try writer.writeByte(' ');
        } else {
            const shown_context = popup.context_path[0..@min(popup.context_path.len, inner_width / 2)];
            try writer.writeAll(shown_context);
            try writer.writeAll(" > ");
            const used_prefix = 1 + shown_context.len + 3;
            const input_space = inner_width -| used_prefix -| 1;
            const shown_input = popup.input.items[0..@min(popup.input.items.len, input_space)];
            try writer.writeAll(shown_input);
            for (shown_input.len..input_space) |_| try writer.writeByte(' ');
        }
        try writer.writeAll(prompt_popup_border_ansi ++ "│\x1b[0m");

        var row_offset: usize = 2;
        if (popup.error_message) |msg| {
            try terminal.moveCursor(writer, screen_row + row_offset, screen_col);
            try writer.writeAll(prompt_popup_border_ansi ++ "│\x1b[48;5;235m\x1b[38;5;203m ");
            const shown = msg[0..@min(msg.len, inner_width -| 2)];
            try writer.writeAll(shown);
            for (shown.len..inner_width -| 1) |_| try writer.writeByte(' ');
            try writer.writeAll(prompt_popup_border_ansi ++ "│\x1b[0m");
            row_offset += 1;
        }

        try terminal.moveCursor(writer, screen_row + row_offset, screen_col);
        try writer.writeAll(prompt_popup_border_ansi ++ "│\x1b[48;5;235m\x1b[38;5;245m ");
        const footer = promptFooter(popup.kind);
        const shown_footer = footer[0..@min(footer.len, inner_width -| 2)];
        try writer.writeAll(shown_footer);
        for (shown_footer.len..inner_width -| 1) |_| try writer.writeByte(' ');
        try writer.writeAll(prompt_popup_border_ansi ++ "│\x1b[0m");

        try terminal.moveCursor(writer, screen_row + row_offset + 1, screen_col);
        try writer.writeAll(prompt_popup_border_ansi ++ "╰");
        for (0..inner_width) |_| try writer.writeAll("─");
        try writer.writeAll("╯\x1b[0m");
    }

    fn terminalCellStyle(cell: terminal_panel_mod.TerminalCell) render_mod.RenderStyle {
        if (cell.style.fg) |fg| {
            return switch (fg) {
                .black => .terminal_black,
                .red => if (cell.style.bold) .terminal_bright_red else .terminal_red,
                .green => if (cell.style.bold) .terminal_bright_green else .terminal_green,
                .yellow => if (cell.style.bold) .terminal_bright_yellow else .terminal_yellow,
                .blue => if (cell.style.bold) .terminal_bright_blue else .terminal_blue,
                .magenta => if (cell.style.bold) .terminal_bright_magenta else .terminal_magenta,
                .cyan => if (cell.style.bold) .terminal_bright_cyan else .terminal_cyan,
                .white => if (cell.style.bold) .terminal_bright_white else .terminal_white,
                .bright_black => .terminal_bright_black,
                .bright_red => .terminal_bright_red,
                .bright_green => .terminal_bright_green,
                .bright_yellow => .terminal_bright_yellow,
                .bright_blue => .terminal_bright_blue,
                .bright_magenta => .terminal_bright_magenta,
                .bright_cyan => .terminal_bright_cyan,
                .bright_white => .terminal_bright_white,
            };
        }
        return if (cell.style.bold) .terminal_bright_white else .terminal_bg;
    }

    fn renderTerminalPanelLegacy(self: *Editor, writer: anytype) !void {
        const panel_height = self.terminalPanelHeight();
        if (panel_height == 0 or self.width == 0) return;

        const start_row = self.height - panel_height + 1;
        const title = if (self.terminal_panel.focused) " Terminal [focused] " else " Terminal ";
        const title_style: render_mod.RenderStyle = if (self.terminal_panel.focused) .terminal_focus else .terminal_title;

        try terminal.moveCursor(writer, start_row, 1);
        try writer.writeAll(render_mod.RenderStyle.terminal_border.ansi());
        var title_written = false;
        var col: usize = 0;
        while (col < self.width) : (col += 1) {
            if (!title_written and col == 1 and self.width > title.len + 1) {
                try writer.writeAll(title_style.ansi());
                try writer.writeAll(title);
                try writer.writeAll(render_mod.RenderStyle.terminal_border.ansi());
                col += title.len - 1;
                title_written = true;
            } else {
                try writer.writeByte('-');
            }
        }

        const body_height = panel_height -| 1;
        self.terminal_panel.resizePty(self.width, body_height);
        self.terminal_panel.clampScroll(body_height);
        const total_lines = self.terminal_panel.renderLineCount();
        const end = total_lines -| @min(self.terminal_panel.scroll_offset, total_lines);
        const shown = @min(body_height, end);
        const first = end - shown;

        for (0..body_height) |offset| {
            const row = start_row + 1 + offset;
            try terminal.moveCursor(writer, row, 1);
            try writer.writeAll(render_mod.RenderStyle.terminal_bg.ansi());
            if (offset < shown) {
                const line = self.terminal_panel.renderLineAt(first + offset) orelse continue;
                var x: usize = 0;
                for (line.cells.items[0..@min(line.cells.items.len, self.width)]) |cell| {
                    try writer.writeAll(terminalCellStyle(cell).ansi());
                    try writer.writeByte(cell.ch);
                    x += 1;
                }
                if (self.terminal_panel.focused and first + offset == self.terminal_panel.cursorRenderIndex() and self.terminal_panel.cursor_col < self.width) {
                    while (x < self.terminal_panel.cursor_col and x < self.width) : (x += 1) try writer.writeByte(' ');
                    if (x < self.width) {
                        const ch = if (self.terminal_panel.cursor_col < line.cells.items.len) line.cells.items[self.terminal_panel.cursor_col].ch else ' ';
                        try writer.writeAll(render_mod.RenderStyle.terminal_cursor.ansi());
                        try writer.writeByte(ch);
                        x += 1;
                    }
                }
                try writer.writeAll(render_mod.RenderStyle.terminal_bg.ansi());
                for (x..self.width) |_| try writer.writeByte(' ');
            } else {
                for (0..self.width) |_| try writer.writeByte(' ');
            }
        }
        try writer.writeAll(render_mod.RenderStyle.normal.ansi());
    }

    fn render(self: *Editor, writer: anytype) !void {
        if (self.state.mode == .Dashboard or self.state.mode == .OpenFilePrompt or self.state.mode == .FilesystemPicker) {
            try self.state.dash.render(writer, self.width, self.height);

            if (self.state.mode == .FilesystemPicker) {
                try self.renderFilesystemPickerPopup(writer);
            } else if (self.state.mode == .OpenFilePrompt) {
                try terminal.moveCursor(writer, self.statusTerminalRow(), 1);
                try terminal.clearLine(writer);
                try writer.print("Open file: {s}", .{self.state.command_buffer.items});
                try terminal.moveCursor(writer, self.statusTerminalRow(), 12 + self.state.command_buffer.items.len);
            } else if (self.state.error_message) |err_msg| {
                try terminal.moveCursor(writer, self.statusTerminalRow(), 1);
                try terminal.clearLine(writer);
                try writer.writeAll("\x1b[31;1m"); // Red, Bold
                try writer.print("{s}", .{err_msg});
                try writer.writeAll("\x1b[0m"); // Reset
            }
            return;
        }

        if (self.state.search_system == null) {
            self.state.search_system = search.SearchSystem.init(self.allocator);
        }

        var buf_start_col: usize = 1;
        var buf_width: usize = self.width;

        // Move to top-left (row 2, because of tabs) WITHOUT blanking the screen — eliminates flicker.
        // Each line erases its own tail via \x1b[K; leftover rows cleared below with \x1b[J.
        try terminal.moveHome(writer);

        if (self.state.explorer_visible and self.state.tree != null) {
            const exp_width = (self.width * @as(usize, self.config.explorer.width_percentage)) / 100;
            if (exp_width > 0) {
                // Explorer starts at row 2
                try self.state.tree.?.renderAt(writer, exp_width, self.height - 1, 2, self.state.explorer_focused, if (self.state.git_snapshot) |*s| s else null);

                for (2..self.height) |r| {
                    try terminal.moveCursor(writer, r, exp_width + 1);
                    try writer.writeAll("│");
                }
                buf_start_col = exp_width + 2;
                buf_width = self.width -| (exp_width + 1);
            }
        }

        const tabs_start = if (self.active_keypress_trace != null) perf.nowNs() else 0;
        try self.renderTabs(writer, buf_start_col, buf_width);
        if (self.active_keypress_trace) |trace| trace.tabs_ns += perf.elapsedNs(tabs_start);

        // Line number gutter.
        const tab = self.currentTab();
        const gutter_width: usize = if (tab) |t|
            self.calculateGutterWidth(t.buf.lines.items.len)
        else
            0;

        const visible_rows = self.editorVisibleRows();
        if (tab) |t| {
            const highlight_start = perf.nowNs();
            self.prepareSyntaxForViewport(t, t.scroll_row, t.scroll_row + visible_rows, 20) catch {
                if (self.active_keypress_trace) |trace| trace.syntax_cache = syntax.ViewportCacheStatus.unknown.name();
            };
            if (self.active_keypress_trace) |trace| trace.highlight_ns += perf.elapsedNs(highlight_start);
        }
        const visible_lines_start = if (self.active_keypress_trace != null) perf.nowNs() else 0;
        for (1..visible_rows + 1) |screen_row| {
            // 1. Move to the correct column for the right-hand panel (start at row 3)
            try terminal.moveCursor(writer, screen_row + 2, buf_start_col);

            if (tab) |t| {
                const buffer_line_idx = screen_row + t.scroll_row - 1;
                if (buffer_line_idx < t.buf.lines.items.len) {
                    const trace = self.active_keypress_trace;
                    if (trace) |keypress_trace| keypress_trace.visible_rows += 1;

                    // --- Gutter ---
                    const mc = t.mainCursor();
                    const is_current = (buffer_line_idx == mc.row);
                    const line_num = buffer_line_idx + 1;

                    const num_digits = @max(buffer.countDigits(t.buf.lines.items.len), 2);

                    if (is_current) {
                        try writer.writeAll("\x1b[33;1m"); // bold yellow — current line
                    } else {
                        try writer.writeAll("\x1b[2;37m"); // dim grey - non-current line
                    }

                    // --- Render Gutter ---
                    // Format: " " (1 space) + number (num_digits wide) + " " (1 space)
                    try writer.writeByte(' ');
                    const num_used = buffer.countDigits(line_num);
                    const pad = num_digits - num_used;
                    for (0..pad) |_| try writer.writeByte(' ');
                    try writer.print("{d} ", .{line_num});
                    try writer.writeAll("\x1b[0m"); // Reset

                    // --- Line content ---
                    // No need to moveCursor; we are exactly at buf_start_col + gutter_width
                    const content_width = buf_width -| gutter_width;
                    const line = t.buf.lines.items[buffer_line_idx];
                    const line_len = line.len();

                    var selection_storage: [64]SelectionRange = undefined;
                    var line_state = self.buildLineRenderState(t, buffer_line_idx, content_width, &selection_storage);

                    var char_idx: usize = t.scroll_col;
                    var m_idx: usize = 0;
                    if (line_state.search_match) |m| {
                        while (m_idx < m.indices.len and m.indices[m_idx] < t.scroll_col) : (m_idx += 1) {}
                    }
                    const end_col = @min(line_len, t.scroll_col +| content_width);
                    while (char_idx < end_col) : (char_idx += 1) {
                        if (line_state.syntaxStyleAt(char_idx)) |style| {
                            try writer.writeAll(style.ansi());
                        }

                        if (line_state.isSelected(char_idx)) {
                            try writer.writeAll("\x1b[48;5;239m"); // Dark grey selection
                        }

                        const is_match = if (line_state.search_match) |m| (if (m_idx < m.indices.len and m.indices[m_idx] == char_idx) true else false) else false;
                        if (is_match) {
                            if (line_state.active_match_col != null and line_state.active_match_col.? == char_idx) {
                                try writer.writeAll("\x1b[48;5;214m\x1b[30m"); // Orange background
                            } else {
                                try writer.writeAll("\x1b[48;5;228m\x1b[30m"); // Light Yellow background
                            }
                            m_idx += 1;
                        }

                        const ch = line.byteAt(char_idx).?;
                        if (trace) |keypress_trace| {
                            keypress_trace.visible_chars += 1;
                            keypress_trace.line_byte_reads += 1;
                        }
                        try writer.writeByte(ch);
                        try writer.writeAll("\x1b[0m");
                    }
                }
            }

            // 2. Erase the tail of the line (clears both stale content and avoids wiping explorer)
            try terminal.eraseToLineEnd(writer);
        }
        if (self.active_keypress_trace) |trace| trace.visible_lines_ns += perf.elapsedNs(visible_lines_start);

        const status_start = if (self.active_keypress_trace != null) perf.nowNs() else 0;
        try self.renderStatusLineLegacyStyle(writer, tab);
        if (self.active_keypress_trace) |trace| trace.status_ns += perf.elapsedNs(status_start);

        try self.renderTerminalPanelLegacy(writer);

        const popup_start = if (self.active_keypress_trace != null) perf.nowNs() else 0;
        try self.renderCommandPopup(writer);
        try self.renderGlobalSearchPopup(writer);
        try self.renderFilesystemPickerPopup(writer);
        try self.renderPromptPopup(writer);
        if (self.active_keypress_trace) |trace| trace.popup_ns += perf.elapsedNs(popup_start);

        // Move cursor to proper location
        if (self.state.mode == .Command) {
            if (self.commandPopupGeometry()) |geom| {
                const input_space = geom.width -| 5;
                const cursor_col = @min(self.state.command_popup.input.items.len, input_space);
                try terminal.moveCursor(writer, geom.row + 2, geom.col + 5 + cursor_col);
            }
        } else if (self.state.mode == .GlobalSearch) {
            if (self.globalSearchPopupGeometry()) |geom| {
                const input_space = geom.width -| 5;
                const cursor_col = @min(self.state.global_search.input.items.len, input_space);
                try terminal.moveCursor(writer, geom.row + 2, geom.col + 5 + cursor_col);
            }
        } else if (self.state.mode == .Search) {
            try terminal.moveCursor(writer, self.statusTerminalRow(), 2 + self.state.search_buffer.items.len);
        } else if (self.state.mode == .FilesystemPicker and self.state.filesystem_picker.phase == .entering_name) {
            try terminal.moveCursor(writer, self.statusTerminalRow(), self.width);
        } else if (self.state.mode == .Prompt) {
            try terminal.moveCursor(writer, self.statusTerminalRow(), self.width);
        } else if (self.state.explorer_focused and self.state.explorer_visible and self.state.tree != null) {
            try terminal.moveCursor(writer, self.statusTerminalRow(), self.width);
        } else if (self.state.mode == .Terminal) {
            const pos = self.terminalCursorScreenPosition();
            try terminal.moveCursor(writer, pos.row, pos.col);
        } else if (tab) |t| {
            // Offset cursor past the line-number gutter
            const content_width = buf_width -| gutter_width;

            // Draw all cursors
            for (t.cursors.items, 0..) |cursor, i| {
                const vis_col = visibleCursorCol(cursor.col, t.scroll_col, content_width);
                if (cursor.row >= t.scroll_row and cursor.row < t.scroll_row + visible_rows) {
                    const vis_row = cursor.row - t.scroll_row + 3;
                    try terminal.moveCursor(writer, vis_row, buf_start_col + gutter_width + vis_col);

                    if (i == t.main_cursor_idx) {
                        // Main cursor is handled by the terminal's hardware cursor usually,
                        // but we need to move it there last.
                    } else {
                        // Secondary cursors - just a block highlight or something
                        try writer.writeAll("\x1b[7m \x1b[27m"); // Inverse space
                    }
                }
            }

            // Finally move hardware cursor to main cursor position
            const mc = t.mainCursor();
            const vis_col = visibleCursorCol(mc.col, t.scroll_col, content_width);
            const vis_row = if (mc.row >= t.scroll_row)
                mc.row - t.scroll_row + 3
            else
                3;
            try terminal.moveCursor(writer, vis_row, buf_start_col + gutter_width + vis_col);
        }
    }

    /// Calculates total gutter width: 1 space + num_digits + 1 space separator.
    pub fn calculateGutterWidth(self: *const Editor, total_lines: usize) usize {
        _ = self;
        return renderer_mod.calculateGutterWidth(total_lines);
    }

    fn canUseVirtualRenderer(self: *const Editor) bool {
        return self.state.mode != .Dashboard and
            self.state.mode != .OpenFilePrompt and
            self.state.mode != .FilesystemPicker and
            self.state.mode != .Prompt and
            !self.state.explorer_visible and
            !self.state.lsp_ui.completion_active;
    }

    fn renderVirtual(self: *Editor, writer: anytype, metrics: *perf.FrameMetrics) !void {
        if (try self.renderer.screen.resize(self.width, self.height)) {
            self.renderer.screen_renderer.invalidate(.full);
        }
        self.renderer.screen.clear();

        var status_buf: [160]u8 = undefined;
        const ctx = self.buildRenderContext(&status_buf);

        const tabs_start = if (self.active_keypress_trace != null) perf.nowNs() else 0;
        self.renderVirtualTabs();
        if (self.active_keypress_trace) |trace| trace.tabs_ns += perf.elapsedNs(tabs_start);

        if (ctx.tab) |t| {
            const highlight_start = perf.nowNs();
            self.prepareSyntaxForViewport(t, t.scroll_row, t.scroll_row + ctx.visible_rows, 20) catch {
                if (self.active_keypress_trace) |trace| trace.syntax_cache = syntax.ViewportCacheStatus.unknown.name();
            };
            const highlight_elapsed = perf.elapsedNs(highlight_start);
            metrics.add(.highlight_viewport, highlight_elapsed);
            if (self.active_keypress_trace) |trace| trace.highlight_ns += highlight_elapsed;

            const visible_lines_start = if (self.active_keypress_trace != null) perf.nowNs() else 0;
            for (0..ctx.visible_rows) |screen_row| {
                const buffer_line_idx = screen_row + t.scroll_row;
                const row = screen_row + 2;
                if (buffer_line_idx >= t.buf.lines.items.len) continue;
                self.renderVirtualLine(t, buffer_line_idx, row, ctx.gutter_width);
            }
            if (self.active_keypress_trace) |trace| trace.visible_lines_ns += perf.elapsedNs(visible_lines_start);
        }

        const popup_start = if (self.active_keypress_trace != null) perf.nowNs() else 0;
        self.renderVirtualCommandPopup();
        self.renderVirtualGlobalSearchPopup();
        if (self.active_keypress_trace) |trace| trace.popup_ns += perf.elapsedNs(popup_start);
        const status_start = if (self.active_keypress_trace != null) perf.nowNs() else 0;
        self.renderVirtualStatus(ctx);
        if (self.active_keypress_trace) |trace| trace.status_ns += perf.elapsedNs(status_start);
        self.renderVirtualTerminalPanel();
        const emit_start = if (self.active_keypress_trace != null) perf.nowNs() else 0;
        const emit_bytes = try self.renderer.screen_renderer.emit(writer, &self.renderer.screen);
        if (self.active_keypress_trace) |trace| {
            trace.virtual_emit_ns += perf.elapsedNs(emit_start);
            trace.virtual_emit_bytes += emit_bytes;
        }
        const tab_separator_bytes = try self.renderVirtualTabSeparator(writer);
        if (self.active_keypress_trace) |trace| trace.tab_separator_bytes += tab_separator_bytes;
        try self.moveVirtualCursor(writer, ctx.tab, ctx.gutter_width, ctx.visible_rows);
    }

    fn renderVirtualTabSeparator(self: *Editor, writer: anytype) !usize {
        if (self.height < 2 or self.width == 0) return 0;
        try terminal.moveCursor(writer, 2, 1);
        try writer.writeAll("\x1b[2;37m");
        for (0..self.width) |_| try writer.writeAll("─");
        try writer.writeAll("\x1b[0m");
        return "\x1b[2;1H".len + "\x1b[2;37m".len + (self.width * "─".len) + "\x1b[0m".len;
    }

    fn renderVirtualTabs(self: *Editor) void {
        if (self.height == 0 or self.width == 0) return;
        if (self.state.tabs.items.len == 0) {
            self.renderer.screen.fillRow(1, '-', .dim);
            return;
        }

        const layout = self.prepareTabBarLayout(self.width);
        if (layout.has_hidden_left) {
            self.renderer.screen.set(0, 0, '<', .dim);
        }
        if (layout.content_width > 0) {
            const viewport_start = layout.scroll_col;
            const viewport_end = viewport_start + layout.content_width;
            var label_start: usize = 0;
            for (self.state.tabs.items, 0..) |*tab, i| {
                const label_width = tabLabelWidth(tab);
                if (label_start >= viewport_end) break;
                if (label_start + label_width > viewport_start) {
                    self.writeVirtualClippedTabLabel(0, layout.content_start_col, label_start, viewport_start, viewport_end, tab, i == self.state.active_tab_index);
                }
                label_start += label_width;
            }
        }
        if (layout.has_hidden_right) {
            self.renderer.screen.set(0, self.width - 1, '>', .dim);
        }

        self.renderer.screen.fillRow(1, '-', .dim);
    }

    fn renderVirtualCommandPopup(self: *Editor) void {
        const geom = self.commandPopupGeometry() orelse return;
        const popup = &self.state.command_popup;
        const inner_width = geom.width - 2;
        const title_col = if (geom.width > command_popup_title.len)
            geom.col + (geom.width - command_popup_title.len) / 2
        else
            geom.col;

        self.renderer.screen.set(geom.row, geom.col, '+', .command_popup_border);
        for (1..geom.width - 1) |i| self.renderer.screen.set(geom.row, geom.col + i, '-', .command_popup_border);
        self.renderer.screen.set(geom.row, geom.col + geom.width - 1, '+', .command_popup_border);
        if (command_popup_title.len + 2 < geom.width) {
            self.renderer.screen.writeText(geom.row, title_col, command_popup_title, .command_popup_border);
        }

        const input_row = geom.row + 1;
        self.renderer.screen.set(input_row, geom.col, '|', .command_popup_border);
        self.renderer.screen.set(input_row, geom.col + geom.width - 1, '|', .command_popup_border);
        for (1..geom.width - 1) |i| self.renderer.screen.set(input_row, geom.col + i, ' ', .command_popup);
        self.renderer.screen.writeText(input_row, geom.col + 2, ">", .command_popup_prompt);
        const input_space = inner_width -| 3;
        const shown_input = popup.input.items[0..@min(popup.input.items.len, input_space)];
        self.renderer.screen.writeText(input_row, geom.col + 4, shown_input, .command_popup);

        for (0..geom.suggestion_count) |i| {
            const row = geom.row + 2 + i;
            const style: render_mod.RenderStyle = if (popup.selected_index != null and popup.selected_index.? == i)
                .command_popup_selected
            else
                .command_popup;
            self.renderer.screen.set(row, geom.col, '|', .command_popup_border);
            self.renderer.screen.set(row, geom.col + geom.width - 1, '|', .command_popup_border);
            for (1..geom.width - 1) |col_offset| self.renderer.screen.set(row, geom.col + col_offset, ' ', style);
            const suggestion = popup.suggestions.items[i].name();
            const shown = suggestion[0..@min(suggestion.len, inner_width -| 2)];
            self.renderer.screen.writeText(row, geom.col + 2, shown, style);
        }

        const bottom_row = geom.row + 2 + geom.suggestion_count;
        self.renderer.screen.set(bottom_row, geom.col, '+', .command_popup_border);
        for (1..geom.width - 1) |i| self.renderer.screen.set(bottom_row, geom.col + i, '-', .command_popup_border);
        self.renderer.screen.set(bottom_row, geom.col + geom.width - 1, '+', .command_popup_border);
    }

    fn writeVirtualTruncated(self: *Editor, row: usize, col: *usize, end_col: usize, text: []const u8, style: render_mod.RenderStyle) void {
        if (col.* >= end_col) return;
        const remaining = end_col - col.*;
        const shown = text[0..@min(text.len, remaining)];
        self.renderer.screen.writeText(row, col.*, shown, style);
        col.* += shown.len;
    }

    fn globalSearchFileStyle(selected: bool) render_mod.RenderStyle {
        return if (selected) .global_search_file_selected else .global_search_file;
    }

    fn globalSearchResultStyle(selected: bool) render_mod.RenderStyle {
        return if (selected) .global_search_result_selected else .global_search_result;
    }

    fn renderVirtualGlobalSearchRowText(self: *Editor, row: usize, start_col: usize, end_col: usize, render_row: GlobalSearchRenderRow, results: []const global_search.GlobalSearchResult, selected: bool) void {
        var col = start_col;
        switch (render_row) {
            .header => |display_path| {
                self.writeVirtualTruncated(row, &col, end_col, display_path, globalSearchFileStyle(false));
            },
            .path => |result_index| {
                const path = results[result_index].path;
                self.writeVirtualTruncated(row, &col, end_col, path.display_path, globalSearchFileStyle(selected));
            },
            .content => |result_index| {
                const content = results[result_index].content;
                const style = globalSearchResultStyle(selected);
                self.writeVirtualTruncated(row, &col, end_col, "  ", style);
                var location_buf: [48]u8 = undefined;
                const location = std.fmt.bufPrint(&location_buf, "{d}:{d}  ", .{ content.row + 1, content.col + 1 }) catch "";
                self.writeVirtualTruncated(row, &col, end_col, location, style);
                self.writeVirtualTruncated(row, &col, end_col, content.snippet, style);
            },
        }
    }

    fn renderVirtualGlobalSearchPopup(self: *Editor) void {
        const geom = self.globalSearchPopupGeometry() orelse return;
        const popup = &self.state.global_search;
        const inner_width = geom.width - 2;
        const title_col = if (geom.width > global_search_popup_title.len)
            geom.col + (geom.width - global_search_popup_title.len) / 2
        else
            geom.col;

        self.renderer.screen.set(geom.row, geom.col, '+', .global_search_popup_border);
        for (1..geom.width - 1) |i| self.renderer.screen.set(geom.row, geom.col + i, '-', .global_search_popup_border);
        self.renderer.screen.set(geom.row, geom.col + geom.width - 1, '+', .global_search_popup_border);
        if (global_search_popup_title.len + 2 < geom.width) {
            self.renderer.screen.writeText(geom.row, title_col, global_search_popup_title, .global_search_popup_border);
        }

        const input_row = geom.row + 1;
        self.renderer.screen.set(input_row, geom.col, '|', .global_search_popup_border);
        self.renderer.screen.set(input_row, geom.col + geom.width - 1, '|', .global_search_popup_border);
        for (1..geom.width - 1) |i| self.renderer.screen.set(input_row, geom.col + i, ' ', .command_popup);
        self.renderer.screen.writeText(input_row, geom.col + 2, ">", .command_popup_prompt);
        const input_space = inner_width -| 3;
        const shown_input = popup.input.items[0..@min(popup.input.items.len, input_space)];
        self.renderer.screen.writeText(input_row, geom.col + 4, shown_input, .command_popup);

        self.adjustGlobalSearchRenderScroll(geom.suggestion_count);
        for (0..geom.suggestion_count) |offset| {
            const render_row_index = self.state.global_search.scroll_offset + offset;
            const render_row = globalSearchRenderRowAt(popup.results.items, render_row_index) orelse break;
            const row = geom.row + 2 + offset;
            const selected = switch (render_row) {
                .path => |result_index| popup.selected_index != null and popup.selected_index.? == result_index,
                .content => |result_index| popup.selected_index != null and popup.selected_index.? == result_index,
                .header => false,
            };
            const style: render_mod.RenderStyle = if (selected)
                .command_popup_selected
            else
                .command_popup;
            self.renderer.screen.set(row, geom.col, '|', .global_search_popup_border);
            self.renderer.screen.set(row, geom.col + geom.width - 1, '|', .global_search_popup_border);
            for (1..geom.width - 1) |col_offset| self.renderer.screen.set(row, geom.col + col_offset, ' ', style);
            self.renderVirtualGlobalSearchRowText(row, geom.col + 2, geom.col + geom.width - 1, render_row, popup.results.items, selected);
        }

        const bottom_row = geom.row + 2 + geom.suggestion_count;
        self.renderer.screen.set(bottom_row, geom.col, '+', .global_search_popup_border);
        for (1..geom.width - 1) |i| self.renderer.screen.set(bottom_row, geom.col + i, '-', .global_search_popup_border);
        self.renderer.screen.set(bottom_row, geom.col + geom.width - 1, '+', .global_search_popup_border);
    }

    fn renderVirtualTerminalPanel(self: *Editor) void {
        const panel_height = self.terminalPanelHeight();
        if (panel_height == 0 or self.width == 0) return;

        const start_row = self.height - panel_height;
        for (start_row..self.height) |row| {
            self.renderer.screen.fillRow(row, ' ', .terminal_bg);
        }

        self.renderer.screen.fillRow(start_row, '-', .terminal_border);
        const title = if (self.terminal_panel.focused) " Terminal [focused] " else " Terminal ";
        const title_style: render_mod.RenderStyle = if (self.terminal_panel.focused) .terminal_focus else .terminal_title;
        if (self.width > 2) {
            self.renderer.screen.writeText(start_row, 1, title[0..@min(title.len, self.width - 1)], title_style);
        }

        const body_height = panel_height -| 1;
        if (body_height == 0) return;

        self.terminal_panel.resizePty(self.width, body_height);
        self.terminal_panel.clampScroll(body_height);
        const total_lines = self.terminal_panel.renderLineCount();
        const end = total_lines -| @min(self.terminal_panel.scroll_offset, total_lines);
        const shown = @min(body_height, end);
        const first = end - shown;
        for (0..shown) |offset| {
            const row = start_row + 1 + offset;
            const line = self.terminal_panel.renderLineAt(first + offset) orelse continue;
            const max_cols = self.width;
            for (line.cells.items[0..@min(line.cells.items.len, max_cols)], 0..) |cell, col| {
                self.renderer.screen.set(row, col, cell.ch, terminalCellStyle(cell));
            }
            if (self.terminal_panel.focused and first + offset == self.terminal_panel.cursorRenderIndex()) {
                const cursor_col = @min(self.terminal_panel.cursor_col, max_cols -| 1);
                const ch = if (cursor_col < line.cells.items.len) line.cells.items[cursor_col].ch else ' ';
                self.renderer.screen.set(row, cursor_col, ch, .terminal_cursor);
            }
        }
    }

    fn renderVirtualLine(self: *Editor, tab: *Tab, buffer_line_idx: usize, row: usize, gutter_width: usize) void {
        const trace = self.active_keypress_trace;
        if (trace) |keypress_trace| keypress_trace.visible_rows += 1;

        const mc = tab.mainCursor();
        const is_current = buffer_line_idx == mc.row;
        const line_num = buffer_line_idx + 1;

        var gutter_buf: [32]u8 = undefined;
        const num_digits = @max(buffer.countDigits(tab.buf.lines.items.len), 2);
        const gutter = std.fmt.bufPrint(&gutter_buf, "{d}", .{line_num}) catch "";
        var gutter_col: usize = 1;
        if (num_digits > gutter.len) {
            gutter_col += num_digits - gutter.len;
        }
        self.renderer.screen.writeText(row, gutter_col, gutter, if (is_current) .gutter_current else .dim);

        const content_col = gutter_width;
        const content_width = self.width -| content_col;
        const line = tab.buf.lines.items[buffer_line_idx];
        const line_len = line.len();

        var selection_storage: [64]SelectionRange = undefined;
        var line_state = self.buildLineRenderState(tab, buffer_line_idx, content_width, &selection_storage);

        var char_idx: usize = tab.scroll_col;
        var m_idx: usize = 0;
        if (line_state.search_match) |m| {
            while (m_idx < m.indices.len and m.indices[m_idx] < tab.scroll_col) : (m_idx += 1) {}
        }
        const end_col = @min(line_len, tab.scroll_col +| content_width);
        while (char_idx < end_col) : (char_idx += 1) {
            const ch = line.byteAt(char_idx) orelse ' ';
            if (trace) |keypress_trace| {
                keypress_trace.visible_chars += 1;
                keypress_trace.line_byte_reads += 1;
            }
            var style: render_mod.RenderStyle = if (line_state.syntaxStyleAt(char_idx)) |syntax_style|
                renderStyleFromSyntax(syntax_style)
            else
                .normal;

            if (line_state.isSelected(char_idx)) {
                style = .selection;
            }

            const is_match = if (line_state.search_match) |m| m_idx < m.indices.len and m.indices[m_idx] == char_idx else false;
            if (is_match) {
                if (line_state.active_match_col != null and line_state.active_match_col.? == char_idx) {
                    style = .search_active;
                } else {
                    style = .search_match;
                }
                m_idx += 1;
            }

            self.renderer.screen.set(row, content_col + (char_idx - tab.scroll_col), ch, style);
        }
    }

    fn renderVirtualStatus(self: *Editor, ctx: RenderContext) void {
        if (self.height == 0) return;
        const row = self.statusRowIndex();
        self.renderer.screen.fillRow(row, ' ', .status_bg);

        var col: usize = 0;
        self.writeVirtualStatusLeft(row, &col, ctx.tab);

        var right_buf: [192]u8 = undefined;
        const right = self.buildRightStatusLayout(ctx.tab, &right_buf) catch RightStatusLayout{ .text = "" };
        const right_cells = render_mod.displayCellCount(right.text) + 1;
        if (right_cells < self.width) {
            const start = self.width - right_cells;
            self.renderer.screen.writeText(row, start, "", .status_sep_right);
            self.renderer.screen.writeText(row, start + 1, right.text, .status_right);
            self.cacheRightStatusLayout(right, start + 2, right_cells - 1);
        } else {
            self.status_cache.invalidate();
        }
    }

    fn writeVirtualStatusText(self: *Editor, row: usize, col: *usize, text: []const u8, style: render_mod.RenderStyle) void {
        if (col.* >= self.width) return;
        self.renderer.screen.writeText(row, col.*, text, style);
        col.* += @min(render_mod.displayCellCount(text), self.width - col.*);
    }

    fn writeVirtualStatusLeft(self: *Editor, row: usize, col: *usize, tab: ?*Tab) void {
        if (self.state.error_message) |err| {
            self.writeVirtualStatusText(row, col, " ERROR ", .status_error);
            self.writeVirtualStatusText(row, col, "", .status_sep_error);
            self.writeVirtualStatusText(row, col, " ", .status_file);
            self.writeVirtualStatusText(row, col, err, .status_file);
            return;
        }

        var mode_buf: [32]u8 = undefined;
        const mode = std.fmt.bufPrint(&mode_buf, " {s} ", .{self.statusModeLabel()}) catch " NORMAL ";
        self.writeVirtualStatusText(row, col, mode, self.statusModeStyle());
        self.writeVirtualStatusText(row, col, "", self.statusModeSepStyle());

        if (self.state.git_snapshot) |snapshot| {
            if (snapshot.branch) |branch| {
                var branch_buf: [96]u8 = undefined;
                const branch_text = std.fmt.bufPrint(&branch_buf, "  {s} ", .{branch}) catch "";
                self.writeVirtualStatusText(row, col, branch_text, .status_branch);
                self.writeVirtualStatusText(row, col, "", .status_sep_branch);
            }
        }

        var file_buf: [192]u8 = undefined;
        const file_path = self.statusFilePath(tab);
        const file_text = std.fmt.bufPrint(&file_buf, " {s} {s} ", .{ fileIconForName(file_path), file_path }) catch "";
        self.writeVirtualStatusText(row, col, file_text, .status_file);

        if (self.statusContext()) |context| {
            self.writeVirtualStatusText(row, col, "", .status_sep_file);
            var context_buf: [96]u8 = undefined;
            const context_text = std.fmt.bufPrint(&context_buf, " ◆ {s} ", .{context}) catch "";
            self.writeVirtualStatusText(row, col, context_text, .status_context);
        }
        self.writeVirtualStatusText(row, col, "", .status_sep_context);
    }

    fn moveVirtualCursor(self: *Editor, writer: anytype, tab: ?*Tab, gutter_width: usize, visible_rows: usize) !void {
        if (self.state.mode == .Command) {
            if (self.commandPopupGeometry()) |geom| {
                const input_space = geom.width -| 5;
                const cursor_col = @min(self.state.command_popup.input.items.len, input_space);
                try terminal.moveCursor(writer, geom.row + 2, geom.col + 5 + cursor_col);
            }
            return;
        }
        if (self.state.mode == .GlobalSearch) {
            if (self.globalSearchPopupGeometry()) |geom| {
                const input_space = geom.width -| 5;
                const cursor_col = @min(self.state.global_search.input.items.len, input_space);
                try terminal.moveCursor(writer, geom.row + 2, geom.col + 5 + cursor_col);
            }
            return;
        }
        if (self.state.mode == .Search) {
            try terminal.moveCursor(writer, self.statusTerminalRow(), 2 + self.state.search_buffer.items.len);
            return;
        }
        if (self.state.mode == .Terminal) {
            const pos = self.terminalCursorScreenPosition();
            try terminal.moveCursor(writer, pos.row, pos.col);
            return;
        }

        const t = tab orelse return;
        const content_width = self.width -| gutter_width;
        const mc = t.mainCursor();
        const vis_col = visibleCursorCol(mc.col, t.scroll_col, content_width);
        const vis_row = if (mc.row >= t.scroll_row and mc.row < t.scroll_row + visible_rows)
            mc.row - t.scroll_row + 3
        else
            3;
        try terminal.moveCursor(writer, vis_row, gutter_width + vis_col + 1);
    }

    fn isSelected(self: *const Editor, tab: *const Tab, row: usize, col: usize) bool {
        _ = self;
        for (tab.cursors.items) |cursor| {
            if (cursor.selection_start) |ss| {
                const s_row = @min(ss.row, cursor.row);
                const e_row = @max(ss.row, cursor.row);
                const s_col = if (ss.row < cursor.row) ss.col else if (ss.row > cursor.row) cursor.col else @min(ss.col, cursor.col);
                const e_col = if (ss.row < cursor.row) cursor.col else if (ss.row > cursor.row) ss.col else @max(ss.col, cursor.col);

                if (row > s_row and row < e_row) return true;
                if (row == s_row and row == e_row and col >= s_col and col < e_col) return true;
                if (row == s_row and row != e_row and col >= s_col) return true;
                if (row == e_row and row != s_row and col < e_col) return true;
            }
        }
        return false;
    }

    fn renderStyleFromSyntax(style: syntax.Style) render_mod.RenderStyle {
        return switch (style) {
            .keyword => .keyword,
            .string => .string,
            .comment => .comment,
            .number => .number,
            .constant => .constant,
            .type => .type_name,
            .function => .function_name,
            .property => .property,
            .operator => .operator,
            .punctuation => .punctuation,
        };
    }

    fn diagnosticUri(value: std.json.Value) ?[]const u8 {
        if (value != .object) return null;
        const uri = value.object.get("uri") orelse return null;
        if (uri != .string) return null;
        const diagnostics = value.object.get("diagnostics") orelse return null;
        if (diagnostics != .array) return null;
        return uri.string;
    }

    fn isValidCompletionValue(value: std.json.Value) bool {
        if (value == .array) return true;
        if (value == .object) {
            const items = value.object.get("items") orelse return false;
            return items == .array;
        }
        return false;
    }

    fn completionItemObject(value: std.json.Value) ?std.json.ObjectMap {
        if (value != .object) return null;
        return value.object;
    }

    fn completionItemString(item: std.json.ObjectMap, key: []const u8) ?[]const u8 {
        const value = item.get(key) orelse return null;
        if (value != .string) return null;
        return value.string;
    }

    fn renderCompletionMenu(self: *Editor, writer: anytype) !void {
        if (!self.state.lsp_ui.completion_active or self.state.lsp_ui.completion_items == null) return;

        const tab = self.currentTab() orelse return;
        const mc = tab.mainCursor();

        const viewport = self.bufferViewportGeometry();
        const gutter_width = self.calculateGutterWidth(tab.buf.lines.items.len);
        const content_width = viewport.width -| gutter_width;

        // Relative row in viewport
        const rel_row = mc.row - tab.scroll_row;
        const col = viewport.start_col + gutter_width + visibleCursorCol(mc.col, tab.scroll_col, content_width);

        const items = self.state.lsp_ui.completionItems();

        if (items.len == 0) {
            self.state.lsp_ui.clearCompletion();
            return;
        }

        const max_height = 10;
        const visible_count = @min(items.len, max_height);

        // Flipped menu if near bottom
        var row = rel_row + 3 + 1;
        if (row + visible_count >= self.height - 1) {
            row = (rel_row + 3) -| visible_count;
        }

        // Handle scrolling in the menu
        var scroll_top: usize = 0;
        if (self.state.lsp_ui.completion_selected >= max_height) {
            scroll_top = self.state.lsp_ui.completion_selected - max_height + 1;
        }

        // Draw background/border
        for (0..visible_count) |i| {
            const item_idx = scroll_top + i;
            if (item_idx >= items.len) break;

            try terminal.moveCursor(writer, row + i, col);

            if (item_idx == self.state.lsp_ui.completion_selected) {
                try writer.writeAll("\x1b[48;5;25m\x1b[38;5;255m"); // Blue selection, white text
            } else {
                try writer.writeAll("\x1b[48;5;236m\x1b[38;5;250m"); // Dark grey background, light grey text
            }

            const item = completionItemObject(items[item_idx]) orelse continue;
            const label = completionItemString(item, "label") orelse continue;
            const kind_val = if (item.get("kind")) |k|
                if (k == .integer) @as(u8, @intCast(k.integer)) else @as(u8, 0)
            else
                @as(u8, 0);

            const kind_str = switch (kind_val) {
                1 => "Text",
                2 => "Method",
                3 => "Fn",
                4 => "Const",
                5 => "Field",
                6 => "Var",
                7 => "Class",
                8 => "Intf",
                9 => "Mod",
                10 => "Prop",
                13 => "Enum",
                14 => "Key",
                15 => "Snip",
                21 => "Const",
                22 => "Struct",
                else => "",
            };

            // Pad to fixed width and show kind
            try writer.print(" {s: <6} │ {s: <30} ", .{ kind_str, label[0..@min(label.len, 30)] });

            // If selected, maybe show detail on the right
            if (item_idx == self.state.lsp_ui.completion_selected) {
                if (item.get("detail")) |d| {
                    if (d == .string) {
                        const detail = d.string;
                        const detail_col = col + 42;
                        try terminal.moveCursor(writer, row + i, detail_col);
                        try writer.writeAll("\x1b[48;5;238m\x1b[38;5;252m"); // Slightly lighter grey for detail
                        try writer.print(" {s} ", .{detail[0..@min(detail.len, 40)]});
                    }
                }
            }

            try writer.writeAll("\x1b[0m");
        }
    }

    fn handleCompletionInput(self: *Editor, event: terminal.KeyEvent) !bool {
        if (!self.state.lsp_ui.completion_active or self.state.lsp_ui.completion_items == null) return false;
        const items = self.state.lsp_ui.completionItems();

        if (event.eql(self.keys.completion_previous)) {
            if (self.state.lsp_ui.completion_selected > 0) {
                self.state.lsp_ui.completion_selected -= 1;
            } else if (items.len > 0) {
                self.state.lsp_ui.completion_selected = items.len - 1;
            }
            return true;
        }

        if (event.eql(self.keys.completion_next)) {
            if (self.state.lsp_ui.completion_selected < items.len - 1) {
                self.state.lsp_ui.completion_selected += 1;
            } else {
                self.state.lsp_ui.completion_selected = 0;
            }
            return true;
        }

        if (event.eql(self.keys.completion_accept)) {
            if (items.len == 0) {
                self.state.lsp_ui.clearCompletion();
                return false;
            }
            const item = completionItemObject(items[self.state.lsp_ui.completion_selected]) orelse {
                self.state.lsp_ui.clearCompletion();
                return false;
            };
            const label = completionItemString(item, "label") orelse {
                self.state.lsp_ui.clearCompletion();
                return false;
            };
            const insertText = completionItemString(item, "insertText") orelse label;

            // Insert the completion
            if (self.currentTab()) |tab| {
                const mc = tab.mainCursor();
                // Simple insertion for now.
                // TODO: handle overwrite and snippets.
                for (insertText) |c| {
                    try tab.buf.insertChar(mc.row, mc.col, c);
                    mc.col += 1;
                }
            }

            self.state.lsp_ui.clearCompletion();
            return true;
        }

        if (event.eql(self.keys.completion_cancel)) {
            self.state.lsp_ui.clearCompletion();
            return true;
        }

        switch (event.key) {
            .Char => {
                if (!std.ascii.isAlphanumeric(event.char)) {
                    self.state.lsp_ui.clearCompletion();
                    return false;
                }
                return false;
            },
            else => {
                self.state.lsp_ui.clearCompletion();
                return false;
            },
        }
    }
};

test "Editor.calculateGutterWidth" {
    const cfg = config.Config{};
    var ed = try Editor.init(std.testing.allocator, std.testing.io, cfg);
    defer ed.deinit();
    ed.width = 120;
    ed.height = 24;

    // 1-99 lines => 2 digits min => 1 + 2 + 1 = 4
    try std.testing.expectEqual(@as(usize, 4), ed.calculateGutterWidth(5));
    try std.testing.expectEqual(@as(usize, 4), ed.calculateGutterWidth(99));

    // 100-999 lines => 3 digits => 1 + 3 + 1 = 5
    try std.testing.expectEqual(@as(usize, 5), ed.calculateGutterWidth(100));
    try std.testing.expectEqual(@as(usize, 5), ed.calculateGutterWidth(999));
}

fn addNamedTestTab(state: *state_mod.EditorState, allocator: std.mem.Allocator, name: []const u8) !void {
    var buf = try buffer.Buffer.init(allocator);
    errdefer buf.deinit();
    try buf.setFilename(name);
    try std.testing.expect(try state.addTab(allocator, buf));
}

test "tab bar scroll follows active tab with variable label widths" {
    const allocator = std.testing.allocator;
    var state = state_mod.EditorState.init(allocator);
    defer state.deinit(allocator);

    try addNamedTestTab(&state, allocator, "a.zig");
    try addNamedTestTab(&state, allocator, "very_long_filename_one.zig");
    try addNamedTestTab(&state, allocator, "b.zig");
    try addNamedTestTab(&state, allocator, "another_long_filename_two.zig");

    state.active_tab_index = 3;
    Editor.ensureActiveTabVisible(state.tabs.items, state.active_tab_index, 20, &state.tab_bar_scroll_col);
    const active_start = Editor.tabStartCol(state.tabs.items, state.active_tab_index);
    const active_end = active_start + Editor.tabLabelWidth(&state.tabs.items[state.active_tab_index]);
    try std.testing.expect(state.tab_bar_scroll_col < active_end);
    try std.testing.expect(active_start < state.tab_bar_scroll_col + 20);
    try std.testing.expect(active_end <= state.tab_bar_scroll_col + 20);

    state.active_tab_index = 1;
    Editor.ensureActiveTabVisible(state.tabs.items, state.active_tab_index, 20, &state.tab_bar_scroll_col);
    const left_active_start = Editor.tabStartCol(state.tabs.items, state.active_tab_index);
    try std.testing.expect(state.tab_bar_scroll_col <= left_active_start);
}

test "tab bar layout clamps stale scroll and reserves continuation markers" {
    const cfg = config.Config{};
    var ed = try Editor.init(std.testing.allocator, std.testing.io, cfg);
    defer ed.deinit();

    try addNamedTestTab(&ed.state, ed.allocator, "short.zig");
    try addNamedTestTab(&ed.state, ed.allocator, "a_much_longer_name.zig");
    try addNamedTestTab(&ed.state, ed.allocator, "tail.zig");

    ed.state.active_tab_index = 2;
    ed.state.tab_bar_scroll_col = 9999;
    const narrow = ed.prepareTabBarLayout(12);
    try std.testing.expect(narrow.has_hidden_left);
    try std.testing.expect(narrow.content_width <= 12);
    try std.testing.expect(ed.state.tab_bar_scroll_col < narrow.total_width);

    ed.state.active_tab_index = 0;
    const wide = ed.prepareTabBarLayout(200);
    try std.testing.expectEqual(@as(usize, 0), ed.state.tab_bar_scroll_col);
    try std.testing.expect(!wide.has_hidden_left);
    try std.testing.expect(!wide.has_hidden_right);
}

test "Editor command mode status uses command segment label" {
    const cfg = config.Config{};
    var ed = try Editor.init(std.testing.allocator, std.testing.io, cfg);
    defer ed.deinit();

    ed.state.mode = .Command;
    var status_buf: [160]u8 = undefined;
    const status_text = try ed.buildStatusText(null, &status_buf);

    try std.testing.expectEqual(render_mod.RenderStyle.status_mode_command, ed.statusModeStyle());
    try std.testing.expect(std.mem.indexOf(u8, status_text, "COMMAND") != null);
}

test "Editor status includes branch file context and diagnostics" {
    const cfg = config.Config{};
    var ed = try Editor.init(std.testing.allocator, std.testing.io, cfg);
    defer ed.deinit();
    ed.width = 120;
    ed.height = 24;

    var buf = try buffer.Buffer.init(std.testing.allocator);
    try buf.setFilename("src/config.zig");
    try std.testing.expect(try ed.state.addTab(ed.allocator, buf));
    ed.state.mode = .Prompt;
    ed.state.prompt_popup.kind = .explorer_rename;

    var snapshot = @import("git_status.zig").Snapshot.init(std.testing.allocator);
    snapshot.branch = try std.testing.allocator.dupe(u8, "main");
    ed.state.git_snapshot = snapshot;

    var diagnostics = std.json.Array.init(std.testing.allocator);
    try diagnostics.append(.null);
    var obj: std.json.ObjectMap = .{};
    try obj.put(std.testing.allocator, try std.testing.allocator.dupe(u8, "diagnostics"), .{ .array = diagnostics });
    try ed.state.lsp_ui.replaceDiagnostics("src/config.zig", .{ .object = obj });

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try ed.renderStatusLineLegacyStyle(&out.writer, ed.currentTab());

    const rendered = out.written();
    try std.testing.expect(std.mem.indexOf(u8, rendered, " main") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, " src/config.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "◆ explorer_rename") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, " 1") != null);
}

test "Editor status omits git branch outside repository and keeps error" {
    const cfg = config.Config{};
    var ed = try Editor.init(std.testing.allocator, std.testing.io, cfg);
    defer ed.deinit();

    ed.width = 80;
    ed.height = 24;
    ed.state.error_message = "boom";

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try ed.renderStatusLineLegacyStyle(&out.writer, null);

    const rendered = out.written();
    try std.testing.expect(std.mem.indexOf(u8, rendered, "ERROR") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "boom") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "") == null);
}

fn visibleCellsIgnoringAnsi(bytes: []const u8) usize {
    var cells: usize = 0;
    var i: usize = 0;
    while (i < bytes.len) {
        if (bytes[i] == 0x1b) {
            i += 1;
            if (i < bytes.len and bytes[i] == '[') {
                i += 1;
                while (i < bytes.len) : (i += 1) {
                    const b = bytes[i];
                    if (b >= 0x40 and b <= 0x7e) {
                        i += 1;
                        break;
                    }
                }
            }
            continue;
        }
        const len = @min(render_mod.utf8CellLen(bytes[i]), bytes.len - i);
        i += len;
        cells += 1;
    }
    return cells;
}

test "Editor legacy status never writes past terminal width" {
    const cfg = config.Config{};
    var ed = try Editor.init(std.testing.allocator, std.testing.io, cfg);
    defer ed.deinit();
    ed.width = 40;
    ed.height = 24;

    var buf = try buffer.Buffer.init(std.testing.allocator);
    try buf.setFilename("src/a/very/long/path/that/would/wrap/without/clipping/config.zig");
    try std.testing.expect(try ed.state.addTab(ed.allocator, buf));
    ed.state.mode = .Prompt;
    ed.state.prompt_popup.kind = .explorer_rename;

    var snapshot = @import("git_status.zig").Snapshot.init(std.testing.allocator);
    snapshot.branch = try std.testing.allocator.dupe(u8, "feature/very-long-branch-name");
    ed.state.git_snapshot = snapshot;

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try ed.renderStatusLineLegacyStyle(&out.writer, ed.currentTab());

    try std.testing.expect(visibleCellsIgnoringAnsi(out.written()) <= ed.width);
}

test "Editor discards stale syntax parse results" {
    try logger.init(std.testing.io, std.testing.allocator, true);
    defer logger.shutdown() catch {};

    var ed = try Editor.init(std.testing.allocator, std.testing.io, .{});
    defer ed.deinit();

    var buf = try buffer.Buffer.init(std.testing.allocator);
    errdefer buf.deinit();
    try buf.setFilename("stale.nope");
    try ed.addTab(buf);

    const tab = ed.currentTab().?;
    tab.buf.revision = 2;
    tab.syntax_requested_revision = 1;

    var result = syntax.ParseResult{
        .buffer_id = tab.syntax_buffer_id,
        .revision = 1,
        .language = .zig,
        .source = try std.testing.allocator.dupe(u8, "const stale = true;\n"),
        .tree = null,
    };
    defer result.deinit(std.testing.allocator);

    try ed.handleSyntaxParseResult(&result);

    try std.testing.expectEqual(@as(?u64, null), tab.syntax_highlighter.parsed_revision);
    try std.testing.expectEqual(@as(?u64, 1), tab.syntax_requested_revision);
}

test "fast cursor move eligibility accepts plain movement inside viewport" {
    var ed = try makeFastMoveTestEditor(std.testing.allocator);
    defer ed.deinit();

    const keys = [_]terminal.KeyEvent{
        ed.keys.move_down,
        ed.keys.move_up,
        ed.keys.move_right,
        ed.keys.move_left,
    };

    for (keys) |key| {
        const tab = ed.currentTab().?;
        tab.mainCursor().row = 1;
        tab.mainCursor().col = 1;
        tab.scroll_row = 0;
        ed.state.mode = .Normal;
        ed.state.explorer_visible = false;
        ed.state.explorer_focused = false;
        ed.state.lsp_ui.completion_active = false;
        ed.state.search_buffer.clearRetainingCapacity();

        const before = ed.captureCursorMoveState().?;
        try input.handleInput(&ed, key);
        try std.testing.expect(ed.canFastRenderCursorMove(before));
    }
}

test "fast cursor move reject reason is null for eligible movement" {
    var ed = try makeFastMoveTestEditor(std.testing.allocator);
    defer ed.deinit();

    const tab = ed.currentTab().?;
    tab.mainCursor().row = 1;
    tab.mainCursor().col = 1;
    tab.scroll_row = 0;

    const before = ed.captureCursorMoveState().?;
    try input.handleInput(&ed, ed.keys.move_right);
    try std.testing.expectEqual(@as(?FastCursorRejectReason, null), ed.fastCursorMoveRejectReason(before));
}

test "horizontal cursor visibility math keeps cursor inside viewport" {
    try std.testing.expectEqual(@as(usize, 0), Editor.horizontalScrollForCursor(0, 0, 10));
    try std.testing.expectEqual(@as(usize, 0), Editor.horizontalScrollForCursor(9, 0, 10));
    try std.testing.expectEqual(@as(usize, 1), Editor.horizontalScrollForCursor(10, 0, 10));
    try std.testing.expectEqual(@as(usize, 16), Editor.horizontalScrollForCursor(25, 10, 10));
    try std.testing.expectEqual(@as(usize, 5), Editor.horizontalScrollForCursor(5, 10, 10));
    try std.testing.expectEqual(@as(usize, 10), Editor.horizontalScrollForCursor(25, 10, 0));
}

test "horizontal scroll commands clamp safely" {
    var ed = try makeFastMoveTestEditor(std.testing.allocator);
    defer ed.deinit();

    ed.width = 14; // 4-cell gutter leaves 10 content columns.
    const tab = ed.currentTab().?;
    tab.mainCursor().row = 0;
    tab.mainCursor().col = 5;
    tab.scroll_col = 10;

    ed.applyHorizontalScrollCommand(.cursor_end);
    try std.testing.expectEqual(@as(usize, 0), tab.scroll_col);

    tab.mainCursor().col = 4;
    ed.applyHorizontalScrollCommand(.right_half);
    try std.testing.expect(tab.scroll_col <= tab.mainCursor().col);
    try std.testing.expect(tab.scroll_col <= tab.buf.lines.items[0].len());
}

test "fast cursor move eligibility rejects scrolling movement" {
    var ed = try makeFastMoveTestEditor(std.testing.allocator);
    defer ed.deinit();

    ed.height = 4;
    const tab = ed.currentTab().?;
    tab.scroll_row = 0;
    tab.mainCursor().row = 0;

    const before = ed.captureCursorMoveState().?;
    try input.handleInput(&ed, ed.keys.move_down);
    try std.testing.expect(!ed.canFastRenderCursorMove(before));
    try std.testing.expectEqual(@as(?FastCursorRejectReason, FastCursorRejectReason.viewport_scrolled), ed.fastCursorMoveRejectReason(before));
}

test "fast cursor move eligibility rejects horizontal scrolling movement" {
    var ed = try makeFastMoveTestEditor(std.testing.allocator);
    defer ed.deinit();

    ed.width = 8; // 4-cell gutter leaves 4 content columns.
    const tab = ed.currentTab().?;
    tab.scroll_row = 0;
    tab.scroll_col = 0;
    tab.mainCursor().row = 0;
    tab.mainCursor().col = 3;

    const before = ed.captureCursorMoveState().?;
    try input.handleInput(&ed, ed.keys.move_right);
    try std.testing.expectEqual(@as(usize, 1), tab.scroll_col);
    try std.testing.expect(!ed.canFastRenderCursorMove(before));
    try std.testing.expectEqual(@as(?FastCursorRejectReason, FastCursorRejectReason.viewport_scrolled), ed.fastCursorMoveRejectReason(before));
}

test "fast cursor move eligibility accepts movement inside horizontal viewport" {
    var ed = try makeFastMoveTestEditor(std.testing.allocator);
    defer ed.deinit();

    ed.width = 8; // 4-cell gutter leaves 4 content columns.
    const tab = ed.currentTab().?;
    tab.scroll_row = 0;
    tab.scroll_col = 1;
    tab.mainCursor().row = 0;
    tab.mainCursor().col = 2;

    const before = ed.captureCursorMoveState().?;
    try input.handleInput(&ed, ed.keys.move_right);
    try std.testing.expectEqual(@as(usize, 1), tab.scroll_col);
    try std.testing.expect(ed.canFastRenderCursorMove(before));
}

test "fast cursor move eligibility rejects active overlays and complex cursors" {
    var ed = try makeFastMoveTestEditor(std.testing.allocator);
    defer ed.deinit();

    {
        const tab = ed.currentTab().?;
        tab.mainCursor().selection_start = .{ .row = 1, .col = 0 };
        tab.mainCursor().row = 1;
        tab.mainCursor().col = 1;
        const before = ed.captureCursorMoveState().?;
        try input.handleInput(&ed, ed.keys.move_right);
        try std.testing.expect(!ed.canFastRenderCursorMove(before));
        try std.testing.expectEqual(@as(?FastCursorRejectReason, FastCursorRejectReason.selection_active), ed.fastCursorMoveRejectReason(before));
        tab.mainCursor().selection_start = null;
    }

    {
        const tab = ed.currentTab().?;
        try tab.cursors.append(ed.allocator, .{ .row = 1, .col = 0 });
        const before = ed.captureCursorMoveState().?;
        try input.handleInput(&ed, ed.keys.move_right);
        try std.testing.expect(!ed.canFastRenderCursorMove(before));
        try std.testing.expectEqual(@as(?FastCursorRejectReason, FastCursorRejectReason.multiple_cursors), ed.fastCursorMoveRejectReason(before));
        _ = tab.cursors.pop();
    }

    const rejection_cases = [_]struct {
        mode: EditorMode = .Normal,
        explorer_visible: bool = false,
        explorer_focused: bool = false,
        completion_active: bool = false,
        search_text: []const u8 = "",
        reason: FastCursorRejectReason,
    }{
        .{ .explorer_visible = true, .explorer_focused = true, .reason = .explorer_focused },
        .{ .completion_active = true, .reason = .completion_active },
        .{ .search_text = "needle", .reason = .search_active },
        .{ .mode = .Command, .reason = .mode },
        .{ .mode = .Search, .reason = .mode },
    };

    for (rejection_cases) |case| {
        const tab = ed.currentTab().?;
        tab.mainCursor().row = 1;
        tab.mainCursor().col = 1;
        tab.scroll_row = 0;
        ed.state.mode = case.mode;
        ed.state.explorer_visible = case.explorer_visible;
        ed.state.explorer_focused = case.explorer_focused;
        ed.state.lsp_ui.completion_active = case.completion_active;
        ed.state.search_buffer.clearRetainingCapacity();
        try ed.state.search_buffer.appendSlice(ed.allocator, case.search_text);

        const before = ed.captureCursorMoveState().?;
        if (case.mode == .Normal) {
            try input.handleInput(&ed, ed.keys.move_right);
        }
        try std.testing.expect(!ed.canFastRenderCursorMove(before));
        try std.testing.expectEqual(@as(?FastCursorRejectReason, case.reason), ed.fastCursorMoveRejectReason(before));
    }
}

test "fast cursor move eligibility allows visible explorer when buffer is focused" {
    var ed = try makeFastMoveTestEditor(std.testing.allocator);
    defer ed.deinit();

    const tab = ed.currentTab().?;
    tab.mainCursor().row = 1;
    tab.mainCursor().col = 1;
    tab.scroll_row = 0;
    ed.state.explorer_visible = true;
    ed.state.explorer_focused = false;

    const before = ed.captureCursorMoveState().?;
    try input.handleInput(&ed, ed.keys.move_right);
    try std.testing.expect(ed.canFastRenderCursorMove(before));
}

test "fast cursor move output stays small and updates status only" {
    var ed = try makeFastMoveTestEditor(std.testing.allocator);
    defer ed.deinit();

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    try ed.renderBenchmarkFrame(&out.writer);
    out.clearRetainingCapacity();

    const tab = ed.currentTab().?;
    tab.mainCursor().row = 0;
    tab.mainCursor().col = 0;
    tab.scroll_row = 0;

    const before = ed.captureCursorMoveState().?;
    try input.handleInput(&ed, ed.keys.move_down);
    try std.testing.expect(ed.canFastRenderCursorMove(before));
    try ed.renderFastCursorMove(&out.writer, before);

    const rendered = out.written();
    try std.testing.expect(rendered.len < 300);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "2:1") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "alpha") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "beta") == null);
}

test "virtual renderer starts visible line content at horizontal scroll column" {
    var ed = try makeFastMoveTestEditor(std.testing.allocator);
    defer ed.deinit();

    const tab = ed.currentTab().?;
    var old_line = tab.buf.lines.orderedRemove(0);
    old_line.deinit();
    try tab.buf.lines.insert(ed.allocator, 0, try buffer.Line.fromSlice(ed.allocator, "0123456789abcdef"));
    tab.mainCursor().row = 0;
    tab.mainCursor().col = 5;
    tab.scroll_col = 5;
    ed.width = 10; // 4-cell gutter leaves 6 content columns.
    ed.height = 8;

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    try ed.renderBenchmarkFrame(&out.writer);
    const rendered = out.written();
    try std.testing.expect(std.mem.indexOf(u8, rendered, "56789a") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "012345") == null);
}

test "fast cursor move overwrites wider cursor position in cached field" {
    var ed = try makeFastMoveTestEditorWithLineCount(std.testing.allocator, 12);
    defer ed.deinit();

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    const tab = ed.currentTab().?;
    tab.mainCursor().row = 8;
    tab.mainCursor().col = 0;
    tab.scroll_row = 0;
    try ed.renderBenchmarkFrame(&out.writer);
    out.clearRetainingCapacity();

    const before = ed.captureCursorMoveState().?;
    try input.handleInput(&ed, ed.keys.move_down);
    try std.testing.expect(ed.canFastRenderCursorMove(before));
    try ed.renderFastCursorMove(&out.writer, before);

    const rendered = out.written();
    try std.testing.expect(rendered.len < 300);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "10:1") != null);
}

test "fast cursor move does not repaint stable status segments" {
    var ed = try makeFastMoveTestEditor(std.testing.allocator);
    defer ed.deinit();

    try ed.currentTab().?.buf.setFilename("src/config.zig");
    var snapshot = @import("git_status.zig").Snapshot.init(std.testing.allocator);
    snapshot.branch = try std.testing.allocator.dupe(u8, "main");
    ed.state.git_snapshot = snapshot;

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    const tab = ed.currentTab().?;
    tab.mainCursor().row = 1;
    tab.mainCursor().col = 0;
    tab.scroll_row = 0;
    try ed.renderBenchmarkFrame(&out.writer);
    out.clearRetainingCapacity();

    const before = ed.captureCursorMoveState().?;
    try input.handleInput(&ed, ed.keys.move_right);
    try std.testing.expect(ed.canFastRenderCursorMove(before));
    try ed.renderFastCursorMove(&out.writer, before);

    const rendered = out.written();
    try std.testing.expect(std.mem.indexOf(u8, rendered, "2:2") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "src/config.zig") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "◇") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "") == null);
}

test "movement coalescing helper accepts repeated plain Down" {
    var ed = try makeFastMoveTestEditor(std.testing.allocator);
    defer ed.deinit();

    const candidate = switch (ed.movementCoalescingEligibilityBefore(ed.keys.move_down)) {
        .eligible => |candidate| candidate,
        .blocked => return error.ExpectedCoalescingEligibility,
    };

    try std.testing.expectEqual(CoalescedMovement.down, candidate.movement);
    try std.testing.expect(ed.coalescingStopReasonForNext(candidate, ed.keys.move_down, 1) == null);
}

test "movement coalescing stores different movement for next input" {
    var ed = try makeFastMoveTestEditor(std.testing.allocator);
    defer ed.deinit();

    const candidate = switch (ed.movementCoalescingEligibilityBefore(ed.keys.move_down)) {
        .eligible => |candidate| candidate,
        .blocked => return error.ExpectedCoalescingEligibility,
    };

    try std.testing.expectEqual(
        MovementCoalesceStopReason.different_key,
        ed.coalescingStopReasonForNext(candidate, ed.keys.move_up, 1).?,
    );
}

test "movement coalescing stores printable input for next input" {
    var ed = try makeFastMoveTestEditor(std.testing.allocator);
    defer ed.deinit();

    const candidate = switch (ed.movementCoalescingEligibilityBefore(ed.keys.move_down)) {
        .eligible => |candidate| candidate,
        .blocked => return error.ExpectedCoalescingEligibility,
    };
    const printable = terminal.KeyEvent{ .key = .Char, .char = 'x' };

    try std.testing.expectEqual(
        MovementCoalesceStopReason.different_key,
        ed.coalescingStopReasonForNext(candidate, printable, 1).?,
    );
}

test "movement coalescing rejects prompt and overlay modes" {
    var ed = try makeFastMoveTestEditor(std.testing.allocator);
    defer ed.deinit();

    const rejected_modes = [_]EditorMode{
        .Dashboard,
        .Command,
        .OpenFilePrompt,
        .FilesystemPicker,
        .Prompt,
        .Search,
        .GlobalSearch,
        .Terminal,
    };

    for (rejected_modes) |mode| {
        ed.state.mode = mode;
        switch (ed.movementCoalescingEligibilityBefore(ed.keys.move_down)) {
            .eligible => return error.ExpectedCoalescingRejection,
            .blocked => {},
        }
    }
}

test "movement coalescing rejects completion and focused explorer" {
    var ed = try makeFastMoveTestEditor(std.testing.allocator);
    defer ed.deinit();

    ed.state.lsp_ui.completion_active = true;
    try std.testing.expectEqual(
        MovementCoalesceStopReason.overlay_active,
        switch (ed.movementCoalescingEligibilityBefore(ed.keys.move_down)) {
            .eligible => return error.ExpectedCoalescingRejection,
            .blocked => |reason| reason,
        },
    );

    ed.state.lsp_ui.completion_active = false;
    ed.state.explorer_visible = true;
    ed.state.explorer_focused = true;
    try std.testing.expectEqual(
        MovementCoalesceStopReason.overlay_active,
        switch (ed.movementCoalescingEligibilityBefore(ed.keys.move_down)) {
            .eligible => return error.ExpectedCoalescingRejection,
            .blocked => |reason| reason,
        },
    );
}

test "movement coalescing stops at max batch count" {
    var ed = try makeFastMoveTestEditor(std.testing.allocator);
    defer ed.deinit();

    const candidate = switch (ed.movementCoalescingEligibilityBefore(ed.keys.move_down)) {
        .eligible => |candidate| candidate,
        .blocked => return error.ExpectedCoalescingEligibility,
    };

    try std.testing.expectEqual(
        MovementCoalesceStopReason.max_batch,
        ed.coalescingStopReasonForNext(candidate, ed.keys.move_down, max_movement_coalesce_batch_count).?,
    );
}

test "movement coalescing rejects ambiguous non-simple movement binding" {
    var ed = try makeFastMoveTestEditor(std.testing.allocator);
    defer ed.deinit();

    ed.config.keybindings.line_start = "down";
    ed.refreshKeybindings();

    switch (ed.movementCoalescingEligibilityBefore(ed.keys.move_down)) {
        .eligible => return error.ExpectedCoalescingRejection,
        .blocked => {},
    }
}

test "pending key is processed before reading terminal input" {
    var ed = try makeFastMoveTestEditor(std.testing.allocator);
    defer ed.deinit();

    ed.pending_key = ed.keys.move_up;
    var reader = std.Io.Reader.fixed("\x1b[B");
    var metrics = perf.FrameMetrics{};

    const first = try ed.readInputKey(&reader, &metrics);
    try std.testing.expect(first.from_pending);
    try std.testing.expect(first.event.eql(ed.keys.move_up));
    try std.testing.expect(ed.pending_key == null);

    const second = try ed.readInputKey(&reader, &metrics);
    try std.testing.expect(!second.from_pending);
    try std.testing.expect(second.event.eql(ed.keys.move_down));
}

test "normal-mode hjkl movement can coalesce only when bound to movement" {
    var ed = try makeFastMoveTestEditor(std.testing.allocator);
    defer ed.deinit();

    const j = terminal.KeyEvent{ .key = .Char, .char = 'j' };
    switch (ed.movementCoalescingEligibilityBefore(j)) {
        .eligible => return error.ExpectedCoalescingRejection,
        .blocked => {},
    }

    ed.config.keybindings.move_down = "j";
    ed.refreshKeybindings();
    switch (ed.movementCoalescingEligibilityBefore(j)) {
        .eligible => |candidate| try std.testing.expectEqual(CoalescedMovement.down, candidate.movement),
        .blocked => return error.ExpectedCoalescingEligibility,
    }

    ed.state.mode = .Insert;
    switch (ed.movementCoalescingEligibilityBefore(j)) {
        .eligible => return error.ExpectedCoalescingRejection,
        .blocked => {},
    }
}

test "LSP helper rejects malformed diagnostics and completions" {
    var malformed_diag = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"uri\":\"file:///tmp/main.zig\"}", .{});
    defer malformed_diag.deinit();
    try std.testing.expect(Editor.diagnosticUri(malformed_diag.value) == null);

    try std.testing.expect(!Editor.isValidCompletionValue(.null));

    var malformed_completion = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"items\":null}", .{});
    defer malformed_completion.deinit();
    try std.testing.expect(!Editor.isValidCompletionValue(malformed_completion.value));
}

test "completion trigger is limited to buffer editing modes" {
    var ed = try makeFastMoveTestEditor(std.testing.allocator);
    defer ed.deinit();

    const allowed = [_]EditorMode{ .Normal, .Insert };
    for (allowed) |mode| {
        ed.state.mode = mode;
        try std.testing.expect(ed.modeAllowsCompletion());
    }

    const rejected = [_]EditorMode{ .Dashboard, .Command, .OpenFilePrompt, .FilesystemPicker, .Prompt, .Search, .GlobalSearch, .Terminal };
    for (rejected) |mode| {
        ed.state.mode = mode;
        try std.testing.expect(!ed.modeAllowsCompletion());
    }
}

fn makeFastMoveTestEditor(allocator: std.mem.Allocator) !Editor {
    return makeFastMoveTestEditorWithLineCount(allocator, 4);
}

fn makeFastMoveTestEditorWithLineCount(allocator: std.mem.Allocator, line_count: usize) !Editor {
    var ed = try Editor.init(allocator, std.testing.io, .{});
    errdefer ed.deinit();

    var buf = try buffer.Buffer.init(allocator);
    errdefer buf.deinit();
    var first = buf.lines.orderedRemove(0);
    first.deinit();

    const seed_lines = [_][]const u8{ "alpha", "beta", "gamma", "delta" };
    for (0..line_count) |i| {
        const line = if (i < seed_lines.len) seed_lines[i] else "filler";
        try buf.lines.append(allocator, try buffer.Line.fromSlice(allocator, line));
    }

    try ed.addTab(buf);
    ed.state.mode = .Normal;
    ed.width = 80;
    ed.height = 24;
    ed.state.render_dirty = false;
    ed.state.force_full_render = false;
    return ed;
}

pub fn start_editor(io: std.Io, allocator: std.mem.Allocator, cfg: config.Config) !void {
    var editor = try Editor.init(allocator, io, cfg);
    defer editor.deinit();
    try editor.run();
}
