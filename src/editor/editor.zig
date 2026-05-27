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
const editor_lsp = @import("lsp/editor_lsp.zig");
const viewport_mod = @import("navigation/viewport.zig");
const syntax = @import("syntax.zig");
const editor_syntax = @import("syntax_editor.zig");
const perf = @import("../perf/perf.zig");
const completion_menu = @import("renderer/completion_menu.zig");
const editor_render = @import("renderer/editor_render.zig");
const render_mod = @import("renderer/virtual_screen.zig");
const picker_help_popups = @import("renderer/picker_help_popups.zig");
const popup = @import("renderer/popup.zig");
const search_popups = @import("renderer/search_popups.zig");
const statusline = @import("renderer/statusline.zig");
const tabbar = @import("renderer/tabbar.zig");
const logger = @import("../logger.zig");
const tab_mod = @import("model/tab.zig");
const state_mod = @import("state/state.zig");
const jump_history = @import("state/jump_history.zig");
const key_profile = @import("runtime/key_profile.zig");
const movement_coalesce = @import("runtime/movement_coalesce.zig");
const runtime_background = @import("runtime/background.zig");
const runtime_loop = @import("runtime/loop.zig");
const runtime_mod = @import("runtime/runtime.zig");
const renderer_mod = @import("renderer/renderer.zig");
const terminal_panel_mod = @import("terminal_panel.zig");
const icons_mod = @import("icons.zig");
const git_diff = @import("git/diff_model.zig");

pub const EditorMode = state_mod.EditorMode;
pub const Pos = tab_mod.Pos;
pub const Cursor = tab_mod.Cursor;
pub const Tab = tab_mod.Tab;
const max_movement_coalesce_batch_count = movement_coalesce.max_movement_coalesce_batch_count;
const CoalescedMovement = movement_coalesce.CoalescedMovement;
const MovementCoalesceStopReason = movement_coalesce.MovementCoalesceStopReason;
const MovementCoalesceSnapshot = movement_coalesce.MovementCoalesceSnapshot;
const CoalescingCandidate = movement_coalesce.CoalescingCandidate;
const MovementCoalesceEligibility = movement_coalesce.MovementCoalesceEligibility;

const InputKeyRead = runtime_loop.InputKeyRead;
const RuntimeKeyDispatch = runtime_loop.RuntimeKeyDispatch;

pub const HorizontalScrollCommand = viewport_mod.HorizontalScrollCommand;

const TabBarLayout = tabbar.TabBarLayout;

const FilesystemPickerGeometry = popup.FilesystemPickerGeometry;

const GlobalSearchRenderRow = search_popups.GlobalSearchRenderRow;

pub const Editor = struct {
    config: config.Config,
    keybinding_registry: command_keybindings.Registry,
    configured_icon_mode: icons_mod.IconMode,
    icon_mode: icons_mod.IconMode,
    icons: icons_mod.IconSet,
    utf8_locale_detected: bool,
    allocator: std.mem.Allocator,
    io: std.Io,
    state: state_mod.EditorState,
    terminal_panel: terminal_panel_mod.TerminalPanel,
    runtime: runtime_mod.EditorRuntime,
    renderer: renderer_mod.EditorRenderer,
    keypress_profiler: perf.KeypressProfiler,
    active_config_path: []const u8,
    active_config_source: config.ConfigPathSource,
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
    message_buf: [256]u8 = undefined,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, cfg: config.Config) !Editor {
        return initWithConfigPathAndRuntimeOptions(allocator, io, cfg, "config.toml", .cli, .{});
    }

    pub fn initWithRuntimeOptions(allocator: std.mem.Allocator, io: std.Io, cfg: config.Config, runtime_options: runtime_mod.EditorRuntime.Options) !Editor {
        return initWithConfigPathAndRuntimeOptions(allocator, io, cfg, "config.toml", .cli, runtime_options);
    }

    pub fn initWithConfigPath(
        allocator: std.mem.Allocator,
        io: std.Io,
        cfg: config.Config,
        active_config_path: []const u8,
        active_config_source: config.ConfigPathSource,
    ) !Editor {
        return initWithConfigPathAndRuntimeOptions(allocator, io, cfg, active_config_path, active_config_source, .{});
    }

    pub fn initWithConfigPathAndRuntimeOptions(
        allocator: std.mem.Allocator,
        io: std.Io,
        cfg: config.Config,
        active_config_path: []const u8,
        active_config_source: config.ConfigPathSource,
        runtime_options: runtime_mod.EditorRuntime.Options,
    ) !Editor {
        return initWithConfigPathRuntimeOptionsAndEnv(allocator, io, cfg, active_config_path, active_config_source, runtime_options, icons_mod.EmptyEnv{});
    }

    pub fn initWithConfigPathRuntimeOptionsAndEnv(
        allocator: std.mem.Allocator,
        io: std.Io,
        cfg: config.Config,
        active_config_path: []const u8,
        active_config_source: config.ConfigPathSource,
        runtime_options: runtime_mod.EditorRuntime.Options,
        env: anytype,
    ) !Editor {
        var runtime = try runtime_mod.EditorRuntime.initWithOptions(allocator, io, runtime_options);
        errdefer runtime.deinit(allocator);
        if (runtime.lsp_mgr) |*mgr| {
            if (cfg.languages.protobuf) |protobuf| {
                if (protobuf.extensions.len > 0) {
                    try mgr.plugin_mgr.overrideExtensions("protobuf", protobuf.extensions);
                }
                if (protobuf.lsp) |lsp| {
                    if (lsp.command) |command| {
                        try mgr.plugin_mgr.overrideLsp("protobuf", command, lsp.args, lsp.language_id);
                    }
                }
            }
        }
        var keybinding_diagnostics = command_keybindings.BuildDiagnostics{};
        defer keybinding_diagnostics.deinit(allocator);
        var keybinding_registry = try config.buildKeybindingRegistry(allocator, &cfg, &keybinding_diagnostics);
        errdefer keybinding_registry.deinit(allocator);
        const owned_config_path = try allocator.dupe(u8, active_config_path);
        errdefer allocator.free(owned_config_path);
        const configured_icon_mode = try config.configuredIconMode(&cfg);
        const active_icon_mode = icons_mod.detectIconMode(env, configured_icon_mode);

        return Editor{
            .allocator = allocator,
            .io = io,
            .config = cfg,
            .keybinding_registry = keybinding_registry,
            .configured_icon_mode = configured_icon_mode,
            .icon_mode = active_icon_mode,
            .icons = icons_mod.iconSetForMode(active_icon_mode),
            .utf8_locale_detected = icons_mod.hasUtf8Locale(env),
            .active_config_path = owned_config_path,
            .active_config_source = active_config_source,
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
        self.allocator.free(self.active_config_path);
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

    pub fn fontInfoStatusMessage(self: *Editor) []const u8 {
        const utf8_text = if (self.utf8_locale_detected) "yes" else "no";
        return std.fmt.bufPrint(
            &self.message_buf,
            "Icons: active={s}, config={s}, UTF-8={s}. Terminal apps cannot switch fonts; set [ui].icon_mode or FLAMINGO_ICON_MODE.",
            .{ icons_mod.iconModeName(self.icon_mode), icons_mod.iconModeName(self.configured_icon_mode), utf8_text },
        ) catch "Icons: use [ui].icon_mode or FLAMINGO_ICON_MODE; terminal apps cannot switch fonts automatically.";
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
        self.clearAllMultiCursors();
        const added = try self.state.addTab(self.allocator, buf);
        self.markDirty(.full);
        if (!added) {
            self.queueGitDiffRefreshForCurrentTab(false);
            return;
        }
        self.queueGitDiffRefreshForCurrentTab(false);

        if (self.runtime.lsp_mgr) |*mgr| {
            if (self.currentTab()) |tab| if (tab.buf.filename) |fname| {
                if (mgr.startLspForFile(fname)) |lsp_start| {
                    switch (lsp_start) {
                        .command_unavailable, .start_failed => |plugin_name| {
                            if (std.mem.eql(u8, plugin_name, "protobuf")) {
                                self.setStatus("Protobuf LSP unavailable: install Buf or configure a protobuf language server.");
                            }
                        },
                        else => {},
                    }
                } else |err| {
                    logz.err().fmt("msg", "Failed to start LSP: {any}", .{err}).log();
                }

                const content = try tab.buf.toOwnedTextSnapshot(self.allocator);
                defer self.allocator.free(content);

                mgr.notifyOpen(fname, content) catch |err| {
                    logz.err().fmt("msg", "Failed to notify open: {any}", .{err}).log();
                };
            };
        }
    }

    pub fn requestDefinitionAtCursor(self: *Editor) !void {
        return editor_lsp.requestDefinitionAtCursor(self);
    }

    pub fn closeTab(self: *Editor) void {
        self.clearAllMultiCursors();
        if (self.currentTab()) |tab| {
            if (tab.buf.filename) |filename| {
                if (self.runtime.lsp_mgr) |*mgr| {
                    mgr.notifyClose(filename) catch |err| {
                        logz.err().fmt("msg", "Failed to notify close: {any}", .{err}).log();
                    };
                }
            }
        }
        self.state.closeTab(self.allocator);
        self.markDirty(.full);
    }

    pub fn nextTab(self: *Editor) void {
        self.clearAllMultiCursors();
        self.state.nextTab();
        self.clearAllMultiCursors();
        self.markDirty(.full);
    }

    pub fn prevTab(self: *Editor) void {
        self.clearAllMultiCursors();
        self.state.prevTab();
        self.clearAllMultiCursors();
        self.markDirty(.full);
    }

    pub fn closeAllTabs(self: *Editor) void {
        self.clearAllMultiCursors();
        self.state.closeAllTabs(self.allocator);
        self.markDirty(.full);
    }

    pub fn clearAllMultiCursors(self: *Editor) void {
        for (self.state.tabs.items) |*tab| {
            tab.multi_cursor.clear(self.allocator);
        }
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
                self.saveTab(tab) catch {
                    error_occurred = true;
                };
            }
        }
        if (error_occurred) {
            self.state.error_message = "Failed to save some files";
        }
    }

    pub fn saveCurrentBuffer(self: *Editor) !void {
        const tab = self.currentTab() orelse return;
        try self.saveTab(tab);
    }

    pub fn saveTab(self: *Editor, tab: *Tab) !void {
        const filename = tab.buf.filename orelse return error.MissingFilename;

        if (tab.buf.kind == .settings_config) {
            const snapshot = try tab.buf.toOwnedTextSnapshot(self.allocator);
            defer self.allocator.free(snapshot);

            if (try config.validateConfigBytesForSave(self.allocator, filename, snapshot)) |message| {
                defer self.allocator.free(message);
                self.setStatusFmt("Config save rejected: {s}", .{message});
                self.markDirty(.full);
                return error.InvalidConfig;
            }

            try tab.buf.saveTextToFile(self.io, filename, snapshot);
            if (self.runtime.lsp_mgr) |*mgr| {
                mgr.notifySave(filename) catch |err| {
                    logz.err().fmt("msg", "Failed to notify save: {any}", .{err}).log();
                };
            }
            self.queueGitDiffRefreshForTab(tab, false);
            self.setStatus("Config saved. Restart Flamingo for all settings to take effect.");
            self.markDirty(.full);
            return;
        }

        try tab.buf.saveToFile(self.io, filename);
        if (self.runtime.lsp_mgr) |*mgr| {
            mgr.notifySave(filename) catch |err| {
                logz.err().fmt("msg", "Failed to notify save: {any}", .{err}).log();
            };
        }
        self.queueGitDiffRefreshForTab(tab, false);
    }

    pub fn queueGitDiffRefreshForCurrentTab(self: *Editor, explicit: bool) void {
        const tab = self.currentTab() orelse {
            if (explicit) self.setStatus("Git diff refresh unavailable: no file");
            return;
        };
        self.queueGitDiffRefreshForTab(tab, explicit);
    }

    pub fn queueGitDiffRefreshForTab(self: *Editor, tab: *Tab, explicit: bool) void {
        const filename = tab.buf.filename orelse {
            if (explicit) self.setStatus("Git diff refresh unavailable: no file");
            return;
        };
        const worker = self.runtime.git_diff_worker orelse {
            if (explicit) self.setStatus("Git diff refresh unavailable");
            return;
        };
        worker.requestRefresh(filename, tab.buf.lines.items.len, explicit) catch |err| {
            logz.debug().fmt("msg", "failed to queue git diff refresh: {any}", .{err}).log();
            if (explicit) self.setStatus("Git diff refresh failed");
        };
    }

    pub fn setGitDiffRefreshStatus(self: *Editor, status: git_diff.RefreshStatus) void {
        self.setStatus(switch (status) {
            .disabled => "Git diff unavailable: not a Git repository",
            .clean => "Git diff refreshed: no unstaged changes",
            .changed => "Git diff refreshed",
            .untracked => "Git diff refreshed: untracked file",
            .outside_repository => "Git diff unavailable: file is outside repository",
            .git_unavailable => "Git executable not found",
            .command_failed => "Git diff refresh failed",
            .output_too_large => "Git diff output too large",
        });
    }

    pub fn setStatus(self: *Editor, message: []const u8) void {
        const len = @min(message.len, self.message_buf.len);
        @memcpy(self.message_buf[0..len], message[0..len]);
        self.state.status_message = self.message_buf[0..len];
    }

    pub fn setStatusFmt(self: *Editor, comptime fmt: []const u8, args: anytype) void {
        self.state.status_message = std.fmt.bufPrint(&self.message_buf, fmt, args) catch "Status message too long";
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
        return runtime_loop.run(self);
    }

    /// Run the editor event loop with explicit reader/writer.
    /// Using generic I/O allows tests to inject a `fixedBufferStream` reader
    /// (synthetic key bytes) and an `ArrayList` writer (capture render output)
    /// without touching a real TTY.
    pub fn runWithIO(self: *Editor, reader: anytype, raw_writer: anytype) !void {
        return runtime_loop.runWithIO(self, reader, raw_writer);
    }

    fn readInputKey(self: *Editor, reader: anytype, metrics: *perf.FrameMetrics) !InputKeyRead {
        return runtime_loop.readInputKey(self, reader, metrics);
    }

    fn refreshTerminalSize(self: *Editor) void {
        runtime_loop.refreshTerminalSize(self);
    }

    fn dispatchRuntimeKeyForLoop(
        self: *Editor,
        event: terminal.KeyEvent,
        key_trace: ?*perf.KeypressTrace,
        metrics: *perf.FrameMetrics,
    ) !RuntimeKeyDispatch {
        return runtime_loop.dispatchRuntimeKeyForLoop(self, event, key_trace, metrics);
    }

    fn movementCoalescingEligibilityBefore(self: *Editor, event: terminal.KeyEvent) MovementCoalesceEligibility {
        return movement_coalesce.movementCoalescingEligibilityBefore(self, event);
    }

    fn coalescingStopReasonAfterMovement(self: *Editor, snapshot: MovementCoalesceSnapshot) ?MovementCoalesceStopReason {
        return movement_coalesce.coalescingStopReasonAfterMovement(self, snapshot);
    }

    fn coalescingStopReasonForNext(
        self: *Editor,
        candidate: CoalescingCandidate,
        event: terminal.KeyEvent,
        batch_count: usize,
    ) ?MovementCoalesceStopReason {
        return movement_coalesce.coalescingStopReasonForNext(self, candidate, event, batch_count);
    }

    fn processBackgroundEvents(self: *Editor, max_fifo_events: usize) !void {
        return runtime_background.processBackgroundEvents(self, max_fifo_events);
    }

    fn updateStatusClockDirty(self: *Editor) void {
        runtime_background.updateStatusClockDirty(self);
    }

    pub fn noteKeypressMovementHandled(self: *Editor, handled: bool) void {
        key_profile.noteKeypressMovementHandled(self, handled);
    }

    fn initKeypressTrace(self: *Editor, event: terminal.KeyEvent, key_name: []const u8) perf.KeypressTrace {
        return key_profile.initKeypressTrace(self, event, key_name);
    }

    fn updateKeypressTraceAfterDispatch(self: *Editor, trace: *perf.KeypressTrace) void {
        key_profile.updateKeypressTraceAfterDispatch(self, trace);
    }

    fn formatKeyName(event: terminal.KeyEvent, buf: *[32]u8) []const u8 {
        return key_profile.formatKeyName(event, buf);
    }

    pub fn shouldRenderAfterInputEvent(self: *const Editor, event: terminal.KeyEvent) bool {
        if (event.key == .PageUp or event.key == .PageDown) return true;

        var without_shift = event;
        without_shift.shift = false;
        const context: commands.CommandContext = if (self.state.explorer_focused and self.state.explorer_visible and self.state.tree != null)
            if (self.state.tree.?.search_active) .explorer_search else .explorer
        else if (self.state.todo_panel.visible and self.state.todo_panel.focused)
            .todo_panel
        else if (self.state.comments_panel.visible and self.state.comments_panel.focused)
            .comments_panel
        else if (self.state.mode == .GitGraph)
            .git_graph
        else if (self.state.mode == .GitDiff)
            .git_diff
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
            .todo_panel_move_up,
            .todo_panel_move_down,
            .comments_panel_move_up,
            .comments_panel_move_down,
            .git_graph_move_up,
            .git_graph_move_down,
            .git_graph_page_up,
            .git_graph_page_down,
            .git_diff_move_up,
            .git_diff_move_down,
            .git_diff_page_up,
            .git_diff_page_down,
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

    fn buildStatusText(self: *Editor, tab: ?*Tab, buf: *[160]u8) ![]const u8 {
        return statusline.buildStatusText(self, tab, buf);
    }

    fn statusModeStyle(self: *const Editor) render_mod.RenderStyle {
        return statusline.statusModeStyle(self);
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

    pub fn handleRuntimeKey(self: *Editor, event: terminal.KeyEvent) !void {
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
        return editor_lsp.modeAllowsCompletion(self);
    }

    fn handleSyntaxParseResult(self: *Editor, result: *syntax.ParseResult) !void {
        return editor_syntax.handleSyntaxParseResult(self, result);
    }

    fn notePendingLspChange(self: *Editor) void {
        editor_lsp.notePendingLspChange(self);
    }

    fn horizontalScrollForCursor(cursor_col: usize, scroll_col: usize, visible_width: usize) usize {
        return viewport_mod.horizontalScrollForCursor(cursor_col, scroll_col, visible_width);
    }

    pub fn applyHorizontalScrollCommand(self: *Editor, command: HorizontalScrollCommand) void {
        viewport_mod.applyHorizontalScrollCommand(self, command);
    }

    /// Adjust scroll state so the main cursor is always within the visible viewport_mod.
    pub fn clampScroll(self: *Editor) void {
        viewport_mod.clampScroll(self);
    }

    fn tabLabelWidth(tabs: []const Tab, tab: *const Tab) usize {
        return tabbar.tabLabelWidth(tabs, tab);
    }

    fn tabStartCol(tabs: []const Tab, index: usize) usize {
        return tabbar.tabStartCol(tabs, index);
    }

    fn ensureActiveTabVisible(tabs: []const Tab, active_index: usize, available_width: usize, scroll_col: *usize) void {
        tabbar.ensureActiveTabVisible(tabs, active_index, available_width, scroll_col);
    }

    fn prepareTabBarLayout(self: *Editor, width: usize) TabBarLayout {
        return tabbar.prepareTabBarLayout(self.state.tabs.items, self.state.active_tab_index, width, &self.state.tab_bar_scroll_col);
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

    fn helpPopupGeometry(self: *const Editor) ?FilesystemPickerGeometry {
        return picker_help_popups.helpPopupGeometry(self);
    }

    pub fn helpPopupBodyRows(self: *const Editor) usize {
        return picker_help_popups.helpPopupBodyRows(self);
    }

    /// Calculates total gutter width: 1 space + num_digits + 1 space + 1 git diff marker + 1 space separator.
    pub fn calculateGutterWidth(self: *const Editor, total_lines: usize) usize {
        _ = self;
        return renderer_mod.calculateGutterWidth(total_lines);
    }

    pub fn renderVirtual(self: *Editor, writer: anytype, metrics: *perf.FrameMetrics) !void {
        return editor_render.renderVirtual(self, writer, metrics);
    }

    fn diagnosticUri(value: std.json.Value) ?[]const u8 {
        return editor_lsp.diagnosticUri(value);
    }

    fn isValidCompletionValue(value: std.json.Value) bool {
        return editor_lsp.isValidCompletionValue(value);
    }

    fn completionItemObject(value: std.json.Value) ?std.json.ObjectMap {
        return editor_lsp.completionItemObject(value);
    }

    fn completionItemString(item: std.json.ObjectMap, key: []const u8) ?[]const u8 {
        return editor_lsp.completionItemString(item, key);
    }

    fn completionKindLabel(item: std.json.ObjectMap) []const u8 {
        return completion_menu.completionKindLabel(item);
    }

    fn handleCompletionInput(self: *Editor, event: terminal.KeyEvent) !bool {
        return editor_lsp.handleCompletionInput(self, event);
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

pub fn start_editor(
    io: std.Io,
    allocator: std.mem.Allocator,
    cfg: config.Config,
    active_config_path: []const u8,
    active_config_source: config.ConfigPathSource,
    env: anytype,
) !void {
    var editor = try Editor.initWithConfigPathRuntimeOptionsAndEnv(allocator, io, cfg, active_config_path, active_config_source, .{}, env);
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

    // 1-99 lines => 2 digits min => 1 + 2 + 1 space + 1 marker + 1 = 6
    try std.testing.expectEqual(@as(usize, 6), ed.calculateGutterWidth(5));
    try std.testing.expectEqual(@as(usize, 6), ed.calculateGutterWidth(99));

    // 100-999 lines => 3 digits => 1 + 3 + 1 space + 1 marker + 1 = 7
    try std.testing.expectEqual(@as(usize, 7), ed.calculateGutterWidth(100));
    try std.testing.expectEqual(@as(usize, 7), ed.calculateGutterWidth(999));
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
    const cfg = config.Config{ .ui = .{ .icon_mode = "nerd_font" } };
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
    try std.testing.expect(std.mem.indexOf(u8, rendered, icons_mod.nerdFontIcons.git_branch) != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, " main") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, icons_mod.nerdFontIcons.file_zig) != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, " src/config.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, icons_mod.nerdFontIcons.context) != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, " explorer_rename") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, icons_mod.nerdFontIcons.error_icon) != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, " 1") != null);
}

test "Editor status omits git branch outside repository and keeps error" {
    const cfg = config.Config{ .ui = .{ .icon_mode = "nerd_font" } };
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
    try std.testing.expect(std.mem.indexOf(u8, rendered, icons_mod.nerdFontIcons.git_branch) == null);
}

test "Editor status renders each explicit icon mode" {
    inline for (.{ "nerd_font", "unicode", "ascii" }) |mode| {
        const cfg = config.Config{ .ui = .{ .icon_mode = mode } };
        var ed = try Editor.init(std.testing.allocator, std.testing.io, cfg);
        defer ed.deinit();
        ed.width = 80;
        ed.height = 12;
        ed.state.mode = .Normal;

        var out = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer out.deinit();
        try ed.renderBenchmarkFrame(&out.writer);
        try std.testing.expect(out.written().len > 0);
    }
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
    ed.width = 10; // 6-cell gutter leaves 4 content columns.
    ed.height = 8;

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    try ed.renderBenchmarkFrame(&out.writer);
    const rendered = out.written();
    try std.testing.expect(std.mem.indexOf(u8, rendered, "5678") != null);
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
