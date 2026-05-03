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

const max_fifo_events_per_idle_tick = 8;

pub const EditorMode = state_mod.EditorMode;
pub const Pos = tab_mod.Pos;
pub const Cursor = tab_mod.Cursor;
pub const Tab = tab_mod.Tab;
pub const ResolvedKeybindings = keybindings.ResolvedKeybindings;

const CursorMoveState = struct {
    row: usize,
    col: usize,
    scroll_row: usize,
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

const RenderContext = struct {
    tab: ?*Tab,
    buf_start_col: usize,
    buf_width: usize,
    gutter_width: usize,
    visible_rows: usize,
    status_style: render_mod.RenderStyle,
    status_text: []const u8,
    status_text_len: usize,
};

const CommandPopupGeometry = struct {
    row: usize,
    col: usize,
    width: usize,
    suggestion_count: usize,
};

const command_popup_title = " Cmdline ";
const global_search_popup_title = " Search ";

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

pub const Editor = struct {
    config: config.Config,
    keys: ResolvedKeybindings,
    allocator: std.mem.Allocator,
    io: std.Io,
    state: state_mod.EditorState,
    runtime: runtime_mod.EditorRuntime,
    renderer: renderer_mod.EditorRenderer,
    width: usize = 0,
    height: usize = 0,
    should_quit: bool = false,
    is_deinitialized: bool = false,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, cfg: config.Config) !Editor {
        var runtime = try runtime_mod.EditorRuntime.init(allocator, io);
        errdefer runtime.deinit(allocator);

        return Editor{
            .allocator = allocator,
            .io = io,
            .config = cfg,
            .keys = ResolvedKeybindings.init(cfg.keybindings),
            .state = state_mod.EditorState.init(allocator),
            .runtime = runtime,
            .renderer = renderer_mod.EditorRenderer.init(allocator),
        };
    }

    pub fn deinit(self: *Editor) void {
        if (self.is_deinitialized) return;
        self.is_deinitialized = true;

        self.runtime.deinit(self.allocator);
        self.state.deinit(self.allocator);
        self.renderer.deinit(self.allocator);
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

        while (!self.should_quit) {
            const loop_start = perf.nowNs();
            var metrics = perf.FrameMetrics{};

            var handled_input = false;
            var first_fast_cursor_before: ?CursorMoveState = null;
            var fast_cursor_candidate = true;
            var last_update_end_ns: ?u64 = null;
            var input_count: usize = 0;
            while (input_count < 128) : (input_count += 1) {
                const read_start = perf.nowNs();
                const event = try terminal.readKey(reader);
                metrics.add(.input_poll, perf.elapsedNs(read_start));
                if (event.key == .None) break;
                handled_input = true;
                metrics.input_events += 1;

                const render_after_event = self.shouldRenderAfterInputEvent(event);
                if (render_after_event) {
                    metrics.cursor_move_events += 1;
                    if (first_fast_cursor_before == null) {
                        first_fast_cursor_before = self.captureCursorMoveState();
                    }
                } else {
                    fast_cursor_candidate = false;
                }

                const input_handle_start = perf.nowNs();
                try self.handleRuntimeKey(event);
                const update_elapsed = perf.elapsedNs(input_handle_start);
                const update_end = perf.nowNs();
                metrics.add(.update_state, update_elapsed);
                metrics.input_to_update_ns += update_end - read_start;
                last_update_end_ns = update_end;

                if (self.should_quit) break;
                if (!render_after_event) break;
            }

            if (!handled_input) {
                const events_start = perf.nowNs();
                try self.processBackgroundEvents(max_fifo_events_per_idle_tick);
                metrics.add(.event_processing, perf.elapsedNs(events_start));

                const update_start = perf.nowNs();
                try self.flushPendingLspChanges(false);
                metrics.add(.update_state, perf.elapsedNs(update_start));
            }

            if (self.state.render_dirty) {
                aw.clearRetainingCapacity();

                var rendered_fast_cursor = false;
                if (fast_cursor_candidate) {
                    if (first_fast_cursor_before) |before| {
                        if (self.canFastRenderCursorMove(before)) {
                            const frame_start = perf.nowNs();
                            try self.renderFastCursorMove(writer, before);
                            metrics.add(.build_frame, perf.elapsedNs(frame_start));
                            metrics.fast_cursor_move = true;
                            metrics.render_kind = .fast_cursor;
                            rendered_fast_cursor = true;
                        }
                    }
                }

                if (!rendered_fast_cursor) {
                    const frame_start = perf.nowNs();
                    try terminal.hideCursor(writer);
                    if (self.canUseVirtualRenderer()) {
                        try self.renderVirtual(writer, &metrics);
                    } else {
                        try self.render(writer);
                        try self.renderCompletionMenu(writer);
                    }
                    try terminal.showCursor(writer);
                    metrics.add(.build_frame, perf.elapsedNs(frame_start));
                    metrics.render_kind = if (self.state.force_full_render) .full else .partial;
                }

                const flush_start = perf.nowNs();
                if (last_update_end_ns) |update_end| {
                    metrics.update_to_flush_ns += flush_start - update_end;
                }
                const bytes = aw.written().len;
                try raw_writer.writeAll(aw.written());
                metrics.add(.flush_output, perf.elapsedNs(flush_start));
                self.runtime.updateFrameCapacityFps(metrics.get(.build_frame) + metrics.get(.flush_output));
                metrics.rendered = true;
                metrics.bytes_emitted = bytes;
                metrics.write_count = 1;
                self.state.render_dirty = false;
                if (!rendered_fast_cursor) {
                    self.state.force_full_render = false;
                }
            }

            if (!handled_input) {
                const syntax_request_start = perf.nowNs();
                try self.queueSyntaxParseForCurrentTab();
                metrics.add(.update_state, perf.elapsedNs(syntax_request_start));
            }

            metrics.add(.total_loop, perf.elapsedNs(loop_start));
            self.runtime.perf_sampler.observe(metrics);

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
        const top_reserved = 2;
        const bot_reserved = 1;
        const visible_rows = if (self.height > top_reserved + bot_reserved) self.height - (top_reserved + bot_reserved) else 0;
        const viewport = self.bufferViewportGeometry();
        return .{
            .row = mc.row,
            .col = mc.col,
            .scroll_row = tab.scroll_row,
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

    fn buildRenderContext(self: *Editor, status_buf: *[160]u8) RenderContext {
        const tab = self.currentTab();
        const viewport = self.bufferViewportGeometry();
        const gutter_width: usize = if (tab) |t|
            self.calculateGutterWidth(t.buf.lines.items.len)
        else
            0;
        const top_reserved = 2;
        const bot_reserved = 1;
        const visible_rows = if (self.height > top_reserved + bot_reserved) self.height - (top_reserved + bot_reserved) else 0;

        const status_style: render_mod.RenderStyle = switch (self.state.mode) {
            .Search => .search_status,
            .GlobalSearch => .search_status,
            .Command => .status_command,
            .Insert => .status_insert,
            else => .status_normal,
        };
        const status_text = self.buildStatusText(tab, status_buf) catch "";

        return .{
            .tab = tab,
            .buf_start_col = viewport.start_col,
            .buf_width = viewport.width,
            .gutter_width = gutter_width,
            .visible_rows = visible_rows,
            .status_style = status_style,
            .status_text = status_text,
            .status_text_len = status_text.len,
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
            .Command => "-- COMMAND --",
            .GlobalSearch => "-- GLOBAL SEARCH --",
            .Insert => "-- INSERT --",
            else => "-- NORMAL --",
        };
        if (tab) |t| {
            const diag_count = if (t.buf.filename) |fname| self.state.lsp_ui.diagnosticCountForFile(fname) else 0;
            if (diag_count > 0) {
                return try std.fmt.bufPrint(buf, " {s} | Row: {d}, Col: {d} | Cursors: {d} | ERR: {d} | FPS: {d} ", .{ mode_str, t.mainCursor().row + 1, t.mainCursor().col + 1, t.cursors.items.len, diag_count, self.runtime.fps });
            }
            return try std.fmt.bufPrint(buf, " {s} | Row: {d}, Col: {d} | Cursors: {d} | FPS: {d} ", .{ mode_str, t.mainCursor().row + 1, t.mainCursor().col + 1, t.cursors.items.len, self.runtime.fps });
        }
        return try std.fmt.bufPrint(buf, " {s} | No file open | FPS: {d} ", .{ mode_str, self.runtime.fps });
    }

    fn canFastRenderCursorMove(self: *Editor, before: CursorMoveState) bool {
        if (before.mode != .Normal and before.mode != .Insert) return false;
        if (self.state.mode != .Normal and self.state.mode != .Insert) return false;
        if (before.cursor_count != 1) return false;
        if (before.had_selection) return false;
        if (self.state.tabs.items.len != before.tab_count) return false;
        if (self.state.active_tab_index != before.active_tab_index) return false;
        if (self.width != before.width or self.height != before.height) return false;
        if (self.state.explorer_focused) return false;
        if (self.state.tree) |tree| {
            if (tree.search_active) return false;
        }
        if (self.state.lsp_ui.completion_active) return false;
        if (self.state.search_buffer.items.len > 0) return false;

        const tab = self.currentTab() orelse return false;
        if (&tab.buf != before.buffer_ptr) return false;
        if (tab.scroll_row != before.scroll_row) return false;
        if (tab.cursors.items.len != 1) return false;
        if (tab.main_cursor_idx != 0) return false;

        const mc = tab.mainCursor();
        const viewport = self.bufferViewportGeometry();
        if (viewport.start_col != before.buf_start_col or viewport.width != before.buf_width) return false;
        if (mc.selection_start != null) return false;
        if (mc.row == before.row and mc.col == before.col) return false;
        if (before.row < tab.scroll_row or before.row >= tab.scroll_row + before.visible_rows) return false;
        if (mc.row < tab.scroll_row or mc.row >= tab.scroll_row + before.visible_rows) return false;

        return true;
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

        try self.renderStatusLineLegacyStyle(writer, tab);

        const content_width = before.buf_width -| before.gutter_width;
        const vis_col = if (mc.col > content_width) content_width else mc.col;
        const vis_row = mc.row - tab.scroll_row + 3;
        try terminal.moveCursor(writer, vis_row, before.buf_start_col + before.gutter_width + vis_col);
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
        try terminal.moveCursor(writer, self.height, 1);
        try terminal.clearLine(writer);

        var status_buf: [160]u8 = undefined;
        const status_text = self.buildStatusText(tab, &status_buf) catch "";
        if (self.state.error_message) |err_msg| {
            try writer.writeAll("\x1b[31;1m");
            try writer.print("{s}", .{err_msg});
            try writer.writeAll("\x1b[0m");
            return;
        }

        const mode_color =
            if (self.state.mode == .Command)
                "\x1b[48;5;220m\x1b[30m"
            else if (self.state.mode == .Search or self.state.mode == .GlobalSearch)
                "\x1b[48;5;228m\x1b[30m"
            else if (self.state.mode == .Normal)
                "\x1b[48;5;121m\x1b[30m"
            else
                "\x1b[48;5;117m\x1b[30m";
        try writer.writeAll(mode_color);
        try writer.writeAll(status_text);
        if (self.width > status_text.len) {
            for (0..self.width - status_text.len) |_| {
                try writer.writeAll(" ");
            }
        }
        try writer.writeAll("\x1b[0m");
    }

    fn handleRuntimeKey(self: *Editor, event: terminal.KeyEvent) !void {
        logz.debug().fmt("msg", "key event: key={s}, char={c}, ctrl={}, alt={}", .{ @tagName(event.key), event.char, event.ctrl, event.alt }).log();

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
        self.markDirty(.partial);

        if (self.currentTab()) |tab| {
            if (tab.needsLspChangeNotification()) {
                self.notePendingLspChange();
            }

            const is_completion_auto_trigger = event.eql(self.keys.completion_auto_trigger);
            const is_completion_trigger = event.eql(self.keys.completion_trigger);

            if (is_completion_auto_trigger or is_completion_trigger) {
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
        _ = self;
        _ = try tab.syntax_highlighter.prepareForAsyncBuffer(&tab.buf) orelse {
            tab.syntax_requested_revision = null;
            return;
        };

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

    /// Adjust scroll_row so cursor_row is always within the visible viewport.
    pub fn clampScroll(self: *Editor) void {
        const tab = self.currentTab() orelse return;
        const mc = tab.mainCursor();
        const top_reserved = 2; // tabs + separator
        const bot_reserved = 1; // status bar
        const visible_rows = if (self.height > (top_reserved + bot_reserved)) self.height - (top_reserved + bot_reserved) else 1;
        if (mc.row < tab.scroll_row) {
            tab.scroll_row = mc.row;
        } else if (mc.row >= tab.scroll_row + visible_rows) {
            tab.scroll_row = mc.row - visible_rows + 1;
        }
    }

    fn renderTabs(self: *Editor, writer: anytype, start_col: usize, width: usize) !void {
        try terminal.moveCursor(writer, 1, 1);
        try terminal.eraseToLineEnd(writer);
        try terminal.moveCursor(writer, 1, start_col);

        if (self.state.tabs.items.len == 0) return;

        const max_tab_width = 20;
        var current_col: usize = 1;

        for (self.state.tabs.items, 0..) |tab, i| {
            const is_active = (i == self.state.active_tab_index);
            const filename = tab.buf.filename orelse "unsaved";
            const basename = std.fs.path.basename(filename);

            var display_name: []const u8 = basename;
            var truncated = false;
            if (display_name.len > max_tab_width - 4) {
                display_name = display_name[0 .. max_tab_width - 7];
                truncated = true;
            }

            if (is_active) {
                try writer.writeAll("\x1b[1;33m"); // Bold Yellow
                try writer.writeAll("▶ ");
            } else {
                try writer.writeAll("\x1b[2;37m"); // Dim Grey
                try writer.writeAll("  ");
            }

            try writer.print("{s}{s} ", .{ display_name, if (truncated) "..." else "" });
            try writer.writeAll("\x1b[0m");
            try writer.writeAll("│ ");

            const tab_len = display_name.len + (if (truncated) @as(usize, 3) else @as(usize, 0)) + 5; // "  " + name + " " + "│ "
            current_col += tab_len;
            if (current_col >= width) break;
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
        try writer.writeAll("\x1b[48;5;235m\x1b[38;5;250m╭");
        for (0..inner_width) |_| try writer.writeAll("─");
        try writer.writeAll("╮\x1b[0m");
        if (command_popup_title.len + 2 < geom.width) {
            try terminal.moveCursor(writer, screen_row, title_col);
            try writer.writeAll("\x1b[48;5;235m\x1b[38;5;250m");
            try writer.writeAll(command_popup_title);
            try writer.writeAll("\x1b[0m");
        }

        try terminal.moveCursor(writer, screen_row + 1, screen_col);
        try writer.writeAll("\x1b[48;5;235m\x1b[38;5;250m│\x1b[48;5;235m\x1b[38;5;250m > \x1b[48;5;235m\x1b[38;5;255m");
        const input_space = inner_width -| 3;
        const shown_input = popup.input.items[0..@min(popup.input.items.len, input_space)];
        try writer.writeAll(shown_input);
        for (shown_input.len..input_space) |_| try writer.writeByte(' ');
        try writer.writeAll("\x1b[48;5;235m\x1b[38;5;250m│\x1b[0m");

        for (0..geom.suggestion_count) |i| {
            const suggestion = popup.suggestions.items[i].name();
            const selected = popup.selected_index != null and popup.selected_index.? == i;
            try terminal.moveCursor(writer, screen_row + 2 + i, screen_col);
            if (selected) {
                try writer.writeAll("\x1b[48;5;238m\x1b[38;5;255m");
            } else {
                try writer.writeAll("\x1b[48;5;235m\x1b[38;5;250m");
            }
            try writer.writeAll("│ ");
            const shown = suggestion[0..@min(suggestion.len, inner_width -| 2)];
            try writer.writeAll(shown);
            for (shown.len..inner_width -| 1) |_| try writer.writeByte(' ');
            try writer.writeAll("│\x1b[0m");
        }

        try terminal.moveCursor(writer, screen_row + 2 + geom.suggestion_count, screen_col);
        try writer.writeAll("\x1b[48;5;235m\x1b[38;5;250m╰");
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
        try writer.writeAll("\x1b[48;5;235m\x1b[38;5;250m╭");
        for (0..inner_width) |_| try writer.writeAll("─");
        try writer.writeAll("╮\x1b[0m");
        if (global_search_popup_title.len + 2 < geom.width) {
            try terminal.moveCursor(writer, screen_row, title_col);
            try writer.writeAll("\x1b[48;5;235m\x1b[38;5;250m");
            try writer.writeAll(global_search_popup_title);
            try writer.writeAll("\x1b[0m");
        }

        try terminal.moveCursor(writer, screen_row + 1, screen_col);
        try writer.writeAll("\x1b[48;5;235m\x1b[38;5;250m│\x1b[48;5;235m\x1b[38;5;250m > \x1b[48;5;235m\x1b[38;5;255m");
        const input_space = inner_width -| 3;
        const shown_input = popup.input.items[0..@min(popup.input.items.len, input_space)];
        try writer.writeAll(shown_input);
        for (shown_input.len..input_space) |_| try writer.writeByte(' ');
        try writer.writeAll("\x1b[48;5;235m\x1b[38;5;250m│\x1b[0m");

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
            try writer.writeAll(globalSearchRowBaseAnsi(selected));
            try writer.writeAll("│ ");
            const written = try renderGlobalSearchRowText(writer, render_row, popup.results.items, inner_width -| 2, selected);
            try writer.writeAll(globalSearchRowBaseAnsi(selected));
            for (written..inner_width -| 1) |_| try writer.writeByte(' ');
            try writer.writeAll("│\x1b[0m");
        }

        try terminal.moveCursor(writer, screen_row + 2 + geom.suggestion_count, screen_col);
        try writer.writeAll("\x1b[48;5;235m\x1b[38;5;250m╰");
        for (0..inner_width) |_| try writer.writeAll("─");
        try writer.writeAll("╯\x1b[0m");
    }

    fn render(self: *Editor, writer: anytype) !void {
        if (self.state.mode == .Dashboard or self.state.mode == .OpenFilePrompt) {
            try self.state.dash.render(writer, self.width, self.height);

            if (self.state.mode == .OpenFilePrompt) {
                try terminal.moveCursor(writer, self.height, 1);
                try terminal.clearLine(writer);
                try writer.print("Open file: {s}", .{self.state.command_buffer.items});
                try terminal.moveCursor(writer, self.height, 12 + self.state.command_buffer.items.len);
            } else if (self.state.error_message) |err_msg| {
                try terminal.moveCursor(writer, self.height, 1);
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
                try self.state.tree.?.renderAt(writer, exp_width, self.height - 1, 2, self.state.explorer_focused);

                for (2..self.height) |r| {
                    try terminal.moveCursor(writer, r, exp_width + 1);
                    try writer.writeAll("│");
                }
                buf_start_col = exp_width + 2;
                buf_width = self.width -| (exp_width + 1);
            }
        }

        try self.renderTabs(writer, buf_start_col, buf_width);

        // Line number gutter.
        const tab = self.currentTab();
        const gutter_width: usize = if (tab) |t|
            self.calculateGutterWidth(t.buf.lines.items.len)
        else
            0;

        const top_reserved = 2; // tabs + separator
        const bot_reserved = 1; // status bar
        const visible_rows = if (self.height > (top_reserved + bot_reserved)) self.height - (top_reserved + bot_reserved) else 0;
        if (tab) |t| {
            self.prepareSyntaxForViewport(t, t.scroll_row, t.scroll_row + visible_rows, 20) catch {};
        }
        for (1..visible_rows + 1) |screen_row| {
            // 1. Move to the correct column for the right-hand panel (start at row 3)
            try terminal.moveCursor(writer, screen_row + 2, buf_start_col);

            if (tab) |t| {
                const buffer_line_idx = screen_row + t.scroll_row - 1;
                if (buffer_line_idx < t.buf.lines.items.len) {
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

                    var char_idx: usize = 0;
                    var m_idx: usize = 0;
                    while (char_idx < line_len and char_idx < content_width) : (char_idx += 1) {
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

                        try writer.writeByte(line.byteAt(char_idx).?);
                        try writer.writeAll("\x1b[0m");
                    }
                }
            }

            // 2. Erase the tail of the line (clears both stale content and avoids wiping explorer)
            try terminal.eraseToLineEnd(writer);
        }

        // Draw status bar
        try terminal.moveCursor(writer, self.height, 1);
        try terminal.clearLine(writer);

        if (self.state.mode == .Command) {
            var status_buf: [160]u8 = undefined;
            const status_text = try self.buildStatusText(tab, &status_buf);
            try writer.writeAll("\x1b[48;5;220m\x1b[30m");
            try writer.writeAll(status_text);
            if (self.width > status_text.len) {
                for (0..self.width - status_text.len) |_| {
                    try writer.writeAll(" ");
                }
            }
            try writer.writeAll("\x1b[0m");
        } else if (self.state.mode == .Search) {
            try writer.writeAll("\x1b[48;5;228m\x1b[30m"); // Light Yellow, Black text
            try writer.print("/{s}", .{self.state.search_buffer.items});
            var written: usize = 1 + self.state.search_buffer.items.len;
            if (self.state.search_system) |s| {
                if (s.matches.items.len > 0) {
                    var buf: [64]u8 = undefined;
                    const match_info = try std.fmt.bufPrint(&buf, " ({d}/{d})", .{ (s.active_match_idx orelse 0) + 1, s.matches.items.len });
                    try writer.writeAll(match_info);
                    written += match_info.len;
                } else {
                    const no_match = " (no matches)";
                    try writer.writeAll(no_match);
                    written += no_match.len;
                }
            }
            // Pad status bar
            if (self.width > written) {
                for (0..self.width - written) |_| {
                    try writer.writeAll(" ");
                }
            }
            try writer.writeAll("\x1b[0m"); // Reset
        } else if (self.state.mode == .GlobalSearch) {
            var status_buf: [160]u8 = undefined;
            const status_text = try self.buildStatusText(tab, &status_buf);
            try writer.writeAll("\x1b[48;5;228m\x1b[30m");
            try writer.writeAll(status_text);
            if (self.width > status_text.len) {
                for (0..self.width - status_text.len) |_| {
                    try writer.writeAll(" ");
                }
            }
            try writer.writeAll("\x1b[0m");
        } else if (self.state.error_message) |err_msg| {
            try writer.writeAll("\x1b[31;1m"); // Red, Bold
            try writer.print("{s}", .{err_msg});
            try writer.writeAll("\x1b[0m"); // Reset
        } else {
            const mode_color = if (self.state.mode == .Normal) "\x1b[48;5;121m\x1b[30m" else "\x1b[48;5;117m\x1b[30m";
            try writer.writeAll(mode_color);

            var status_buf: [160]u8 = undefined;
            const status_text = try self.buildStatusText(tab, &status_buf);

            try writer.writeAll(status_text);

            // Pad status bar
            if (self.width > status_text.len) {
                for (0..self.width - status_text.len) |_| {
                    try writer.writeAll(" ");
                }
            }
            try writer.writeAll("\x1b[0m"); // Reset
        }

        try self.renderCommandPopup(writer);
        try self.renderGlobalSearchPopup(writer);

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
            try terminal.moveCursor(writer, self.height, 2 + self.state.search_buffer.items.len);
        } else if (self.state.explorer_focused and self.state.explorer_visible and self.state.tree != null) {
            try terminal.moveCursor(writer, self.height, self.width);
        } else if (tab) |t| {
            // Offset cursor past the line-number gutter
            const content_width = buf_width -| gutter_width;

            // Draw all cursors
            for (t.cursors.items, 0..) |cursor, i| {
                const vis_col = if (cursor.col > content_width) content_width else cursor.col;
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
            const vis_col = if (mc.col > content_width) content_width else mc.col;
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

        self.renderVirtualTabs();

        if (ctx.tab) |t| {
            const highlight_start = perf.nowNs();
            self.prepareSyntaxForViewport(t, t.scroll_row, t.scroll_row + ctx.visible_rows, 20) catch {};
            metrics.add(.highlight_viewport, perf.elapsedNs(highlight_start));

            for (0..ctx.visible_rows) |screen_row| {
                const buffer_line_idx = screen_row + t.scroll_row;
                const row = screen_row + 2;
                if (buffer_line_idx >= t.buf.lines.items.len) continue;
                self.renderVirtualLine(t, buffer_line_idx, row, ctx.gutter_width);
            }
        }

        self.renderVirtualCommandPopup();
        self.renderVirtualGlobalSearchPopup();
        self.renderVirtualStatus(ctx);
        _ = try self.renderer.screen_renderer.emit(writer, &self.renderer.screen);
        try self.renderVirtualTabSeparator(writer);
        try self.moveVirtualCursor(writer, ctx.tab, ctx.gutter_width, ctx.visible_rows);
    }

    fn renderVirtualTabSeparator(self: *Editor, writer: anytype) !void {
        if (self.height < 2 or self.width == 0) return;
        try terminal.moveCursor(writer, 2, 1);
        try writer.writeAll("\x1b[2;37m");
        for (0..self.width) |_| try writer.writeAll("─");
        try writer.writeAll("\x1b[0m");
    }

    fn renderVirtualTabs(self: *Editor) void {
        if (self.height == 0 or self.width == 0) return;
        if (self.state.tabs.items.len == 0) {
            self.renderer.screen.fillRow(1, '-', .dim);
            return;
        }

        var col: usize = 0;
        const max_tab_width = 20;
        for (self.state.tabs.items, 0..) |tab, i| {
            if (col >= self.width) break;
            const is_active = i == self.state.active_tab_index;
            const filename = tab.buf.filename orelse "unsaved";
            const basename = std.fs.path.basename(filename);
            const style: render_mod.RenderStyle = if (is_active) .gutter_current else .dim;

            const prefix = if (is_active) "> " else "  ";
            self.renderer.screen.writeText(0, col, prefix, style);
            col += @min(prefix.len, self.width - col);

            const max_name = if (max_tab_width > 5) max_tab_width - 5 else max_tab_width;
            const name_len = @min(basename.len, max_name);
            self.renderer.screen.writeText(0, col, basename[0..name_len], style);
            col += @min(name_len, self.width - col);
            if (basename.len > name_len and col + 3 <= self.width) {
                self.renderer.screen.writeText(0, col, "...", style);
                col += 3;
            }
            if (col + 3 <= self.width) {
                self.renderer.screen.writeText(0, col, " | ", .dim);
                col += 3;
            }
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
            self.renderer.screen.writeText(geom.row, title_col, command_popup_title, .command_popup_title);
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

        self.renderer.screen.set(geom.row, geom.col, '+', .command_popup_border);
        for (1..geom.width - 1) |i| self.renderer.screen.set(geom.row, geom.col + i, '-', .command_popup_border);
        self.renderer.screen.set(geom.row, geom.col + geom.width - 1, '+', .command_popup_border);
        if (global_search_popup_title.len + 2 < geom.width) {
            self.renderer.screen.writeText(geom.row, title_col, global_search_popup_title, .command_popup_title);
        }

        const input_row = geom.row + 1;
        self.renderer.screen.set(input_row, geom.col, '|', .command_popup_border);
        self.renderer.screen.set(input_row, geom.col + geom.width - 1, '|', .command_popup_border);
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
            self.renderer.screen.set(row, geom.col, '|', .command_popup_border);
            self.renderer.screen.set(row, geom.col + geom.width - 1, '|', .command_popup_border);
            for (1..geom.width - 1) |col_offset| self.renderer.screen.set(row, geom.col + col_offset, ' ', style);
            self.renderVirtualGlobalSearchRowText(row, geom.col + 2, geom.col + geom.width - 1, render_row, popup.results.items, selected);
        }

        const bottom_row = geom.row + 2 + geom.suggestion_count;
        self.renderer.screen.set(bottom_row, geom.col, '+', .command_popup_border);
        for (1..geom.width - 1) |i| self.renderer.screen.set(bottom_row, geom.col + i, '-', .command_popup_border);
        self.renderer.screen.set(bottom_row, geom.col + geom.width - 1, '+', .command_popup_border);
    }

    fn renderVirtualLine(self: *Editor, tab: *Tab, buffer_line_idx: usize, row: usize, gutter_width: usize) void {
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

        var char_idx: usize = 0;
        var m_idx: usize = 0;
        while (char_idx < line_len and char_idx < content_width) : (char_idx += 1) {
            const ch = line.byteAt(char_idx) orelse ' ';
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

            self.renderer.screen.set(row, content_col + char_idx, ch, style);
        }
    }

    fn renderVirtualStatus(self: *Editor, ctx: RenderContext) void {
        if (self.height == 0) return;
        const row = self.height - 1;
        if (self.state.error_message != null) {
            self.renderer.screen.fillRow(row, ' ', .normal);
            self.renderer.screen.writeText(row, 0, ctx.status_text, .error_style);
            return;
        }

        self.renderer.screen.fillRow(row, ' ', ctx.status_style);
        self.renderer.screen.writeText(row, 0, ctx.status_text, ctx.status_style);
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
            try terminal.moveCursor(writer, self.height, 2 + self.state.search_buffer.items.len);
            return;
        }

        const t = tab orelse return;
        const content_width = self.width -| gutter_width;
        const mc = t.mainCursor();
        const vis_col = if (mc.col > content_width) content_width else mc.col;
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

        const explorer_width = if (self.state.explorer_visible) self.width / 5 else 0;
        const gutter_width = self.calculateGutterWidth(tab.buf.lines.items.len);

        // Relative row in viewport
        const rel_row = mc.row - tab.scroll_row;
        const col = explorer_width + gutter_width + mc.col + 1;

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

    // 1-99 lines => 2 digits min => 1 + 2 + 1 = 4
    try std.testing.expectEqual(@as(usize, 4), ed.calculateGutterWidth(5));
    try std.testing.expectEqual(@as(usize, 4), ed.calculateGutterWidth(99));

    // 100-999 lines => 3 digits => 1 + 3 + 1 = 5
    try std.testing.expectEqual(@as(usize, 5), ed.calculateGutterWidth(100));
    try std.testing.expectEqual(@as(usize, 5), ed.calculateGutterWidth(999));
}

test "Editor command mode status is yellow Command label" {
    const cfg = config.Config{};
    var ed = try Editor.init(std.testing.allocator, std.testing.io, cfg);
    defer ed.deinit();

    ed.state.mode = .Command;
    var status_buf: [160]u8 = undefined;
    const ctx = ed.buildRenderContext(&status_buf);

    try std.testing.expectEqual(render_mod.RenderStyle.status_command, ctx.status_style);
    try std.testing.expect(std.mem.indexOf(u8, ctx.status_text, "-- COMMAND --") != null);
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
        tab.mainCursor().selection_start = null;
    }

    {
        const tab = ed.currentTab().?;
        try tab.cursors.append(ed.allocator, .{ .row = 1, .col = 0 });
        const before = ed.captureCursorMoveState().?;
        try input.handleInput(&ed, ed.keys.move_right);
        try std.testing.expect(!ed.canFastRenderCursorMove(before));
        _ = tab.cursors.pop();
    }

    const rejection_cases = [_]struct {
        mode: EditorMode = .Normal,
        explorer_visible: bool = false,
        explorer_focused: bool = false,
        completion_active: bool = false,
        search_text: []const u8 = "",
    }{
        .{ .explorer_visible = true, .explorer_focused = true },
        .{ .completion_active = true },
        .{ .search_text = "needle" },
        .{ .mode = .Command },
        .{ .mode = .Search },
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
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Row: 2, Col: 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "alpha") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "beta") == null);
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

fn makeFastMoveTestEditor(allocator: std.mem.Allocator) !Editor {
    var ed = try Editor.init(allocator, std.testing.io, .{});
    errdefer ed.deinit();

    var buf = try buffer.Buffer.init(allocator);
    errdefer buf.deinit();
    var first = buf.lines.orderedRemove(0);
    first.deinit();

    const lines = [_][]const u8{ "alpha", "beta", "gamma", "delta" };
    for (lines) |line| {
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
