const std = @import("std");
const logz = @import("logz");
const config = @import("../config.zig");
const terminal = @import("../terminal.zig");
const buffer = @import("buffer.zig");
const dashboard = @import("dashboard.zig");
const explorer = @import("explorer.zig");
const input = @import("input.zig");
const search = @import("search.zig");
const syntax = @import("syntax.zig");
const syntax_worker = @import("syntax_worker.zig");
const perf = @import("../perf/perf.zig");
const render_mod = @import("render.zig");
const lsp_manager = @import("../lsp/manager.zig");
const event_queue = @import("event_queue.zig");

pub const EditorMode = enum {
    Dashboard,
    Normal,
    Insert,
    Command,
    OpenFilePrompt,
    Search,
};

pub const Pos = struct {
    row: usize,
    col: usize,
};

pub const Cursor = struct {
    row: usize = 0,
    col: usize = 0,
    selection_start: ?Pos = null,
};

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

pub const Tab = struct {
    buf: buffer.Buffer,
    cursors: std.ArrayListUnmanaged(Cursor),
    syntax_highlighter: syntax.Highlighter,
    syntax_buffer_id: u64,
    syntax_requested_revision: ?u64 = null,
    main_cursor_idx: usize = 0,
    scroll_row: usize = 0,
    lsp_notified_revision: ?u64 = null,
    lsp_pending_since_ns: ?u64 = null,

    pub fn deinit(self: *Tab, allocator: std.mem.Allocator) void {
        self.syntax_highlighter.deinit();
        self.buf.deinit();
        self.cursors.deinit(allocator);
    }

    pub fn mainCursor(self: *Tab) *Cursor {
        return &self.cursors.items[self.main_cursor_idx];
    }

    pub fn needsLspChangeNotification(self: *const Tab) bool {
        return self.buf.is_dirty and self.buf.filename != null and self.lsp_notified_revision != self.buf.revision;
    }

    pub fn markLspChangeNotified(self: *Tab) void {
        self.lsp_notified_revision = self.buf.revision;
        self.lsp_pending_since_ns = null;
    }
};

pub const ResolvedKeybindings = struct {
    new_file: terminal.KeyEvent,
    open_file: terminal.KeyEvent,
    open_folder: terminal.KeyEvent,
    settings: terminal.KeyEvent,
    quit: terminal.KeyEvent,
    toggle_explorer: terminal.KeyEvent,
    switch_focus: terminal.KeyEvent,
    close_tab: terminal.KeyEvent,
    next_tab: terminal.KeyEvent,
    previous_tab: terminal.KeyEvent,
    dashboard_up: terminal.KeyEvent,
    dashboard_down: terminal.KeyEvent,
    dashboard_select: terminal.KeyEvent,
    explorer_up: terminal.KeyEvent,
    explorer_down: terminal.KeyEvent,
    explorer_open: terminal.KeyEvent,
    insert_mode: terminal.KeyEvent,
    command_mode: terminal.KeyEvent,
    search_mode: terminal.KeyEvent,
    normal_mode: terminal.KeyEvent,
    insert_newline: terminal.KeyEvent,
    delete_back: terminal.KeyEvent,
    delete_word_back: terminal.KeyEvent,
    indent: terminal.KeyEvent,
    prompt_submit: terminal.KeyEvent,
    prompt_backspace: terminal.KeyEvent,
    save: terminal.KeyEvent,
    undo: terminal.KeyEvent,
    redo: terminal.KeyEvent,
    select_all: terminal.KeyEvent,
    copy: terminal.KeyEvent,
    cut: terminal.KeyEvent,
    paste: terminal.KeyEvent,
    duplicate_line: terminal.KeyEvent,
    delete_line: terminal.KeyEvent,
    add_cursor_above: terminal.KeyEvent,
    add_cursor_below: terminal.KeyEvent,
    move_up: terminal.KeyEvent,
    move_down: terminal.KeyEvent,
    move_left: terminal.KeyEvent,
    move_right: terminal.KeyEvent,
    line_start: terminal.KeyEvent,
    line_end: terminal.KeyEvent,
    word_left: terminal.KeyEvent,
    word_right: terminal.KeyEvent,
    search_next: terminal.KeyEvent,
    search_previous: terminal.KeyEvent,
    completion_auto_trigger: terminal.KeyEvent,
    completion_trigger: terminal.KeyEvent,
    completion_next: terminal.KeyEvent,
    completion_previous: terminal.KeyEvent,
    completion_accept: terminal.KeyEvent,
    completion_cancel: terminal.KeyEvent,

    pub fn init(keys: config.KeybindingsConfig) ResolvedKeybindings {
        return .{
            .new_file = terminal.parseKeyChord(keys.new_file),
            .open_file = terminal.parseKeyChord(keys.open_file),
            .open_folder = terminal.parseKeyChord(keys.open_folder),
            .settings = terminal.parseKeyChord(keys.settings),
            .quit = terminal.parseKeyChord(keys.quit),
            .toggle_explorer = terminal.parseKeyChord(keys.toggle_explorer),
            .switch_focus = terminal.parseKeyChord(keys.switch_focus),
            .close_tab = terminal.parseKeyChord(keys.close_tab),
            .next_tab = terminal.parseKeyChord(keys.next_tab),
            .previous_tab = terminal.parseKeyChord(keys.previous_tab),
            .dashboard_up = terminal.parseKeyChord(keys.dashboard_up),
            .dashboard_down = terminal.parseKeyChord(keys.dashboard_down),
            .dashboard_select = terminal.parseKeyChord(keys.dashboard_select),
            .explorer_up = terminal.parseKeyChord(keys.explorer_up),
            .explorer_down = terminal.parseKeyChord(keys.explorer_down),
            .explorer_open = terminal.parseKeyChord(keys.explorer_open),
            .insert_mode = terminal.parseKeyChord(keys.insert_mode),
            .command_mode = terminal.parseKeyChord(keys.command_mode),
            .search_mode = terminal.parseKeyChord(keys.search_mode),
            .normal_mode = terminal.parseKeyChord(keys.normal_mode),
            .insert_newline = terminal.parseKeyChord(keys.insert_newline),
            .delete_back = terminal.parseKeyChord(keys.delete_back),
            .delete_word_back = terminal.parseKeyChord(keys.delete_word_back),
            .indent = terminal.parseKeyChord(keys.indent),
            .prompt_submit = terminal.parseKeyChord(keys.prompt_submit),
            .prompt_backspace = terminal.parseKeyChord(keys.prompt_backspace),
            .save = terminal.parseKeyChord(keys.save),
            .undo = terminal.parseKeyChord(keys.undo),
            .redo = terminal.parseKeyChord(keys.redo),
            .select_all = terminal.parseKeyChord(keys.select_all),
            .copy = terminal.parseKeyChord(keys.copy),
            .cut = terminal.parseKeyChord(keys.cut),
            .paste = terminal.parseKeyChord(keys.paste),
            .duplicate_line = terminal.parseKeyChord(keys.duplicate_line),
            .delete_line = terminal.parseKeyChord(keys.delete_line),
            .add_cursor_above = terminal.parseKeyChord(keys.add_cursor_above),
            .add_cursor_below = terminal.parseKeyChord(keys.add_cursor_below),
            .move_up = terminal.parseKeyChord(keys.move_up),
            .move_down = terminal.parseKeyChord(keys.move_down),
            .move_left = terminal.parseKeyChord(keys.move_left),
            .move_right = terminal.parseKeyChord(keys.move_right),
            .line_start = terminal.parseKeyChord(keys.line_start),
            .line_end = terminal.parseKeyChord(keys.line_end),
            .word_left = terminal.parseKeyChord(keys.word_left),
            .word_right = terminal.parseKeyChord(keys.word_right),
            .search_next = terminal.parseKeyChord(keys.search_next),
            .search_previous = terminal.parseKeyChord(keys.search_previous),
            .completion_auto_trigger = terminal.parseKeyChord(keys.completion_auto_trigger),
            .completion_trigger = terminal.parseKeyChord(keys.completion_trigger),
            .completion_next = terminal.parseKeyChord(keys.completion_next),
            .completion_previous = terminal.parseKeyChord(keys.completion_previous),
            .completion_accept = terminal.parseKeyChord(keys.completion_accept),
            .completion_cancel = terminal.parseKeyChord(keys.completion_cancel),
        };
    }
};

pub const Editor = struct {
    config: config.Config,
    keys: ResolvedKeybindings,
    allocator: std.mem.Allocator,
    io: std.Io,
    mode: EditorMode = .Dashboard,
    dash: dashboard.Dashboard = .{},
    tabs: std.ArrayList(Tab),
    active_tab_index: usize = 0,
    command_buffer: std.ArrayListUnmanaged(u8) = .empty,
    error_message: ?[]const u8 = null,
    width: usize = 0,
    height: usize = 0,
    should_quit: bool = false,
    tree: ?explorer.Explorer = null,
    explorer_visible: bool = false,
    explorer_focused: bool = false,
    search_buffer: std.ArrayListUnmanaged(u8) = .empty,
    search_system: ?search.SearchSystem = null,
    clipboard: ?[]u8 = null,
    event_queue: *event_queue.EventQueue,
    syntax_parse_worker: *syntax_worker.SyntaxParseWorker,
    lsp_mgr: ?lsp_manager.LspManager = null,
    is_deinitialized: bool = false,
    fps_sample_start_ns: ?i96 = null,
    fps_frame_count: usize = 0,
    fps: u32 = 0,
    render_dirty: bool = true,
    force_full_render: bool = true,
    perf_sampler: perf.PerfSampler = .{},
    legacy_frame: std.ArrayListUnmanaged(u8) = .empty,
    screen: render_mod.VirtualScreen,
    screen_renderer: render_mod.VirtualScreenRenderer,
    next_syntax_buffer_id: u64 = 1,

    // Completion state
    completion_items: ?std.json.Value = null,
    completion_active: bool = false,
    completion_selected: usize = 0,

    diagnostics: std.StringHashMap(std.json.Value),

    pub fn init(allocator: std.mem.Allocator, io: std.Io, cfg: config.Config) !Editor {
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

        return Editor{
            .allocator = allocator,
            .io = io,
            .config = cfg,
            .keys = ResolvedKeybindings.init(cfg.keybindings),
            .tabs = std.ArrayList(Tab).empty,
            .search_system = search.SearchSystem.init(allocator),
            .event_queue = queue,
            .syntax_parse_worker = parser_worker,
            .lsp_mgr = mgr,
            .diagnostics = std.StringHashMap(std.json.Value).init(allocator),
            .perf_sampler = perf.PerfSampler.initFromEnv(),
            .screen = render_mod.VirtualScreen.init(allocator),
            .screen_renderer = render_mod.VirtualScreenRenderer.init(allocator),
        };
    }

    pub fn deinit(self: *Editor) void {
        if (self.is_deinitialized) return;
        self.is_deinitialized = true;

        self.syntax_parse_worker.stop();

        for (self.tabs.items) |*tab| {
            tab.deinit(self.allocator);
        }
        self.tabs.deinit(self.allocator);
        self.tabs = std.ArrayList(Tab).empty;

        if (self.tree) |*t| {
            t.deinit();
            self.tree = null;
        }
        if (self.search_system) |*s| {
            s.deinit();
            self.search_system = null;
        }
        self.command_buffer.deinit(self.allocator);
        self.command_buffer = .empty;
        self.legacy_frame.deinit(self.allocator);
        self.legacy_frame = .empty;
        self.screen.deinit();
        self.screen_renderer.deinit();
        self.search_buffer.deinit(self.allocator);
        self.search_buffer = .empty;
        if (self.clipboard) |c| {
            self.allocator.free(c);
            self.clipboard = null;
        }

        if (self.lsp_mgr) |*mgr| {
            if (self.completion_items) |items| {
                mgr.freeValue(items);
                self.completion_items = null;
            }

            var it = self.diagnostics.iterator();
            while (it.next()) |entry| {
                mgr.freeValue(entry.value_ptr.*);
                self.allocator.free(entry.key_ptr.*);
            }
            self.diagnostics.deinit();
            mgr.deinit();
            self.lsp_mgr = null;
        } else {
            self.diagnostics.deinit();
        }
        self.event_queue.quit = true;
        self.event_queue.deinit();
        self.allocator.destroy(self.event_queue);
    }

    pub fn currentTab(self: *Editor) ?*Tab {
        if (self.tabs.items.len == 0) return null;
        return &self.tabs.items[self.active_tab_index];
    }

    pub fn refreshKeybindings(self: *Editor) void {
        self.keys = ResolvedKeybindings.init(self.config.keybindings);
    }

    pub fn addTab(self: *Editor, buf: buffer.Buffer) !void {
        if (buf.filename) |new_filename| {
            for (self.tabs.items, 0..) |*tab, i| {
                if (tab.buf.filename) |existing_filename| {
                    if (std.mem.eql(u8, existing_filename, new_filename)) {
                        var duplicate = buf;
                        duplicate.deinit();
                        self.active_tab_index = i;
                        return;
                    }
                }
            }
        }

        var cursors = std.ArrayListUnmanaged(Cursor).empty;
        try cursors.append(self.allocator, .{});
        const syntax_buffer_id = self.next_syntax_buffer_id;
        self.next_syntax_buffer_id +%= 1;
        try self.tabs.append(self.allocator, .{
            .buf = buf,
            .cursors = cursors,
            .syntax_highlighter = syntax.Highlighter.init(self.allocator),
            .syntax_buffer_id = syntax_buffer_id,
            .lsp_notified_revision = if (buf.filename != null) buf.revision else null,
        });
        self.active_tab_index = self.tabs.items.len - 1;
        self.markDirty(.full);

        if (self.lsp_mgr) |*mgr| {
            if (buf.filename) |fname| {
                mgr.startLspForFile(fname) catch |err| {
                    logz.err().fmt("msg", "Failed to start LSP: {any}", .{err}).log();
                };

                const content = try buf.toString(self.allocator);
                defer self.allocator.free(content);

                mgr.notifyOpen(fname, content) catch |err| {
                    logz.err().fmt("msg", "Failed to notify open: {any}", .{err}).log();
                };
            }
        }
    }

    pub fn closeTab(self: *Editor) void {
        if (self.tabs.items.len == 0) return;
        var tab = self.tabs.orderedRemove(self.active_tab_index);
        tab.deinit(self.allocator);

        if (self.tabs.items.len == 0) {
            self.mode = .Dashboard;
            self.active_tab_index = 0;
            self.explorer_visible = false;
            self.explorer_focused = false;
        } else {
            if (self.active_tab_index >= self.tabs.items.len) {
                self.active_tab_index = self.tabs.items.len - 1;
            }
        }
        self.markDirty(.full);
    }

    pub fn nextTab(self: *Editor) void {
        if (self.tabs.items.len <= 1) return;
        self.active_tab_index = (self.active_tab_index + 1) % self.tabs.items.len;
        self.markDirty(.full);
    }

    pub fn prevTab(self: *Editor) void {
        if (self.tabs.items.len <= 1) return;
        if (self.active_tab_index == 0) {
            self.active_tab_index = self.tabs.items.len - 1;
        } else {
            self.active_tab_index -= 1;
        }
        self.markDirty(.full);
    }

    pub fn closeAllTabs(self: *Editor) void {
        for (self.tabs.items) |*tab| {
            tab.deinit(self.allocator);
        }
        self.tabs.clearRetainingCapacity();
        self.active_tab_index = 0;
        self.mode = .Dashboard;
        self.explorer_visible = false;
        self.explorer_focused = false;
        self.markDirty(.full);
    }

    pub fn markDirty(self: *Editor, invalidation: render_mod.RenderInvalidation) void {
        self.render_dirty = true;
        if (invalidation == .full) {
            self.force_full_render = true;
        }
        self.screen_renderer.invalidate(invalidation);
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
        self.render_dirty = false;
        self.force_full_render = true;
        self.screen_renderer.invalidate(.full);
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

    fn updateFps(self: *Editor) void {
        const now = std.Io.Timestamp.now(self.io, .awake).nanoseconds;

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

    fn updateFrameCapacityFps(self: *Editor, frame_ns: u64) void {
        if (frame_ns == 0) return;
        const fps = std.time.ns_per_s / frame_ns;
        self.fps = @intCast(@min(fps, 999));
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

            // Pump events
            const events_start = perf.nowNs();
            while (self.event_queue.tryPop()) |ev| {
                var event = ev;
                switch (event) {
                    .lsp_message => |msg| {
                        defer self.allocator.free(msg.message);
                        if (self.lsp_mgr) |*mgr| {
                            const res = mgr.handleMessage(msg.plugin_name, msg.message) catch |err| blk: {
                                logz.err().fmt("msg", "Error handling LSP msg: {any}", .{err}).log();
                                break :blk lsp_manager.LspManager.HandleResult.none;
                            };

                            switch (res) {
                                .initialized => {
                                    for (self.tabs.items) |tab| {
                                        if (tab.buf.filename) |fname| {
                                            const ext = std.fs.path.extension(fname);
                                            if (mgr.plugin_mgr.getPluginForExtension(ext)) |p| {
                                                if (std.mem.eql(u8, p.name, msg.plugin_name)) {
                                                    const content = try tab.buf.toString(self.allocator);
                                                    defer self.allocator.free(content);
                                                    mgr.notifyOpen(fname, content) catch {};
                                                }
                                            }
                                        }
                                    }
                                },
                                .completion => |items| {
                                    if (self.completion_items) |old| {
                                        mgr.freeValue(old);
                                    }
                                    self.completion_items = items;
                                    self.completion_active = true;
                                    self.completion_selected = 0;
                                    self.markDirty(.partial);
                                },
                                .diagnostics => |diag_val| {
                                    var diagnostics_stored = false;
                                    errdefer if (!diagnostics_stored) mgr.freeValue(diag_val);

                                    const uri = diag_val.object.get("uri").?.string;
                                    // filename is after file://
                                    const fname = if (std.mem.startsWith(u8, uri, "file://")) uri[7..] else uri;

                                    const fname_copy = try self.allocator.dupe(u8, fname);
                                    var key_owned = true;
                                    errdefer if (key_owned) self.allocator.free(fname_copy);

                                    const entry = try self.diagnostics.getOrPut(fname_copy);
                                    if (entry.found_existing) {
                                        mgr.freeValue(entry.value_ptr.*);
                                        self.allocator.free(fname_copy);
                                        key_owned = false;
                                    } else {
                                        key_owned = false;
                                    }

                                    entry.value_ptr.* = diag_val;
                                    diagnostics_stored = true;
                                    self.markDirty(.partial);
                                },
                                .none => {},
                            }
                        }
                    },
                    .syntax_parse_result => |*result| {
                        defer result.deinit(self.allocator);
                        self.handleSyntaxParseResult(result) catch |err| {
                            logz.err().fmt("msg", "failed to install syntax parse result: {any}", .{err}).log();
                        };
                    },
                }
            }
            metrics.add(.event_processing, perf.elapsedNs(events_start));

            const input_start = perf.nowNs();
            var handled_input = false;
            var input_count: usize = 0;
            while (input_count < 128) : (input_count += 1) {
                const event = try terminal.readKey(reader);
                if (event.key == .None) break;
                handled_input = true;

                const render_after_event = self.shouldRenderAfterInputEvent(event);
                const cursor_move_before = if (render_after_event) self.captureCursorMoveState() else null;
                const input_handle_start = perf.nowNs();
                try self.handleRuntimeKey(event);
                metrics.add(.update_state, perf.elapsedNs(input_handle_start));

                if (render_after_event) {
                    if (cursor_move_before) |before| {
                        if (self.canFastRenderCursorMove(before)) {
                            aw.clearRetainingCapacity();
                            const frame_start = perf.nowNs();
                            try terminal.hideCursor(writer);
                            try self.renderFastCursorMove(writer, before);
                            try terminal.showCursor(writer);
                            metrics.add(.build_frame, perf.elapsedNs(frame_start));

                            const flush_start = perf.nowNs();
                            const bytes = aw.written().len;
                            try raw_writer.writeAll(aw.written());
                            metrics.add(.flush_output, perf.elapsedNs(flush_start));
                            self.updateFrameCapacityFps(metrics.get(.build_frame) + metrics.get(.flush_output));
                            metrics.rendered = true;
                            metrics.fast_cursor_move = true;
                            metrics.bytes_emitted = bytes;
                            self.render_dirty = false;
                            self.force_full_render = true;
                            self.screen_renderer.invalidate(.full);
                            break;
                        }
                    }
                }

                if (self.should_quit) break;
                if (render_after_event and self.render_dirty) break;
            }
            metrics.add(.input_poll, perf.elapsedNs(input_start));

            if (!handled_input) {
                const update_start = perf.nowNs();
                try self.flushPendingLspChanges(false);
                metrics.add(.update_state, perf.elapsedNs(update_start));
            }

            if (self.render_dirty) {
                aw.clearRetainingCapacity();

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

                const flush_start = perf.nowNs();
                const bytes = aw.written().len;
                try raw_writer.writeAll(aw.written());
                metrics.add(.flush_output, perf.elapsedNs(flush_start));
                self.updateFrameCapacityFps(metrics.get(.build_frame) + metrics.get(.flush_output));
                metrics.rendered = true;
                metrics.bytes_emitted = bytes;
                self.render_dirty = false;
                self.force_full_render = false;
            }

            if (!handled_input) {
                const syntax_request_start = perf.nowNs();
                try self.queueSyntaxParseForCurrentTab();
                metrics.add(.update_state, perf.elapsedNs(syntax_request_start));
            }

            metrics.add(.total_loop, perf.elapsedNs(loop_start));
            self.perf_sampler.observe(metrics);

            if (!self.render_dirty and !handled_input) {
                perf.sleepNs(1 * std.time.ns_per_ms);
            }
        }

        try self.flushPendingLspChanges(true);
        self.perf_sampler.flush();
        aw.clearRetainingCapacity();
        try terminal.clearScreen(writer);
        try terminal.moveCursor(writer, 1, 1);
        try raw_writer.writeAll(aw.written());
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
            .mode = self.mode,
            .cursor_count = tab.cursors.items.len,
            .had_selection = mc.selection_start != null,
            .active_tab_index = self.active_tab_index,
            .tab_count = self.tabs.items.len,
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

        if (self.explorer_visible and self.tree != null) {
            const exp_width = (self.width * @as(usize, self.config.explorer.width_percentage)) / 100;
            if (exp_width > 0) {
                buf_start_col = exp_width + 2;
                buf_width = self.width -| (exp_width + 1);
            }
        }

        return .{ .start_col = buf_start_col, .width = buf_width };
    }

    fn canFastRenderCursorMove(self: *Editor, before: CursorMoveState) bool {
        if (before.mode != .Normal and before.mode != .Insert) return false;
        if (self.mode != .Normal and self.mode != .Insert) return false;
        if (before.cursor_count != 1) return false;
        if (before.had_selection) return false;
        if (self.tabs.items.len != before.tab_count) return false;
        if (self.active_tab_index != before.active_tab_index) return false;
        if (self.width != before.width or self.height != before.height) return false;
        if (self.explorer_focused) return false;
        if (self.tree) |tree| {
            if (tree.search_active) return false;
        }
        if (self.completion_active) return false;
        if (self.search_buffer.items.len > 0) return false;

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

        if (self.error_message) |err_msg| {
            try writer.writeAll("\x1b[31;1m");
            try writer.print("{s}", .{err_msg});
            try writer.writeAll("\x1b[0m");
            return;
        }

        const mode_color = if (self.mode == .Normal) "\x1b[48;5;121m\x1b[30m" else "\x1b[48;5;117m\x1b[30m";
        try writer.writeAll(mode_color);

        const mode_str = if (self.mode == .Normal) "-- NORMAL --" else "-- INSERT --";
        var buf: [160]u8 = undefined;
        const status_text = if (tab) |t| blk: {
            var diag_count: usize = 0;
            if (t.buf.filename) |fname| {
                if (self.diagnostics.get(fname)) |dv| {
                    diag_count = dv.object.get("diagnostics").?.array.items.len;
                }
            }

            if (diag_count > 0) {
                break :blk try std.fmt.bufPrint(&buf, " {s} | Row: {d}, Col: {d} | Cursors: {d} | ERR: {d} | FPS: {d} ", .{ mode_str, t.mainCursor().row + 1, t.mainCursor().col + 1, t.cursors.items.len, diag_count, self.fps });
            }
            break :blk try std.fmt.bufPrint(&buf, " {s} | Row: {d}, Col: {d} | Cursors: {d} | FPS: {d} ", .{ mode_str, t.mainCursor().row + 1, t.mainCursor().col + 1, t.cursors.items.len, self.fps });
        } else try std.fmt.bufPrint(&buf, " {s} | No file open | FPS: {d} ", .{ mode_str, self.fps });

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

        if (self.completion_active) {
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
                    if (self.lsp_mgr) |*mgr| {
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
        for (self.tabs.items) |*tab| {
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

    fn queueSyntaxParseForCurrentTab(self: *Editor) !void {
        const tab = self.currentTab() orelse return;
        const language = try tab.syntax_highlighter.prepareForAsyncBuffer(&tab.buf) orelse {
            tab.syntax_requested_revision = null;
            return;
        };

        if (tab.syntax_highlighter.parsed_revision != tab.buf.revision and
            tab.syntax_requested_revision != tab.buf.revision)
        {
            const source = try tab.buf.toString(self.allocator);
            const revision = tab.buf.revision;
            tab.syntax_requested_revision = revision;
            self.syntax_parse_worker.requestParse(tab.syntax_buffer_id, revision, language, source);
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

        if (self.lsp_mgr) |*mgr| {
            const content = try tab.buf.toString(self.allocator);
            defer self.allocator.free(content);
            if (mgr.notifyChange(tab.buf.filename.?, content)) {
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

        if (self.tabs.items.len == 0) return;

        const max_tab_width = 20;
        var current_col: usize = 1;

        for (self.tabs.items, 0..) |tab, i| {
            const is_active = (i == self.active_tab_index);
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

    fn render(self: *Editor, writer: anytype) !void {
        if (self.mode == .Dashboard or self.mode == .OpenFilePrompt) {
            try self.dash.render(writer, self.width, self.height);

            if (self.mode == .OpenFilePrompt) {
                try terminal.moveCursor(writer, self.height, 1);
                try terminal.clearLine(writer);
                try writer.print("Open file: {s}", .{self.command_buffer.items});
                try terminal.moveCursor(writer, self.height, 12 + self.command_buffer.items.len);
            } else if (self.error_message) |err_msg| {
                try terminal.moveCursor(writer, self.height, 1);
                try terminal.clearLine(writer);
                try writer.writeAll("\x1b[31;1m"); // Red, Bold
                try writer.print("{s}", .{err_msg});
                try writer.writeAll("\x1b[0m"); // Reset
            }
            return;
        }

        if (self.search_system == null) {
            self.search_system = search.SearchSystem.init(self.allocator);
        }

        var buf_start_col: usize = 1;
        var buf_width: usize = self.width;

        // Move to top-left (row 2, because of tabs) WITHOUT blanking the screen — eliminates flicker.
        // Each line erases its own tail via \x1b[K; leftover rows cleared below with \x1b[J.
        try terminal.moveHome(writer);

        if (self.explorer_visible and self.tree != null) {
            const exp_width = (self.width * @as(usize, self.config.explorer.width_percentage)) / 100;
            if (exp_width > 0) {
                // Explorer starts at row 2
                try self.tree.?.renderAt(writer, exp_width, self.height - 1, 2, self.explorer_focused);

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

                    var match_indices: ?[]const usize = null;
                    var is_active_line = false;
                    if (self.search_buffer.items.len > 0) {
                        for (self.search_system.?.matches.items) |m| {
                            if (m.row == buffer_line_idx) {
                                match_indices = m.indices;
                                if (self.search_system.?.active_match_idx) |idx| {
                                    if (self.search_system.?.matches.items[idx].row == buffer_line_idx) {
                                        is_active_line = true;
                                    }
                                }
                                break;
                            }
                        }
                    }

                    var char_idx: usize = 0;
                    var m_idx: usize = 0;
                    while (char_idx < line_len and char_idx < content_width) : (char_idx += 1) {
                        var in_selection = false;
                        for (t.cursors.items) |cursor| {
                            if (cursor.selection_start) |ss| {
                                const s_row = @min(ss.row, cursor.row);
                                const e_row = @max(ss.row, cursor.row);
                                const s_col = if (ss.row < cursor.row) ss.col else if (ss.row > cursor.row) cursor.col else @min(ss.col, cursor.col);
                                const e_col = if (ss.row < cursor.row) cursor.col else if (ss.row > cursor.row) ss.col else @max(ss.col, cursor.col);

                                if (buffer_line_idx > s_row and buffer_line_idx < e_row) {
                                    in_selection = true;
                                } else if (buffer_line_idx == s_row and buffer_line_idx == e_row) {
                                    if (char_idx >= s_col and char_idx < e_col) in_selection = true;
                                } else if (buffer_line_idx == s_row) {
                                    if (char_idx >= s_col) in_selection = true;
                                } else if (buffer_line_idx == e_row) {
                                    if (char_idx < e_col) in_selection = true;
                                }
                            }
                        }

                        if (t.syntax_highlighter.styleAtLine(buffer_line_idx, char_idx)) |style| {
                            try writer.writeAll(style.ansi());
                        }

                        if (in_selection) {
                            try writer.writeAll("\x1b[48;5;239m"); // Dark grey selection
                        }

                        const is_match = if (match_indices) |indices| (if (m_idx < indices.len and indices[m_idx] == char_idx) true else false) else false;
                        if (is_match) {
                            if (is_active_line and self.search_system.?.getActiveMatch().?.col == char_idx) {
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

        if (self.mode == .Command) {
            try writer.print(":{s}", .{self.command_buffer.items});
        } else if (self.mode == .Search) {
            try writer.writeAll("\x1b[48;5;228m\x1b[30m"); // Light Yellow, Black text
            try writer.print("/{s}", .{self.search_buffer.items});
            var written: usize = 1 + self.search_buffer.items.len;
            if (self.search_system) |s| {
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
        } else if (self.error_message) |err_msg| {
            try writer.writeAll("\x1b[31;1m"); // Red, Bold
            try writer.print("{s}", .{err_msg});
            try writer.writeAll("\x1b[0m"); // Reset
        } else {
            const mode_color = if (self.mode == .Normal) "\x1b[48;5;121m\x1b[30m" else "\x1b[48;5;117m\x1b[30m";
            try writer.writeAll(mode_color);

            const mode_str = if (self.mode == .Normal) "-- NORMAL --" else "-- INSERT --";

            var buf: [128]u8 = undefined;
            const status_text = if (tab) |t| blk: {
                var diag_count: usize = 0;
                if (t.buf.filename) |fname| {
                    if (self.diagnostics.get(fname)) |dv| {
                        diag_count = dv.object.get("diagnostics").?.array.items.len;
                    }
                }

                if (diag_count > 0) {
                    break :blk try std.fmt.bufPrint(&buf, " {s} | Row: {d}, Col: {d} | Cursors: {d} | ERR: {d} | FPS: {d} ", .{ mode_str, t.mainCursor().row + 1, t.mainCursor().col + 1, t.cursors.items.len, diag_count, self.fps });
                } else {
                    break :blk try std.fmt.bufPrint(&buf, " {s} | Row: {d}, Col: {d} | Cursors: {d} | FPS: {d} ", .{ mode_str, t.mainCursor().row + 1, t.mainCursor().col + 1, t.cursors.items.len, self.fps });
                }
            } else try std.fmt.bufPrint(&buf, " {s} | No file open | FPS: {d} ", .{ mode_str, self.fps });

            try writer.writeAll(status_text);

            // Pad status bar
            if (self.width > status_text.len) {
                for (0..self.width - status_text.len) |_| {
                    try writer.writeAll(" ");
                }
            }
            try writer.writeAll("\x1b[0m"); // Reset
        }

        // Move cursor to proper location
        if (self.mode == .Command) {
            try terminal.moveCursor(writer, self.height, 2 + self.command_buffer.items.len);
        } else if (self.mode == .Search) {
            try terminal.moveCursor(writer, self.height, 2 + self.search_buffer.items.len);
        } else if (self.explorer_focused and self.explorer_visible and self.tree != null) {
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
        return @max(buffer.countDigits(total_lines), 2) + 2;
    }

    fn canUseVirtualRenderer(self: *const Editor) bool {
        if (self.search_buffer.items.len > 0) return false;
        if (self.tabs.items.len > 0) {
            const tab = &self.tabs.items[self.active_tab_index];
            for (tab.cursors.items) |cursor| {
                if (cursor.selection_start != null) return false;
            }
        }
        return self.mode != .Dashboard and
            self.mode != .OpenFilePrompt and
            !self.explorer_visible and
            !self.completion_active;
    }

    fn renderVirtual(self: *Editor, writer: anytype, metrics: *perf.FrameMetrics) !void {
        if (try self.screen.resize(self.width, self.height)) {
            self.screen_renderer.invalidate(.full);
        }
        self.screen.clear();

        const tab = self.currentTab();
        const gutter_width: usize = if (tab) |t|
            self.calculateGutterWidth(t.buf.lines.items.len)
        else
            0;

        self.renderVirtualTabs();

        const top_reserved = 2;
        const bot_reserved = 1;
        const visible_rows = if (self.height > top_reserved + bot_reserved) self.height - (top_reserved + bot_reserved) else 0;
        if (tab) |t| {
            const highlight_start = perf.nowNs();
            self.prepareSyntaxForViewport(t, t.scroll_row, t.scroll_row + visible_rows, 20) catch {};
            metrics.add(.highlight_viewport, perf.elapsedNs(highlight_start));

            for (0..visible_rows) |screen_row| {
                const buffer_line_idx = screen_row + t.scroll_row;
                const row = screen_row + 2;
                if (buffer_line_idx >= t.buf.lines.items.len) continue;
                self.renderVirtualLine(t, buffer_line_idx, row, gutter_width);
            }
        }

        self.renderVirtualStatus(tab);
        _ = try self.screen_renderer.emit(writer, &self.screen);
        try self.renderVirtualTabSeparator(writer);
        try self.moveVirtualCursor(writer, tab, gutter_width, visible_rows);
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
        if (self.tabs.items.len == 0) {
            self.screen.fillRow(1, '-', .dim);
            return;
        }

        var col: usize = 0;
        const max_tab_width = 20;
        for (self.tabs.items, 0..) |tab, i| {
            if (col >= self.width) break;
            const is_active = i == self.active_tab_index;
            const filename = tab.buf.filename orelse "unsaved";
            const basename = std.fs.path.basename(filename);
            const style: render_mod.RenderStyle = if (is_active) .gutter_current else .dim;

            const prefix = if (is_active) "> " else "  ";
            self.screen.writeText(0, col, prefix, style);
            col += @min(prefix.len, self.width - col);

            const max_name = if (max_tab_width > 5) max_tab_width - 5 else max_tab_width;
            const name_len = @min(basename.len, max_name);
            self.screen.writeText(0, col, basename[0..name_len], style);
            col += @min(name_len, self.width - col);
            if (basename.len > name_len and col + 3 <= self.width) {
                self.screen.writeText(0, col, "...", style);
                col += 3;
            }
            if (col + 3 <= self.width) {
                self.screen.writeText(0, col, " | ", .dim);
                col += 3;
            }
        }

        self.screen.fillRow(1, '-', .dim);
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
        self.screen.writeText(row, gutter_col, gutter, if (is_current) .gutter_current else .dim);

        const content_col = gutter_width;
        const content_width = self.width -| content_col;
        const line = tab.buf.lines.items[buffer_line_idx];
        const line_len = line.len();

        var match_indices: ?[]const usize = null;
        var is_active_line = false;
        if (self.search_buffer.items.len > 0) {
            if (self.search_system) |s| {
                for (s.matches.items) |m| {
                    if (m.row == buffer_line_idx) {
                        match_indices = m.indices;
                        if (s.active_match_idx) |idx| {
                            is_active_line = s.matches.items[idx].row == buffer_line_idx;
                        }
                        break;
                    }
                }
            }
        }

        var char_idx: usize = 0;
        var m_idx: usize = 0;
        while (char_idx < line_len and char_idx < content_width) : (char_idx += 1) {
            const ch = line.byteAt(char_idx) orelse ' ';
            var style: render_mod.RenderStyle = if (tab.syntax_highlighter.styleAtLine(buffer_line_idx, char_idx)) |syntax_style|
                renderStyleFromSyntax(syntax_style)
            else
                .normal;

            if (self.isSelected(tab, buffer_line_idx, char_idx)) {
                style = .selection;
            }

            const is_match = if (match_indices) |indices| m_idx < indices.len and indices[m_idx] == char_idx else false;
            if (is_match) {
                if (is_active_line and self.search_system.?.getActiveMatch().?.col == char_idx) {
                    style = .search_active;
                } else {
                    style = .search_match;
                }
                m_idx += 1;
            }

            self.screen.set(row, content_col + char_idx, ch, style);
        }
    }

    fn renderVirtualStatus(self: *Editor, tab: ?*Tab) void {
        if (self.height == 0) return;
        const row = self.height - 1;
        const status_style: render_mod.RenderStyle = switch (self.mode) {
            .Search => .search_status,
            .Insert => .status_insert,
            else => .status_normal,
        };
        self.screen.fillRow(row, ' ', status_style);

        if (self.mode == .Command) {
            self.screen.writeText(row, 0, ":", status_style);
            self.screen.writeText(row, 1, self.command_buffer.items, status_style);
            return;
        }

        if (self.mode == .Search) {
            self.screen.writeText(row, 0, "/", status_style);
            self.screen.writeText(row, 1, self.search_buffer.items, status_style);
            const col: usize = 1 + self.search_buffer.items.len;
            if (self.search_system) |s| {
                var info_buf: [64]u8 = undefined;
                const info = if (s.matches.items.len > 0)
                    std.fmt.bufPrint(&info_buf, " ({d}/{d})", .{ (s.active_match_idx orelse 0) + 1, s.matches.items.len }) catch ""
                else
                    " (no matches)";
                self.screen.writeText(row, col, info, status_style);
            }
            return;
        }

        if (self.error_message) |err_msg| {
            self.screen.fillRow(row, ' ', .normal);
            self.screen.writeText(row, 0, err_msg, .error_style);
            return;
        }

        const mode_str = if (self.mode == .Normal) "-- NORMAL --" else "-- INSERT --";
        var status_buf: [160]u8 = undefined;
        const status = if (tab) |t| blk: {
            var diag_count: usize = 0;
            if (t.buf.filename) |fname| {
                if (self.diagnostics.get(fname)) |dv| {
                    diag_count = dv.object.get("diagnostics").?.array.items.len;
                }
            }

            if (diag_count > 0) {
                break :blk std.fmt.bufPrint(&status_buf, " {s} | Row: {d}, Col: {d} | Cursors: {d} | ERR: {d} | FPS: {d} ", .{ mode_str, t.mainCursor().row + 1, t.mainCursor().col + 1, t.cursors.items.len, diag_count, self.fps }) catch "";
            }
            break :blk std.fmt.bufPrint(&status_buf, " {s} | Row: {d}, Col: {d} | Cursors: {d} | FPS: {d} ", .{ mode_str, t.mainCursor().row + 1, t.mainCursor().col + 1, t.cursors.items.len, self.fps }) catch "";
        } else std.fmt.bufPrint(&status_buf, " {s} | No file open | FPS: {d} ", .{ mode_str, self.fps }) catch "";

        self.screen.writeText(row, 0, status, status_style);
    }

    fn moveVirtualCursor(self: *Editor, writer: anytype, tab: ?*Tab, gutter_width: usize, visible_rows: usize) !void {
        if (self.mode == .Command) {
            try terminal.moveCursor(writer, self.height, 2 + self.command_buffer.items.len);
            return;
        }
        if (self.mode == .Search) {
            try terminal.moveCursor(writer, self.height, 2 + self.search_buffer.items.len);
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

    fn renderCompletionMenu(self: *Editor, writer: anytype) !void {
        if (!self.completion_active or self.completion_items == null) return;

        const tab = self.currentTab() orelse return;
        const mc = tab.mainCursor();

        const explorer_width = if (self.explorer_visible) self.width / 5 else 0;
        const gutter_width = self.calculateGutterWidth(tab.buf.lines.items.len);

        // Relative row in viewport
        const rel_row = mc.row - tab.scroll_row;
        const col = explorer_width + gutter_width + mc.col + 1;

        const items_val = self.completion_items.?;
        var items: []std.json.Value = &[_]std.json.Value{};

        if (items_val == .array) {
            items = items_val.array.items;
        } else if (items_val == .object) {
            if (items_val.object.get("items")) |v| {
                if (v == .array) items = v.array.items;
            }
        }

        if (items.len == 0) {
            self.completion_active = false;
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
        if (self.completion_selected >= max_height) {
            scroll_top = self.completion_selected - max_height + 1;
        }

        // Draw background/border
        for (0..visible_count) |i| {
            const item_idx = scroll_top + i;
            if (item_idx >= items.len) break;

            try terminal.moveCursor(writer, row + i, col);

            if (item_idx == self.completion_selected) {
                try writer.writeAll("\x1b[48;5;25m\x1b[38;5;255m"); // Blue selection, white text
            } else {
                try writer.writeAll("\x1b[48;5;236m\x1b[38;5;250m"); // Dark grey background, light grey text
            }

            const item = items[item_idx].object;
            const label = item.get("label").?.string;
            const kind_val = if (item.get("kind")) |k| @as(u8, @intCast(k.integer)) else @as(u8, 0);

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
            if (item_idx == self.completion_selected) {
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
        if (!self.completion_active or self.completion_items == null) return false;
        const items_val = self.completion_items.?;
        var items: []std.json.Value = &[_]std.json.Value{};
        if (items_val == .array) {
            items = items_val.array.items;
        } else if (items_val == .object) {
            if (items_val.object.get("items")) |v| {
                if (v == .array) items = v.array.items;
            }
        }

        if (event.eql(self.keys.completion_previous)) {
            if (self.completion_selected > 0) {
                self.completion_selected -= 1;
            } else if (items.len > 0) {
                self.completion_selected = items.len - 1;
            }
            return true;
        }

        if (event.eql(self.keys.completion_next)) {
            if (self.completion_selected < items.len - 1) {
                self.completion_selected += 1;
            } else {
                self.completion_selected = 0;
            }
            return true;
        }

        if (event.eql(self.keys.completion_accept)) {
            if (items.len == 0) {
                self.completion_active = false;
                return false;
            }
            const item = items[self.completion_selected].object;
            const label = item.get("label").?.string;
            const insertText = if (item.get("insertText")) |it| it.string else label;

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

            self.completion_active = false;
            return true;
        }

        if (event.eql(self.keys.completion_cancel)) {
            self.completion_active = false;
            return true;
        }

        switch (event.key) {
            .Char => {
                if (!std.ascii.isAlphanumeric(event.char)) {
                    self.completion_active = false;
                    return false;
                }
                return false;
            },
            else => {
                self.completion_active = false;
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
        ed.mode = .Normal;
        ed.explorer_visible = false;
        ed.explorer_focused = false;
        ed.completion_active = false;
        ed.search_buffer.clearRetainingCapacity();

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
        ed.mode = case.mode;
        ed.explorer_visible = case.explorer_visible;
        ed.explorer_focused = case.explorer_focused;
        ed.completion_active = case.completion_active;
        ed.search_buffer.clearRetainingCapacity();
        try ed.search_buffer.appendSlice(ed.allocator, case.search_text);

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
    ed.explorer_visible = true;
    ed.explorer_focused = false;

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
    ed.mode = .Normal;
    ed.width = 80;
    ed.height = 24;
    ed.render_dirty = false;
    ed.force_full_render = false;
    return ed;
}

pub fn start_editor(io: std.Io, allocator: std.mem.Allocator, cfg: config.Config) !void {
    var editor = try Editor.init(allocator, io, cfg);
    defer editor.deinit();
    try editor.run();
}
