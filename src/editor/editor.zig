const std = @import("std");
const logz = @import("logz");
const config = @import("../config.zig");
const terminal = @import("../terminal.zig");
const buffer = @import("model/buffer.zig");
const input = @import("input_router/router.zig");
const search = @import("search.zig");
const global_search = @import("global_search.zig");
const commands = @import("commands.zig");
const command_keybindings = @import("keybindings.zig");
const normal_sequence = @import("input_router/normal_sequence.zig");
const viewport_mod = @import("navigation/viewport.zig");
const syntax = @import("syntax.zig");
const perf = @import("../perf/perf.zig");
const completion_menu = @import("renderer/completion_menu.zig");
const line_render = @import("renderer/line_render.zig");
const render_mod = @import("renderer/virtual_screen.zig");
const picker_help_popups = @import("renderer/picker_help_popups.zig");
const popup = @import("renderer/popup.zig");
const prompt_save_popups = @import("renderer/prompt_save_popups.zig");
const search_popups = @import("renderer/search_popups.zig");
const statusline = @import("renderer/statusline.zig");
const tabbar = @import("renderer/tabbar.zig");
const terminal_panel_view = @import("renderer/terminal_panel_view.zig");
const lsp_manager = @import("../lsp/manager.zig");
const logger = @import("../logger.zig");
const tab_mod = @import("model/tab.zig");
const state_mod = @import("state/state.zig");
const jump_history = @import("state/jump_history.zig");
const runtime_mod = @import("runtime/runtime.zig");
const renderer_mod = @import("renderer/renderer.zig");
const filesystem_picker = @import("filesystem_picker.zig");
const prompt_popup = @import("prompt_popup.zig");
const terminal_panel_mod = @import("terminal_panel.zig");

const max_fifo_events_per_idle_tick = 8;
const syntax_parse_idle_delay_ns = 50 * std.time.ns_per_ms;

pub const EditorMode = state_mod.EditorMode;
pub const Pos = tab_mod.Pos;
pub const Cursor = tab_mod.Cursor;
pub const Tab = tab_mod.Tab;
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

pub const HorizontalScrollCommand = viewport_mod.HorizontalScrollCommand;

const TabBarLayout = tabbar.TabBarLayout;
const TabLabel = tabbar.TabLabel;
const RightStatusLayout = statusline.RightStatusLayout;

const RenderContext = struct {
    tab: ?*Tab,
    buf_start_col: usize,
    buf_width: usize,
    gutter_width: usize,
    visible_rows: usize,
};

const CommandPopupGeometry = popup.CommandPopupGeometry;
const FilesystemPickerGeometry = popup.FilesystemPickerGeometry;

const GlobalSearchRenderRow = search_popups.GlobalSearchRenderRow;

const SelectionRange = line_render.SelectionRange;
const LineRenderState = line_render.LineRenderState;

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
    keybinding_registry: command_keybindings.Registry,
    allocator: std.mem.Allocator,
    io: std.Io,
    state: state_mod.EditorState,
    terminal_panel: terminal_panel_mod.TerminalPanel,
    runtime: runtime_mod.EditorRuntime,
    renderer: renderer_mod.EditorRenderer,
    keypress_profiler: perf.KeypressProfiler,
    active_keypress_trace: ?*perf.KeypressTrace = null,
    pending_key: ?terminal.KeyEvent = null,
    pending_definition_request_id: ?usize = null,
    pending_definition_plugin_name: ?[]const u8 = null,
    pending_definition_source: ?jump_history.JumpLocation = null,
    last_input_movement_handled: bool = false,
    width: usize = 0,
    height: usize = 0,
    should_quit: bool = false,
    is_deinitialized: bool = false,
    last_status_minute: i64 = -1,
    status_cache: statusline.StatusLayoutCache = .{},

    pub fn init(allocator: std.mem.Allocator, io: std.Io, cfg: config.Config) !Editor {
        return initWithRuntimeOptions(allocator, io, cfg, .{});
    }

    pub fn initWithRuntimeOptions(allocator: std.mem.Allocator, io: std.Io, cfg: config.Config, runtime_options: runtime_mod.EditorRuntime.Options) !Editor {
        var runtime = try runtime_mod.EditorRuntime.initWithOptions(allocator, io, runtime_options);
        errdefer runtime.deinit(allocator);
        var keybinding_diagnostics = command_keybindings.BuildDiagnostics{};
        defer keybinding_diagnostics.deinit(allocator);
        var keybinding_registry = try config.buildKeybindingRegistry(allocator, &cfg, &keybinding_diagnostics);
        errdefer keybinding_registry.deinit(allocator);

        return Editor{
            .allocator = allocator,
            .io = io,
            .config = cfg,
            .keybinding_registry = keybinding_registry,
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
        self.keybinding_registry.deinit(self.allocator);
        self.runtime.deinit(self.allocator);
        self.state.deinit(self.allocator);
        self.renderer.deinit(self.allocator);
        self.keypress_profiler.deinit();
    }

    pub fn currentTab(self: *Editor) ?*Tab {
        return self.state.currentTab();
    }

    pub fn refreshKeybindings(self: *Editor) void {
        var diagnostics = command_keybindings.BuildDiagnostics{};
        defer diagnostics.deinit(self.allocator);
        const rebuilt = config.buildKeybindingRegistry(self.allocator, &self.config, &diagnostics) catch return;
        self.keybinding_registry.deinit(self.allocator);
        self.keybinding_registry = rebuilt;
    }

    pub fn keyEventForCommand(self: *const Editor, context: commands.CommandContext, id: commands.CommandId) ?terminal.KeyEvent {
        for (self.keybinding_registry.bindings) |binding| {
            if (binding.context == context and binding.command == id and binding.sequence.len == 1) {
                return binding.sequence.chords[0].toEvent();
            }
        }
        return null;
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

    pub fn requestDefinitionAtCursor(self: *Editor) !void {
        const tab = self.currentTab() orelse {
            self.state.error_message = "No active file for definition lookup";
            self.pending_definition_request_id = null;
            self.pending_definition_plugin_name = null;
            self.pending_definition_source = null;
            return;
        };
        const filename = tab.buf.filename orelse {
            self.state.error_message = "No active file for definition lookup";
            self.pending_definition_request_id = null;
            self.pending_definition_plugin_name = null;
            self.pending_definition_source = null;
            return;
        };
        const mc = tab.mainCursor();
        const source = jump_history.JumpLocation{
            .buffer_id = tab.syntax_buffer_id,
            .row = mc.row,
            .col = mc.col,
        };

        if (self.runtime.lsp_mgr) |*mgr| {
            self.flushPendingLspChanges(true) catch |err| {
                logz.err().fmt("msg", "Failed to flush LSP changes before definition request: {any}", .{err}).log();
            };

            const result = mgr.requestDefinition(filename, mc.row, mc.col) catch |err| {
                logz.err().fmt("msg", "Failed to request definition: {any}", .{err}).log();
                self.state.error_message = "LSP definition unavailable";
                self.pending_definition_request_id = null;
                self.pending_definition_source = null;
                return;
            };

            switch (result) {
                .requested => |requested| {
                    self.pending_definition_request_id = requested.request_id;
                    self.pending_definition_plugin_name = requested.plugin_name;
                    self.pending_definition_source = source;
                },
                .no_plugin, .no_client, .not_ready => {
                    self.state.error_message = "LSP definition unavailable";
                    self.pending_definition_request_id = null;
                    self.pending_definition_plugin_name = null;
                    self.pending_definition_source = null;
                },
            }
        } else {
            self.state.error_message = "LSP definition unavailable";
            self.pending_definition_request_id = null;
            self.pending_definition_plugin_name = null;
            self.pending_definition_source = null;
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

    pub fn processQuitAll(self: *Editor) void {
        // Iterate over tabs to find the first dirty one
        for (self.state.tabs.items, 0..) |*tab, i| {
            if (tab.buf.is_dirty) {
                self.state.active_tab_index = i;
                self.state.save_confirmation.open(tab.buf.filename);
                self.state.mode = .SaveConfirmation;
                self.markDirty(.full);
                return;
            }
        }

        // No dirty tabs found, close all remaining tabs and go to dashboard
        self.closeAllTabs();
        self.state.quitting_all = false;
    }

    pub fn processWriteAll(self: *Editor) void {
        var error_occurred = false;
        for (self.state.tabs.items) |*tab| {
            if (tab.buf.is_dirty) {
                if (tab.buf.filename) |f| {
                    tab.buf.saveToFile(self.io, f) catch {
                        error_occurred = true;
                    };
                } else {
                    error_occurred = true;
                }
            }
        }
        if (error_occurred) {
            self.state.error_message = "Failed to save some files";
        }
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
        try self.renderVirtual(writer, &metrics);
    }

    pub fn renderBenchmarkCursorMove(self: *Editor, writer: anytype, event: terminal.KeyEvent) !bool {
        try self.handleRuntimeKey(event);
        var metrics = perf.FrameMetrics{};
        try self.renderVirtual(writer, &metrics);
        self.state.render_dirty = false;
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

                if (key_trace) |trace| {
                    trace.reject = "none";
                }

                const previous_render_trace = self.active_keypress_trace;
                self.active_keypress_trace = key_trace;
                defer self.active_keypress_trace = previous_render_trace;

                const frame_start = perf.nowNs();
                if (key_trace) |trace| {
                    trace.render = .virtual;
                    trace.render_path_reason = "virtual";
                }
                try self.renderVirtual(writer, &metrics);
                const render_elapsed = perf.elapsedNs(frame_start);
                metrics.add(.build_frame, render_elapsed);
                if (key_trace) |trace| {
                    trace.render_ns += render_elapsed;
                }
                metrics.render_kind = if (self.state.force_full_render) .full else .partial;

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
                    trace.total_ns = perf.elapsedNs(key_start_ns);
                }
                self.state.render_dirty = false;
                self.state.force_full_render = false;
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

        const context: commands.CommandContext = if (self.state.mode == .Insert) .insert else .normal;
        const command = self.resolveDefaultContextCommand(context, event) orelse return null;
        return switch (command) {
            .navigation_move_up => .up,
            .navigation_move_down => .down,
            .navigation_move_left => .left,
            .navigation_move_right => .right,
            else => null,
        };
    }

    fn matchesNonSimpleMovement(self: *Editor, event: terminal.KeyEvent) bool {
        const context: commands.CommandContext = if (self.state.mode == .Insert) .insert else .normal;
        const command = self.resolveDefaultContextCommand(context, event) orelse return false;
        return switch (command) {
            .navigation_line_start,
            .navigation_line_end,
            .navigation_word_left,
            .navigation_word_right,
            => true,
            else => false,
        };
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
                .definition => |definition| {
                    defer mgr.freeValue(definition.result);
                    try self.handleDefinitionResult(plugin_name, definition.request_id, definition.result);
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

    fn handleDefinitionResult(self: *Editor, plugin_name: []const u8, request_id: usize, result: std.json.Value) !void {
        const pending_id = self.pending_definition_request_id orelse return;
        const pending_plugin_name = self.pending_definition_plugin_name orelse return;
        if (pending_id != request_id) return;
        if (!std.mem.eql(u8, pending_plugin_name, plugin_name)) return;

        const source = self.pending_definition_source;
        self.pending_definition_request_id = null;
        self.pending_definition_plugin_name = null;
        self.pending_definition_source = null;

        const location = lsp_manager.firstDefinitionLocation(result) orelse {
            self.state.error_message = "No definition found";
            self.markDirty(.partial);
            return;
        };

        const path = lsp_manager.fileUriToPathAlloc(self.allocator, location.uri) catch |err| {
            logz.err().fmt("msg", "failed to convert definition URI {s}: {any}", .{ location.uri, err }).log();
            self.state.error_message = "Could not open definition target";
            self.markDirty(.partial);
            return;
        };
        defer self.allocator.free(path);

        _ = self.jumpToFileLocation(path, location.row, location.col, source) catch |err| {
            logz.err().fmt("msg", "failed to jump to definition target {s}: {any}", .{ path, err }).log();
            self.state.error_message = "Could not open definition target";
            self.markDirty(.partial);
            return;
        };
        self.state.error_message = null;
        self.markDirty(.full);
    }

    fn jumpToFileLocation(
        self: *Editor,
        path: []const u8,
        row: usize,
        col: usize,
        source: ?jump_history.JumpLocation,
    ) !bool {
        if (self.findOpenTabIndexByPath(path)) |idx| {
            self.state.active_tab_index = idx;
        } else {
            var loaded = try buffer.Buffer.loadFromFile(self.allocator, self.io, path);
            var consumed = false;
            errdefer if (!consumed) loaded.deinit();
            try self.addTab(loaded);
            consumed = true;
        }

        const tab = self.currentTab() orelse return false;
        const target = self.clampedLocationForTab(tab, row, col);
        if (source) |from| {
            if (!from.eql(target)) try self.state.jump_history.recordJump(self.allocator, from);
        }

        const mc = tab.mainCursor();
        const changed = mc.row != target.row or mc.col != target.col;
        mc.row = target.row;
        mc.col = target.col;
        mc.preferred_col = null;
        self.clampScroll();
        return changed;
    }

    fn findOpenTabIndexByPath(self: *Editor, path: []const u8) ?usize {
        for (self.state.tabs.items, 0..) |*tab, i| {
            if (tab.buf.filename) |filename| {
                if (std.mem.eql(u8, filename, path)) return i;
            }
        }

        const target_real = self.realPathOrNull(path) orelse return null;
        defer self.allocator.free(target_real);

        for (self.state.tabs.items, 0..) |*tab, i| {
            const filename = tab.buf.filename orelse continue;
            const filename_real = self.realPathOrNull(filename) orelse continue;
            defer self.allocator.free(filename_real);
            if (std.mem.eql(u8, filename_real, target_real)) return i;
        }
        return null;
    }

    fn realPathOrNull(self: *Editor, path: []const u8) ?[]u8 {
        const z = std.Io.Dir.cwd().realPathFileAlloc(self.io, path, self.allocator) catch return null;
        defer self.allocator.free(z);
        return self.allocator.dupe(u8, z) catch null;
    }

    fn clampedLocationForTab(self: *Editor, tab: *const Tab, row: usize, col: usize) jump_history.JumpLocation {
        var clamped_row = row;
        var clamped_col = col;
        if (tab.buf.lines.items.len == 0) {
            clamped_row = 0;
            clamped_col = 0;
        } else {
            clamped_row = @min(clamped_row, tab.buf.lines.items.len - 1);
            clamped_row = tab.buf.clampToVisibleLine(clamped_row);
            clamped_col = @min(clamped_col, tab.buf.lines.items[clamped_row].len());
        }
        _ = self;
        return .{
            .buffer_id = tab.syntax_buffer_id,
            .row = clamped_row,
            .col = clamped_col,
        };
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

        var without_shift = event;
        without_shift.shift = false;
        const context: commands.CommandContext = if (self.state.explorer_focused and self.state.explorer_visible and self.state.tree != null)
            if (self.state.tree.?.search_active) .explorer_search else .explorer
        else if (self.state.mode == .Insert)
            .insert
        else
            .normal;

        const command = self.resolveDefaultContextCommand(context, without_shift) orelse return false;
        return switch (command) {
            .navigation_move_up,
            .navigation_move_down,
            .navigation_move_left,
            .navigation_move_right,
            .navigation_line_start,
            .navigation_line_end,
            .navigation_word_left,
            .navigation_word_right,
            .explorer_move_up,
            .explorer_move_down,
            => true,
            else => false,
        };
    }

    fn bufferViewportGeometry(self: *const Editor) viewport_mod.BufferViewportGeometry {
        return viewport_mod.bufferViewportGeometry(self);
    }

    pub fn terminalPanelHeight(self: *const Editor) usize {
        return viewport_mod.terminalPanelHeight(self);
    }

    fn statusRowIndex(self: *const Editor) usize {
        return viewport_mod.statusRowIndex(self);
    }

    fn statusTerminalRow(self: *const Editor) usize {
        return viewport_mod.statusTerminalRow(self);
    }

    pub fn editorVisibleRows(self: *const Editor) usize {
        return viewport_mod.editorVisibleRows(self);
    }

    fn terminalCursorScreenPosition(self: *Editor) terminal_panel_view.TerminalCursorScreenPosition {
        return terminal_panel_view.terminalCursorScreenPosition(self);
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
        return statusline.buildStatusText(self, tab, buf);
    }

    fn statusModeLabel(self: *const Editor) []const u8 {
        return statusline.statusModeLabel(self);
    }

    fn statusModeStyle(self: *const Editor) render_mod.RenderStyle {
        return statusline.statusModeStyle(self);
    }

    fn statusModeSepStyle(self: *const Editor) render_mod.RenderStyle {
        return statusline.statusModeSepStyle(self);
    }

    fn fileIconForName(name: []const u8) []const u8 {
        return statusline.fileIconForName(name);
    }

    fn statusFilePath(self: *const Editor, tab: ?*Tab) []const u8 {
        return statusline.statusFilePath(self, tab);
    }

    fn statusContext(self: *const Editor) ?[]const u8 {
        return statusline.statusContext(self);
    }

    fn currentMinute(self: *const Editor) i64 {
        return statusline.currentMinute(self);
    }

    fn clockText(self: *const Editor, buf: *[16]u8) []const u8 {
        return statusline.clockText(self, buf);
    }

    fn cacheRightStatusLayout(self: *Editor, right: RightStatusLayout, text_start_terminal_col: usize, text_available: usize) void {
        statusline.cacheRightStatusLayout(self, right, text_start_terminal_col, text_available);
    }

    fn buildRightStatus(self: *Editor, tab: ?*Tab, buf: *[192]u8) ![]const u8 {
        return statusline.buildRightStatus(self, tab, buf);
    }

    fn buildRightStatusLayout(self: *Editor, tab: ?*Tab, buf: *[192]u8) !RightStatusLayout {
        return statusline.buildRightStatusLayout(self, tab, buf);
    }

    fn appendStatusText(buf: *[192]u8, idx: *usize, cells: *usize, text: []const u8) !void {
        return statusline.appendStatusText(buf, idx, cells, text);
    }

    fn appendStatusFmt(buf: *[192]u8, idx: *usize, cells: *usize, comptime fmt: []const u8, args: anytype) !void {
        return statusline.appendStatusFmt(buf, idx, cells, fmt, args);
    }

    fn appendStatusFieldFmt(buf: *[192]u8, idx: *usize, cells: *usize, width: usize, comptime fmt: []const u8, args: anytype) !void {
        return statusline.appendStatusFieldFmt(buf, idx, cells, width, fmt, args);
    }

    fn statusScrollPercent(row: usize, total_lines: usize) usize {
        return statusline.statusScrollPercent(row, total_lines);
    }

    fn resolveDefaultContextCommand(self: *const Editor, context: commands.CommandContext, event: terminal.KeyEvent) ?commands.CommandId {
        const result = self.keybinding_registry.resolve(context, command_keybindings.KeySequence.fromEvent(event));
        return switch (result) {
            .command => |command| command,
            else => null,
        };
    }

    fn registryCommandMatches(self: *const Editor, context: commands.CommandContext, event: terminal.KeyEvent, id: commands.CommandId) bool {
        return (self.resolveDefaultContextCommand(context, event) orelse return false) == id;
    }

    fn quitRequestedByEvent(self: *const Editor, event: terminal.KeyEvent) bool {
        if (self.registryCommandMatches(.global, event, .app_quit_flamingo)) return true;
        if (self.state.mode == .Normal) {
            const command = normal_sequence.resolveGlobalActionCommand(&self.keybinding_registry, event) orelse return false;
            return command == .app_quit_flamingo;
        }
        return false;
    }

    fn completionCommandForEvent(self: *const Editor, event: terminal.KeyEvent) ?commands.CommandId {
        const context: commands.CommandContext = switch (self.state.mode) {
            .Normal => .normal,
            .Insert => .insert,
            else => return null,
        };

        const command = self.resolveDefaultContextCommand(context, event) orelse return null;
        return switch (command) {
            .completion_auto_trigger,
            .completion_trigger,
            => command,
            else => null,
        };
    }

    fn completionActionCommandForEvent(self: *const Editor, event: terminal.KeyEvent) ?commands.CommandId {
        const command = self.resolveDefaultContextCommand(.completion, event) orelse return null;
        return switch (command) {
            .completion_previous,
            .completion_next,
            .completion_accept,
            .completion_cancel,
            => command,
            else => null,
        };
    }

    fn handleRuntimeKey(self: *Editor, event: terminal.KeyEvent) !void {
        if (self.state.mode != .Help and self.quitRequestedByEvent(event)) {
            self.should_quit = true;
            self.markDirty(.full);
            return;
        }

        if (self.state.mode != .Help and self.state.lsp_ui.completion_active) {
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

            if (self.completionCommandForEvent(event) != null and self.modeAllowsCompletion()) {
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
        return line_render.buildLineRenderState(self, tab, buffer_line_idx, content_width, selection_storage);
    }

    fn buildSelectionRanges(tab: *const Tab, row: usize, storage: *[64]SelectionRange) []const SelectionRange {
        return line_render.buildSelectionRanges(tab, row, storage);
    }

    fn selectionRangeForRow(cursor: Cursor, row: usize) ?SelectionRange {
        return line_render.selectionRangeForRow(cursor, row);
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
        return viewport_mod.textViewportWidthForTab(self, tab);
    }

    fn horizontalScrollForCursor(cursor_col: usize, scroll_col: usize, visible_width: usize) usize {
        return viewport_mod.horizontalScrollForCursor(cursor_col, scroll_col, visible_width);
    }

    fn visibleCursorCol(cursor_col: usize, scroll_col: usize, visible_width: usize) usize {
        return viewport_mod.visibleCursorCol(cursor_col, scroll_col, visible_width);
    }

    fn maxVisibleLineLen(tab: *const Tab, visible_rows: usize) usize {
        return viewport_mod.maxVisibleLineLen(tab, visible_rows);
    }

    fn visibleLineOffset(tab: *const Tab, start_line: usize, target_line: usize, max_rows: usize) ?usize {
        return viewport_mod.visibleLineOffset(tab, start_line, target_line, max_rows);
    }

    fn visibleViewportEndLine(tab: *const Tab, start_line: usize, row_count: usize) usize {
        return viewport_mod.visibleViewportEndLine(tab, start_line, row_count);
    }

    fn clampHorizontalScrollToVisibleLines(self: *Editor, tab: *Tab, visible_width: usize) void {
        viewport_mod.clampHorizontalScrollToVisibleLines(self, tab, visible_width);
    }

    pub fn applyHorizontalScrollCommand(self: *Editor, command: HorizontalScrollCommand) void {
        viewport_mod.applyHorizontalScrollCommand(self, command);
    }

    /// Adjust scroll state so the main cursor is always within the visible viewport_mod.
    pub fn clampScroll(self: *Editor) void {
        viewport_mod.clampScroll(self);
    }

    fn getTabLabel(tabs: []const Tab, tab: *const Tab) TabLabel {
        return tabbar.getTabLabel(tabs, tab);
    }

    fn tabLabelWidth(tabs: []const Tab, tab: *const Tab) usize {
        return tabbar.tabLabelWidth(tabs, tab);
    }

    fn totalTabBarWidth(tabs: []const Tab) usize {
        return tabbar.totalTabBarWidth(tabs);
    }

    fn tabStartCol(tabs: []const Tab, index: usize) usize {
        return tabbar.tabStartCol(tabs, index);
    }

    fn clampTabBarScroll(scroll_col: *usize, total_width: usize, available_width: usize) void {
        tabbar.clampTabBarScroll(scroll_col, total_width, available_width);
    }

    fn ensureActiveTabVisible(tabs: []const Tab, active_index: usize, available_width: usize, scroll_col: *usize) void {
        tabbar.ensureActiveTabVisible(tabs, active_index, available_width, scroll_col);
    }

    fn prepareTabBarLayout(self: *Editor, width: usize) TabBarLayout {
        return tabbar.prepareTabBarLayout(self.state.tabs.items, self.state.active_tab_index, width, &self.state.tab_bar_scroll_col);
    }

    fn writeVirtualClippedText(self: *Editor, row: usize, dest_base_col: usize, text_start_col: usize, viewport_start: usize, viewport_end: usize, text: []const u8, style: render_mod.RenderStyle) void {
        tabbar.writeVirtualClippedText(&self.renderer.screen, row, dest_base_col, text_start_col, viewport_start, viewport_end, text, style);
    }

    fn writeVirtualClippedTabLabel(self: *Editor, row: usize, dest_base_col: usize, label_start_col: usize, viewport_start: usize, viewport_end: usize, tab: *const Tab, active: bool) void {
        tabbar.writeVirtualClippedTabLabel(&self.renderer.screen, self.state.tabs.items, row, dest_base_col, label_start_col, viewport_start, viewport_end, tab, active);
    }

    fn popupGeometry(self: *const Editor, visible: bool, item_count: usize, show_items: bool, max_visible_items: usize) ?CommandPopupGeometry {
        const viewport = self.bufferViewportGeometry();
        return popup.popupGeometry(
            self.height,
            viewport.start_col,
            viewport.width,
            visible,
            item_count,
            show_items,
            max_visible_items,
        );
    }

    fn commandPopupGeometry(self: *const Editor) ?CommandPopupGeometry {
        return search_popups.commandPopupGeometry(self);
    }

    fn globalSearchPopupGeometry(self: *const Editor) ?CommandPopupGeometry {
        return search_popups.globalSearchPopupGeometry(self);
    }

    fn isSameContentDisplayPath(a: global_search.GlobalSearchResult, b: global_search.GlobalSearchResult) bool {
        return search_popups.isSameContentDisplayPath(a, b);
    }

    fn globalSearchRenderRowCount(results: []const global_search.GlobalSearchResult) usize {
        return search_popups.globalSearchRenderRowCount(results);
    }

    fn globalSearchRenderRowAt(results: []const global_search.GlobalSearchResult, render_row: usize) ?GlobalSearchRenderRow {
        return search_popups.globalSearchRenderRowAt(results, render_row);
    }

    fn selectedGlobalSearchRenderRow(results: []const global_search.GlobalSearchResult, selected_index: ?usize) ?usize {
        return search_popups.selectedGlobalSearchRenderRow(results, selected_index);
    }

    fn adjustGlobalSearchRenderScroll(self: *Editor, view_height: usize) void {
        search_popups.adjustGlobalSearchRenderScroll(self, view_height);
    }

    fn pickerTitle(mode: filesystem_picker.PickerMode, phase: filesystem_picker.PickerPhase) []const u8 {
        return picker_help_popups.pickerTitle(mode, phase);
    }

    fn pickerFooter(mode: filesystem_picker.PickerMode, phase: filesystem_picker.PickerPhase) []const u8 {
        return picker_help_popups.pickerFooter(mode, phase);
    }

    fn pickerPrompt(mode: filesystem_picker.PickerMode, phase: filesystem_picker.PickerPhase) []const u8 {
        return picker_help_popups.pickerPrompt(mode, phase);
    }

    fn pickerFooterCompact(width: usize) bool {
        return picker_help_popups.pickerFooterCompact(width);
    }

    fn pickerFooterLineOne(mode: filesystem_picker.PickerMode, phase: filesystem_picker.PickerPhase, compact: bool) []const u8 {
        return picker_help_popups.pickerFooterLineOne(mode, phase, compact);
    }

    fn pickerFooterLineTwo(mode: filesystem_picker.PickerMode, phase: filesystem_picker.PickerPhase, compact: bool) ?[]const u8 {
        return picker_help_popups.pickerFooterLineTwo(mode, phase, compact);
    }

    fn pickerFooterLineCount(mode: filesystem_picker.PickerMode, phase: filesystem_picker.PickerPhase, width: usize) usize {
        return picker_help_popups.pickerFooterLineCount(mode, phase, width);
    }

    fn filesystemPickerGeometry(self: *const Editor, mode: filesystem_picker.PickerMode, phase: filesystem_picker.PickerPhase, has_error: bool) ?FilesystemPickerGeometry {
        return picker_help_popups.filesystemPickerGeometry(self, mode, phase, has_error);
    }

    fn helpPopupGeometry(self: *const Editor) ?FilesystemPickerGeometry {
        return picker_help_popups.helpPopupGeometry(self);
    }

    pub fn helpPopupBodyRows(self: *const Editor) usize {
        return picker_help_popups.helpPopupBodyRows(self);
    }

    fn promptFooter(kind: prompt_popup.PromptKind) []const u8 {
        return prompt_save_popups.promptFooter(kind);
    }

    fn terminalCellStyle(cell: terminal_panel_mod.TerminalCell) render_mod.RenderStyle {
        return terminal_panel_view.terminalCellStyle(cell);
    }

    /// Calculates total gutter width: 1 space + num_digits + 1 space separator.
    pub fn calculateGutterWidth(self: *const Editor, total_lines: usize) usize {
        _ = self;
        return renderer_mod.calculateGutterWidth(total_lines);
    }

    fn renderVirtual(self: *Editor, writer: anytype, metrics: *perf.FrameMetrics) !void {
        if (try self.renderer.screen.resize(self.width, self.height)) {
            self.renderer.screen_renderer.invalidate(.full);
        }
        self.renderer.screen.clear();

        var status_buf: [160]u8 = undefined;
        const ctx = self.buildRenderContext(&status_buf);

        if (self.state.mode == .Dashboard or self.state.mode == .OpenFilePrompt or self.state.mode == .FilesystemPicker or
            (self.state.mode == .Help and self.state.tabs.items.len == 0))
        {
            self.state.dash.renderToScreen(&self.renderer.screen);
        } else {
            self.renderVirtualExplorer();

            const tabs_start = if (self.active_keypress_trace != null) perf.nowNs() else 0;
            self.renderVirtualTabs(ctx);
            if (self.active_keypress_trace) |trace| trace.tabs_ns += perf.elapsedNs(tabs_start);

            if (ctx.tab) |t| {
                t.scroll_row = t.buf.clampToVisibleLine(t.scroll_row);
                const highlight_start = perf.nowNs();
                const syntax_end = visibleViewportEndLine(t, t.scroll_row, ctx.visible_rows + 20);
                self.prepareSyntaxForViewport(t, t.scroll_row, syntax_end, 20) catch {
                    if (self.active_keypress_trace) |trace| trace.syntax_cache = syntax.ViewportCacheStatus.unknown.name();
                };
                const highlight_elapsed = perf.elapsedNs(highlight_start);
                metrics.add(.highlight_viewport, highlight_elapsed);
                if (self.active_keypress_trace) |trace| trace.highlight_ns += highlight_elapsed;

                const visible_lines_start = if (self.active_keypress_trace != null) perf.nowNs() else 0;
                var buffer_line_idx = t.scroll_row;
                for (0..ctx.visible_rows) |screen_row| {
                    const row = screen_row + 2;
                    if (buffer_line_idx >= t.buf.lines.items.len) break;
                    self.renderVirtualLine(t, buffer_line_idx, row, ctx);
                    const next = t.buf.nextVisibleLine(buffer_line_idx);
                    if (next == buffer_line_idx) break;
                    buffer_line_idx = next;
                }
                if (self.active_keypress_trace) |trace| trace.visible_lines_ns += perf.elapsedNs(visible_lines_start);
            }
        }

        const popup_start = if (self.active_keypress_trace != null) perf.nowNs() else 0;
        self.renderVirtualCommandPopup();
        self.renderVirtualGlobalSearchPopup();
        self.renderVirtualFilesystemPickerPopup();
        self.renderVirtualPromptPopup();
        self.renderVirtualSaveConfirmationPopup();
        self.renderVirtualHelpPopup();
        self.renderVirtualCompletionMenu();
        if (self.active_keypress_trace) |trace| trace.popup_ns += perf.elapsedNs(popup_start);
        const status_start = if (self.active_keypress_trace != null) perf.nowNs() else 0;
        self.renderVirtualStatus(ctx);
        if (self.active_keypress_trace) |trace| trace.status_ns += perf.elapsedNs(status_start);
        self.renderVirtualTerminalPanel();
        self.setVirtualCursor(ctx);
        const emit_start = if (self.active_keypress_trace != null) perf.nowNs() else 0;
        const emit_bytes = try self.renderer.screen_renderer.emit(writer, &self.renderer.screen);
        if (self.active_keypress_trace) |trace| {
            trace.virtual_emit_ns += perf.elapsedNs(emit_start);
            trace.virtual_emit_bytes += emit_bytes;
        }
    }

    fn renderVirtualExplorer(self: *Editor) void {
        if (!self.state.explorer_visible or self.state.tree == null or self.width == 0 or self.height < 2) return;
        const exp_width = (self.width * @as(usize, self.config.explorer.width_percentage)) / 100;
        if (exp_width == 0) return;
        self.state.tree.?.renderAt(&self.renderer.screen, exp_width, self.height - 1, 1, 0, self.state.explorer_focused, if (self.state.git_snapshot) |*s| s else null);
        const divider_col = exp_width;
        if (divider_col < self.width) {
            for (1..self.height) |row| {
                self.renderer.screen.writeText(row, divider_col, "│", .dim);
            }
        }
    }

    fn renderVirtualTabs(self: *Editor, ctx: RenderContext) void {
        if (self.height == 0 or ctx.buf_width == 0) return;
        const start_col = ctx.buf_start_col -| 1;
        tabbar.renderVirtualTabs(&self.renderer.screen, self.state.tabs.items, self.state.active_tab_index, &self.state.tab_bar_scroll_col, ctx.buf_width, start_col);
    }

    fn renderVirtualCommandPopup(self: *Editor) void {
        search_popups.renderVirtualCommandPopup(self);
    }

    fn writeVirtualTruncated(self: *Editor, row: usize, col: *usize, end_col: usize, text: []const u8, style: render_mod.RenderStyle) void {
        popup.writeVirtualTruncated(&self.renderer.screen, row, col, end_col, text, style);
    }

    fn globalSearchFileStyle(selected: bool) render_mod.RenderStyle {
        return search_popups.globalSearchFileStyle(selected);
    }

    fn globalSearchResultStyle(selected: bool) render_mod.RenderStyle {
        return search_popups.globalSearchResultStyle(selected);
    }

    fn renderVirtualGlobalSearchRowText(self: *Editor, row: usize, start_col: usize, end_col: usize, render_row: GlobalSearchRenderRow, results: []const global_search.GlobalSearchResult, selected: bool) void {
        search_popups.renderVirtualGlobalSearchRowText(self, row, start_col, end_col, render_row, results, selected);
    }

    fn renderVirtualGlobalSearchPopup(self: *Editor) void {
        search_popups.renderVirtualGlobalSearchPopup(self);
    }

    fn renderVirtualFilesystemPickerPopup(self: *Editor) void {
        picker_help_popups.renderVirtualFilesystemPickerPopup(self);
    }

    fn helpFooter(width: usize) []const u8 {
        return picker_help_popups.helpFooter(width);
    }

    fn renderVirtualHelpPopup(self: *Editor) void {
        picker_help_popups.renderVirtualHelpPopup(self);
    }

    fn renderVirtualPromptPopup(self: *Editor) void {
        prompt_save_popups.renderVirtualPromptPopup(self);
    }

    fn renderVirtualSaveConfirmationPopup(self: *Editor) void {
        prompt_save_popups.renderVirtualSaveConfirmationPopup(self);
    }

    fn renderVirtualCompletionMenu(self: *Editor) void {
        completion_menu.renderVirtualCompletionMenu(self);
    }

    fn drawVirtualPopupTop(self: *Editor, geom: CommandPopupGeometry, title: []const u8, style: render_mod.RenderStyle) void {
        popup.drawVirtualPopupTop(&self.renderer.screen, geom, title, style);
    }

    fn drawVirtualPopupRow(self: *Editor, row: usize, col: usize, width: usize, border_style: render_mod.RenderStyle, fill_style: render_mod.RenderStyle) void {
        popup.drawVirtualPopupRow(&self.renderer.screen, row, col, width, border_style, fill_style);
    }

    fn drawVirtualPopupSeparator(self: *Editor, row: usize, col: usize, width: usize, style: render_mod.RenderStyle) void {
        popup.drawVirtualPopupSeparator(&self.renderer.screen, row, col, width, style);
    }

    fn drawVirtualPopupBottom(self: *Editor, row: usize, col: usize, width: usize, style: render_mod.RenderStyle) void {
        popup.drawVirtualPopupBottom(&self.renderer.screen, row, col, width, style);
    }

    fn drawPickerTop(self: *Editor, geom: FilesystemPickerGeometry, title: []const u8, style: render_mod.RenderStyle) void {
        popup.drawPickerTop(&self.renderer.screen, geom, title, style);
    }

    fn drawPickerSeparator(self: *Editor, row: usize, col: usize, width: usize, style: render_mod.RenderStyle) void {
        popup.drawPickerSeparator(&self.renderer.screen, row, col, width, style);
    }

    fn drawPickerRow(self: *Editor, row: usize, col: usize, width: usize, border_style: render_mod.RenderStyle, fill_style: render_mod.RenderStyle) void {
        popup.drawPickerRow(&self.renderer.screen, row, col, width, border_style, fill_style);
    }

    fn drawPickerBottom(self: *Editor, row: usize, col: usize, width: usize, style: render_mod.RenderStyle) void {
        popup.drawPickerBottom(&self.renderer.screen, row, col, width, style);
    }

    fn byteOffsetAfterCells(text: []const u8, cell_count: usize) usize {
        return popup.byteOffsetAfterCells(text, cell_count);
    }

    fn writeVirtualCellsLimited(self: *Editor, row: usize, col: *usize, end_col: usize, text: []const u8, max_cells: usize, style: render_mod.RenderStyle) usize {
        return popup.writeVirtualCellsLimited(&self.renderer.screen, row, col, end_col, text, max_cells, style);
    }

    fn writeVirtualTruncatedCells(self: *Editor, row: usize, col: *usize, end_col: usize, text: []const u8, style: render_mod.RenderStyle, truncate_left: bool) void {
        popup.writeVirtualTruncatedCells(&self.renderer.screen, row, col, end_col, text, style, truncate_left);
    }

    fn pickerEntryIcon(entry: filesystem_picker.PickerEntry) []const u8 {
        return picker_help_popups.pickerEntryIcon(entry);
    }

    fn pickerEntryStyle(entry: filesystem_picker.PickerEntry, selected: bool) render_mod.RenderStyle {
        return picker_help_popups.pickerEntryStyle(entry, selected);
    }

    fn renderVirtualTerminalPanel(self: *Editor) void {
        terminal_panel_view.renderVirtualTerminalPanel(self);
    }

    fn renderVirtualLine(self: *Editor, tab: *Tab, buffer_line_idx: usize, row: usize, ctx: RenderContext) void {
        line_render.renderVirtualLine(self, tab, buffer_line_idx, row, ctx);
    }

    fn renderVirtualStatus(self: *Editor, ctx: RenderContext) void {
        statusline.renderVirtualStatus(self, ctx, self.statusRowIndex());
    }

    fn writeVirtualStatusText(self: *Editor, row: usize, col: *usize, text: []const u8, style: render_mod.RenderStyle) void {
        statusline.writeVirtualStatusText(self, row, col, text, style);
    }

    fn writeVirtualStatusLeft(self: *Editor, row: usize, col: *usize, tab: ?*Tab) void {
        statusline.writeVirtualStatusLeft(self, row, col, tab);
    }

    fn setVirtualCursor(self: *Editor, ctx: RenderContext) void {
        if (self.state.mode == .Command) {
            if (self.commandPopupGeometry()) |geom| {
                const input_space = geom.width -| 5;
                const cursor_col = @min(self.state.command_popup.input.items.len, input_space);
                self.renderer.screen.setCursor(geom.row + 2, geom.col + 5 + cursor_col);
            }
            return;
        }
        if (self.state.mode == .GlobalSearch) {
            if (self.globalSearchPopupGeometry()) |geom| {
                const input_space = geom.width -| 5;
                const cursor_col = @min(self.state.global_search.input.items.len, input_space);
                self.renderer.screen.setCursor(geom.row + 2, geom.col + 5 + cursor_col);
            }
            return;
        }
        if (self.state.mode == .Search) {
            self.renderer.screen.setCursor(self.statusTerminalRow(), 2 + self.state.search_buffer.items.len);
            return;
        }
        if (self.state.mode == .OpenFilePrompt) {
            self.renderer.screen.setCursor(self.statusTerminalRow(), @min(self.width, 12 + self.state.command_buffer.items.len));
            return;
        }
        if (self.state.mode == .FilesystemPicker or self.state.mode == .Prompt or self.state.mode == .Help or
            self.state.mode == .Dashboard or self.state.mode == .SaveConfirmation)
        {
            self.renderer.screen.hideCursor();
            return;
        }
        if (self.state.explorer_focused and self.state.explorer_visible and self.state.tree != null) {
            self.renderer.screen.hideCursor();
            return;
        }
        if (self.state.mode == .Terminal) {
            const pos = self.terminalCursorScreenPosition();
            self.renderer.screen.setCursor(pos.row, pos.col);
            return;
        }

        const t = ctx.tab orelse {
            self.renderer.screen.hideCursor();
            return;
        };
        const content_width = ctx.buf_width -| ctx.gutter_width;
        const mc = t.mainCursor();
        const vis_col = visibleCursorCol(mc.col, t.scroll_col, content_width);
        const vis_row = if (visibleLineOffset(t, t.scroll_row, mc.row, ctx.visible_rows)) |offset| offset + 3 else 3;
        self.renderer.screen.setCursor(vis_row, ctx.buf_start_col + ctx.gutter_width + vis_col);
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
        return line_render.renderStyleFromSyntax(style);
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
        return completion_menu.completionItemObject(value);
    }

    fn completionItemString(item: std.json.ObjectMap, key: []const u8) ?[]const u8 {
        return completion_menu.completionItemString(item, key);
    }

    fn completionKindLabel(item: std.json.ObjectMap) []const u8 {
        return completion_menu.completionKindLabel(item);
    }

    fn handleCompletionInput(self: *Editor, event: terminal.KeyEvent) !bool {
        if (!self.state.lsp_ui.completion_active or self.state.lsp_ui.completion_items == null) return false;
        const items = self.state.lsp_ui.completionItems();

        if (self.completionActionCommandForEvent(event)) |command| {
            switch (command) {
                .completion_previous => {
                    if (self.state.lsp_ui.completion_selected > 0) {
                        self.state.lsp_ui.completion_selected -= 1;
                    } else if (items.len > 0) {
                        self.state.lsp_ui.completion_selected = items.len - 1;
                    }
                    return true;
                },
                .completion_next => {
                    if (self.state.lsp_ui.completion_selected < items.len - 1) {
                        self.state.lsp_ui.completion_selected += 1;
                    } else {
                        self.state.lsp_ui.completion_selected = 0;
                    }
                    return true;
                },
                .completion_accept => {
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
                },
                .completion_cancel => {
                    self.state.lsp_ui.clearCompletion();
                    return true;
                },
                else => unreachable,
            }
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

fn makeFastMoveTestEditor(allocator: std.mem.Allocator) !Editor {
    return makeFastMoveTestEditorWithLineCount(allocator, 4);
}

fn defaultKeyForCommand(ed: *const Editor, context: commands.CommandContext, id: commands.CommandId) terminal.KeyEvent {
    return ed.keyEventForCommand(context, id) orelse unreachable;
}

fn installTestKeybindingOverrides(ed: *Editor, overrides: []const command_keybindings.UserBindingOverride) !void {
    var diagnostics = command_keybindings.BuildDiagnostics{};
    defer diagnostics.deinit(ed.allocator);
    var registry = try command_keybindings.Registry.fromDefaultsAndConfig(ed.allocator, overrides, &.{}, &diagnostics);
    errdefer registry.deinit(ed.allocator);
    try std.testing.expect(!diagnostics.hasErrors());
    ed.keybinding_registry.deinit(ed.allocator);
    ed.keybinding_registry = registry;
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

fn makeFoldTestEditor(allocator: std.mem.Allocator) !Editor {
    var ed = try Editor.init(allocator, std.testing.io, .{});
    errdefer ed.deinit();

    var buf = try buffer.Buffer.init(allocator);
    errdefer buf.deinit();
    var first = buf.lines.orderedRemove(0);
    first.deinit();

    const lines = [_][]const u8{
        "fn main() {",
        "    foo();",
        "}",
        "after();",
    };
    for (lines) |line| {
        try buf.lines.append(allocator, try buffer.Line.fromSlice(allocator, line));
    }

    try ed.addTab(buf);
    ed.state.mode = .Normal;
    ed.width = 80;
    ed.height = 12;
    return ed;
}

pub fn start_editor(io: std.Io, allocator: std.mem.Allocator, cfg: config.Config) !void {
    var editor = try Editor.init(allocator, io, cfg);
    defer editor.deinit();
    try editor.run();
}

fn addNamedTestTab(state: *state_mod.EditorState, allocator: std.mem.Allocator, name: []const u8) !void {
    var buf = try buffer.Buffer.init(allocator);
    errdefer buf.deinit();
    try buf.setFilename(name);
    try std.testing.expect(try state.addTab(allocator, buf));
}

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
    const active_end = active_start + Editor.tabLabelWidth(state.tabs.items, &state.tabs.items[state.active_tab_index]);
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
    try ed.renderBenchmarkFrame(&out.writer);

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
    try ed.renderBenchmarkFrame(&out.writer);

    const rendered = out.written();
    try std.testing.expect(std.mem.indexOf(u8, rendered, "ERROR") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "boom") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "") == null);
}

test "help popup geometry anchors bottom-right" {
    const cfg = config.Config{};
    var ed = try Editor.init(std.testing.allocator, std.testing.io, cfg);
    defer ed.deinit();

    ed.width = 80;
    ed.height = 24;
    ed.state.help_popup.open();
    ed.state.mode = .Help;

    const geom = ed.helpPopupGeometry() orelse return error.ExpectedHelpGeometry;
    try std.testing.expectEqual(@as(usize, 56), geom.width);
    try std.testing.expectEqual(@as(usize, 22), geom.col);
    try std.testing.expectEqual(ed.statusRowIndex() - 1, geom.row + geom.height - 1);
}

test "help popup geometry stays inside narrow viewport" {
    const cfg = config.Config{};
    var ed = try Editor.init(std.testing.allocator, std.testing.io, cfg);
    defer ed.deinit();

    ed.width = 30;
    ed.height = 10;
    ed.state.help_popup.open();
    ed.state.mode = .Help;

    const geom = ed.helpPopupGeometry() orelse return error.ExpectedHelpGeometry;
    try std.testing.expect(geom.width <= ed.width);
    try std.testing.expect(geom.col + geom.width <= ed.width);
    try std.testing.expect(geom.row + geom.height <= ed.statusRowIndex());
    try std.testing.expect(ed.helpPopupBodyRows() > 0);
}

test "virtual renderer includes help popup content" {
    const cfg = config.Config{};
    var ed = try Editor.init(std.testing.allocator, std.testing.io, cfg);
    defer ed.deinit();

    ed.width = 80;
    ed.height = 24;
    ed.state.help_popup.open();
    ed.state.mode = .Help;

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try ed.renderBenchmarkFrame(&out.writer);

    const rendered = out.written();
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Help") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Modes") != null);
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

test "virtual renderer and movement respect folded lines" {
    var ed = try makeFoldTestEditor(std.testing.allocator);
    defer ed.deinit();

    const tab = ed.currentTab().?;
    try tab.buf.foldCurrentBraceBlock(0, 10);

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try ed.renderBenchmarkFrame(&out.writer);

    const rendered = out.written();
    try std.testing.expect(std.mem.indexOf(u8, rendered, "foo();") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "2 lines folded") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "after();") != null);

    tab.mainCursor().row = 0;
    tab.mainCursor().col = 0;
    const down = defaultKeyForCommand(&ed, .normal, .navigation_move_down);
    const up = defaultKeyForCommand(&ed, .normal, .navigation_move_up);
    try std.testing.expect(try input.handleMovement(&ed, down));
    try std.testing.expectEqual(@as(usize, 3), tab.mainCursor().row);
    try std.testing.expect(try input.handleMovement(&ed, up));
    try std.testing.expectEqual(@as(usize, 0), tab.mainCursor().row);
}

test "movement coalescing helper accepts repeated plain Down" {
    var ed = try makeFastMoveTestEditor(std.testing.allocator);
    defer ed.deinit();

    const down = defaultKeyForCommand(&ed, .normal, .navigation_move_down);
    const candidate = switch (ed.movementCoalescingEligibilityBefore(down)) {
        .eligible => |candidate| candidate,
        .blocked => return error.ExpectedCoalescingEligibility,
    };

    try std.testing.expectEqual(CoalescedMovement.down, candidate.movement);
    try std.testing.expect(ed.coalescingStopReasonForNext(candidate, down, 1) == null);
}

test "movement coalescing stores different movement for next input" {
    var ed = try makeFastMoveTestEditor(std.testing.allocator);
    defer ed.deinit();

    const down = defaultKeyForCommand(&ed, .normal, .navigation_move_down);
    const up = defaultKeyForCommand(&ed, .normal, .navigation_move_up);
    const candidate = switch (ed.movementCoalescingEligibilityBefore(down)) {
        .eligible => |candidate| candidate,
        .blocked => return error.ExpectedCoalescingEligibility,
    };

    try std.testing.expectEqual(
        MovementCoalesceStopReason.different_key,
        ed.coalescingStopReasonForNext(candidate, up, 1).?,
    );
}

test "movement coalescing stores printable input for next input" {
    var ed = try makeFastMoveTestEditor(std.testing.allocator);
    defer ed.deinit();

    const down = defaultKeyForCommand(&ed, .normal, .navigation_move_down);
    const candidate = switch (ed.movementCoalescingEligibilityBefore(down)) {
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
        .Help,
        .Terminal,
    };

    for (rejected_modes) |mode| {
        ed.state.mode = mode;
        const down = defaultKeyForCommand(&ed, .normal, .navigation_move_down);
        switch (ed.movementCoalescingEligibilityBefore(down)) {
            .eligible => return error.ExpectedCoalescingRejection,
            .blocked => {},
        }
    }
}

test "movement coalescing rejects completion and focused explorer" {
    var ed = try makeFastMoveTestEditor(std.testing.allocator);
    defer ed.deinit();

    ed.state.lsp_ui.completion_active = true;
    const down = defaultKeyForCommand(&ed, .normal, .navigation_move_down);
    try std.testing.expectEqual(
        MovementCoalesceStopReason.overlay_active,
        switch (ed.movementCoalescingEligibilityBefore(down)) {
            .eligible => return error.ExpectedCoalescingRejection,
            .blocked => |reason| reason,
        },
    );

    ed.state.lsp_ui.completion_active = false;
    ed.state.explorer_visible = true;
    ed.state.explorer_focused = true;
    try std.testing.expectEqual(
        MovementCoalesceStopReason.overlay_active,
        switch (ed.movementCoalescingEligibilityBefore(down)) {
            .eligible => return error.ExpectedCoalescingRejection,
            .blocked => |reason| reason,
        },
    );
}

test "movement coalescing stops at max batch count" {
    var ed = try makeFastMoveTestEditor(std.testing.allocator);
    defer ed.deinit();

    const down = defaultKeyForCommand(&ed, .normal, .navigation_move_down);
    const candidate = switch (ed.movementCoalescingEligibilityBefore(down)) {
        .eligible => |candidate| candidate,
        .blocked => return error.ExpectedCoalescingEligibility,
    };

    try std.testing.expectEqual(
        MovementCoalesceStopReason.max_batch,
        ed.coalescingStopReasonForNext(candidate, down, max_movement_coalesce_batch_count).?,
    );
}

test "movement coalescing rejects ambiguous non-simple movement binding" {
    var ed = try makeFastMoveTestEditor(std.testing.allocator);
    defer ed.deinit();

    try installTestKeybindingOverrides(&ed, &.{
        .{
            .context = .normal,
            .sequence = command_keybindings.keySpecial(.Down),
            .command = .navigation_line_start,
            .replace_default_sequence = command_keybindings.altKey(.Down),
        },
    });

    const down = defaultKeyForCommand(&ed, .normal, .navigation_move_down);
    switch (ed.movementCoalescingEligibilityBefore(down)) {
        .eligible => return error.ExpectedCoalescingRejection,
        .blocked => {},
    }
}

test "pending key is processed before reading terminal input" {
    var ed = try makeFastMoveTestEditor(std.testing.allocator);
    defer ed.deinit();

    const up = defaultKeyForCommand(&ed, .normal, .navigation_move_up);
    const down = defaultKeyForCommand(&ed, .normal, .navigation_move_down);
    ed.pending_key = up;
    var reader = std.Io.Reader.fixed("\x1b[B");
    var metrics = perf.FrameMetrics{};

    const first = try ed.readInputKey(&reader, &metrics);
    try std.testing.expect(first.from_pending);
    try std.testing.expect(first.event.eql(up));
    try std.testing.expect(ed.pending_key == null);

    const second = try ed.readInputKey(&reader, &metrics);
    try std.testing.expect(!second.from_pending);
    try std.testing.expect(second.event.eql(down));
}

test "normal-mode hjkl movement can coalesce only when bound to movement" {
    var ed = try makeFastMoveTestEditor(std.testing.allocator);
    defer ed.deinit();

    const j = terminal.KeyEvent{ .key = .Char, .char = 'j' };
    switch (ed.movementCoalescingEligibilityBefore(j)) {
        .eligible => return error.ExpectedCoalescingRejection,
        .blocked => {},
    }

    try installTestKeybindingOverrides(&ed, &.{
        .{
            .context = .normal,
            .sequence = command_keybindings.keyChar('j'),
            .command = .navigation_move_down,
            .replace_default_sequence = command_keybindings.keySpecial(.Down),
        },
    });
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

    const rejected = [_]EditorMode{ .Dashboard, .Command, .OpenFilePrompt, .FilesystemPicker, .Prompt, .Search, .GlobalSearch, .Help, .Terminal, .SaveConfirmation };
    for (rejected) |mode| {
        ed.state.mode = mode;
        try std.testing.expect(!ed.modeAllowsCompletion());
    }
}

test "completion trigger keys resolve from normal and insert contexts" {
    var ed = try makeFastMoveTestEditor(std.testing.allocator);
    defer ed.deinit();

    ed.state.mode = .Normal;
    try std.testing.expectEqual(commands.CommandId.completion_auto_trigger, ed.completionCommandForEvent(.{ .key = .Char, .char = '.' }).?);
    try std.testing.expectEqual(commands.CommandId.completion_trigger, ed.completionCommandForEvent(.{ .key = .Char, .char = ' ', .ctrl = true }).?);

    ed.state.mode = .Insert;
    try std.testing.expectEqual(commands.CommandId.completion_auto_trigger, ed.completionCommandForEvent(.{ .key = .Char, .char = '.' }).?);
    try std.testing.expectEqual(commands.CommandId.completion_trigger, ed.completionCommandForEvent(.{ .key = .Char, .char = ' ', .ctrl = true }).?);

    try installTestKeybindingOverrides(&ed, &.{
        .{
            .context = .normal,
            .sequence = command_keybindings.ctrlChar('j'),
            .command = .completion_trigger,
            .replace_default_sequence = command_keybindings.ctrlChar(' '),
        },
        .{
            .context = .insert,
            .sequence = command_keybindings.ctrlChar('j'),
            .command = .completion_trigger,
            .replace_default_sequence = command_keybindings.ctrlChar(' '),
        },
    });
    try std.testing.expect(ed.completionCommandForEvent(.{ .key = .Char, .char = ' ', .ctrl = true }) == null);
    try std.testing.expectEqual(commands.CommandId.completion_trigger, ed.completionCommandForEvent(.{ .key = .Char, .char = 'j', .ctrl = true }).?);
}

test "completion popup controls resolve through completion context" {
    const allocator = std.testing.allocator;
    var ed = try makeFastMoveTestEditor(allocator);
    defer ed.deinit();

    var arr = std.json.Array.init(allocator);
    try arr.append(.{ .string = try allocator.dupe(u8, "first") });
    try arr.append(.{ .string = try allocator.dupe(u8, "second") });
    ed.state.lsp_ui.replaceCompletion(.{ .array = arr });

    try std.testing.expect(try ed.handleCompletionInput(.{ .key = .Down }));
    try std.testing.expectEqual(@as(usize, 1), ed.state.lsp_ui.completion_selected);

    try std.testing.expect(try ed.handleCompletionInput(.{ .key = .Up }));
    try std.testing.expectEqual(@as(usize, 0), ed.state.lsp_ui.completion_selected);

    try std.testing.expect(try ed.handleCompletionInput(.{ .key = .Esc }));
    try std.testing.expect(!ed.state.lsp_ui.completion_active);
}

test "completion accept inserts selected item" {
    const allocator = std.testing.allocator;
    var ed = try makeFastMoveTestEditor(allocator);
    defer ed.deinit();

    var item = std.json.ObjectMap{};
    try item.put(allocator, try allocator.dupe(u8, "label"), .{ .string = try allocator.dupe(u8, "World") });
    var arr = std.json.Array.init(allocator);
    try arr.append(.{ .object = item });
    ed.state.lsp_ui.replaceCompletion(.{ .array = arr });

    try std.testing.expect(try ed.handleCompletionInput(.{ .key = .Enter }));
    try std.testing.expect(!ed.state.lsp_ui.completion_active);

    const tab = ed.currentTab().?;
    const line = try tab.buf.lines.items[0].slice(allocator);
    defer allocator.free(line);
    try std.testing.expectEqualStrings("Worldalpha", line);
}

test "insert mode alt-up then character stays in bounds" {
    var ed = try makeFastMoveTestEditor(std.testing.allocator);
    defer ed.deinit();

    ed.state.mode = .Normal;
    ed.state.render_dirty = true;
    ed.state.force_full_render = true;

    var reader = std.Io.Reader.fixed("i\x1b[1;3Ax\x11");
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    try ed.runWithIO(&reader, &out.writer);

    const tab = ed.currentTab().?;
    const line = try tab.buf.lines.items[0].slice(std.testing.allocator);
    defer std.testing.allocator.free(line);
    try std.testing.expectEqualStrings("alphax", line);
    try std.testing.expectEqual(@as(usize, 6), tab.mainCursor().col);
}
