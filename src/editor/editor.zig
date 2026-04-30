const std = @import("std");
const logz = @import("logz");
const config = @import("../config.zig");
const terminal = @import("../terminal.zig");
const buffer = @import("buffer.zig");
const dashboard = @import("dashboard.zig");
const explorer = @import("explorer.zig");
const input = @import("input.zig");
const search = @import("search.zig");
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

pub const Tab = struct {
    buf: buffer.Buffer,
    cursors: std.ArrayListUnmanaged(Cursor),
    main_cursor_idx: usize = 0,
    scroll_row: usize = 0,

    pub fn deinit(self: *Tab, allocator: std.mem.Allocator) void {
        self.buf.deinit();
        self.cursors.deinit(allocator);
    }

    pub fn mainCursor(self: *Tab) *Cursor {
        return &self.cursors.items[self.main_cursor_idx];
    }
};

pub const Editor = struct {
    config: config.Config,
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
    lsp_mgr: ?lsp_manager.LspManager = null,

    // Completion state
    completion_items: ?std.json.Value = null,
    completion_active: bool = false,
    completion_selected: usize = 0,

    diagnostics: std.StringHashMap(std.json.Value),

    pub fn init(allocator: std.mem.Allocator, io: std.Io, cfg: config.Config) !Editor {
        const queue = try allocator.create(event_queue.EventQueue);
        queue.* = event_queue.EventQueue.init(allocator, io);

        const mgr = try lsp_manager.LspManager.init(allocator, io, queue);

        return Editor{
            .allocator = allocator,
            .io = io,
            .config = cfg,
            .tabs = std.ArrayList(Tab).empty,
            .search_system = search.SearchSystem.init(allocator),
            .event_queue = queue,
            .lsp_mgr = mgr,
            .diagnostics = std.StringHashMap(std.json.Value).init(allocator),
        };
    }

    pub fn deinit(self: *Editor) void {
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
        self.search_buffer.deinit(self.allocator);
        self.search_buffer = .empty;
        if (self.clipboard) |c| {
            self.allocator.free(c);
            self.clipboard = null;
        }

        if (self.lsp_mgr) |*mgr| {
            var it = self.diagnostics.iterator();
            while (it.next()) |entry| {
                mgr.freeValue(entry.value_ptr.*);
                self.allocator.free(entry.key_ptr.*);
            }
            self.diagnostics.deinit();
            mgr.deinit();
            self.lsp_mgr = null;
        }
        self.event_queue.quit = true;
        self.event_queue.deinit();
        self.allocator.destroy(self.event_queue);
    }

    pub fn currentTab(self: *Editor) ?*Tab {
        if (self.tabs.items.len == 0) return null;
        return &self.tabs.items[self.active_tab_index];
    }

    pub fn addTab(self: *Editor, buf: buffer.Buffer) !void {
        var cursors = std.ArrayListUnmanaged(Cursor).empty;
        try cursors.append(self.allocator, .{});
        try self.tabs.append(self.allocator, .{
            .buf = buf,
            .cursors = cursors,
        });
        self.active_tab_index = self.tabs.items.len - 1;

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
    }

    pub fn nextTab(self: *Editor) void {
        if (self.tabs.items.len <= 1) return;
        self.active_tab_index = (self.active_tab_index + 1) % self.tabs.items.len;
    }

    pub fn prevTab(self: *Editor) void {
        if (self.tabs.items.len <= 1) return;
        if (self.active_tab_index == 0) {
            self.active_tab_index = self.tabs.items.len - 1;
        } else {
            self.active_tab_index -= 1;
        }
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
        defer render_buffer.deinit(self.allocator);
        var aw = std.Io.Writer.Allocating.fromArrayList(self.allocator, &render_buffer);
        const writer = &aw.writer;

        while (!self.should_quit) {
            // Pump events
            while (self.event_queue.tryPop()) |ev| {
                switch (ev) {
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
                                },
                                .diagnostics => |diag_val| {
                                    const uri = diag_val.object.get("uri").?.string;
                                    // filename is after file://
                                    const fname = if (std.mem.startsWith(u8, uri, "file://")) uri[7..] else uri;

                                    if (self.diagnostics.get(fname)) |old| {
                                        mgr.freeValue(old);
                                    }

                                    const fname_copy = try self.allocator.dupe(u8, fname);
                                    try self.diagnostics.put(fname_copy, diag_val);
                                },
                                .none => {},
                            }
                        }
                    },
                }
            }

            aw.clearRetainingCapacity();
            try terminal.hideCursor(writer);
            try self.render(writer);
            try self.renderCompletionMenu(writer);
            try terminal.showCursor(writer);
            try raw_writer.writeAll(aw.written());

            const event = try terminal.readKey(reader);
            if (event.key == .None) continue;

            logz.debug().fmt("msg", "key event: key={s}, char={c}, ctrl={}, alt={}", .{ @tagName(event.key), event.char, event.ctrl, event.alt }).log();

            // Global quit sequence matching flamingo.toml config
            // For now hardcoded to Ctrl+Q
            if (event.ctrl and event.key == .Char and event.char == 'q') {
                self.should_quit = true;
                continue;
            }

            if (self.completion_active) {
                if (try self.handleCompletionInput(event)) continue;
            }

            try input.handleInput(self, event);

            // Notify LSP of change if buffer is dirty
            if (self.currentTab()) |tab| {
                if (tab.buf.is_dirty and tab.buf.filename != null) {
                    if (self.lsp_mgr) |*mgr| {
                        const content = try tab.buf.toString(self.allocator);
                        defer self.allocator.free(content);
                        mgr.notifyChange(tab.buf.filename.?, content) catch |err| {
                            logz.err().fmt("msg", "Failed to notify change: {any}", .{err}).log();
                        };
                    }
                }

                // Trigger completion
                const is_dot = (event.key == .Char and event.char == '.');
                const is_ctrl_space = (event.ctrl and event.key == .Char and event.char == ' ');

                if (is_dot or is_ctrl_space) {
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

        render_buffer.clearRetainingCapacity();
        try terminal.clearScreen(writer);
        try terminal.moveCursor(writer, 1, 1);
        try raw_writer.writeAll(render_buffer.items);
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
        try terminal.moveCursor(writer, 1, start_col);
        try terminal.eraseToLineEnd(writer);

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

        // Hybrid (Vim-style) line number gutter: absolute on current line, relative elsewhere.
        const tab = self.currentTab();
        const gutter_width: usize = if (tab) |t|
            self.calculateGutterWidth(t.buf.lines.items.len)
        else
            0;

        const top_reserved = 2; // tabs + separator
        const bot_reserved = 1; // status bar
        const visible_rows = if (self.height > (top_reserved + bot_reserved)) self.height - (top_reserved + bot_reserved) else 0;
        for (1..visible_rows + 1) |screen_row| {
            // 1. Move to the correct column for the right-hand panel (start at row 3)
            try terminal.moveCursor(writer, screen_row + 2, buf_start_col);

            if (tab) |t| {
                const buffer_line_idx = screen_row + t.scroll_row - 1;
                if (buffer_line_idx < t.buf.lines.items.len) {
                    // --- Gutter ---
                    const mc = t.mainCursor();
                    const is_current = (buffer_line_idx == mc.row);
                    const line_num: usize = if (is_current)
                        buffer_line_idx + 1 // absolute 1-based
                    else if (buffer_line_idx > mc.row)
                        buffer_line_idx - mc.row
                    else
                        mc.row - buffer_line_idx;

                    const num_digits = @max(buffer.countDigits(t.buf.lines.items.len), 2);

                    if (is_current) {
                        try writer.writeAll("\x1b[33;1m"); // bold yellow — current line
                    } else {
                        try writer.writeAll("\x1b[2;37m"); // dim grey  — relative distance
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
                    const line_content = try line.slice(self.allocator);
                    defer self.allocator.free(line_content);

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
                    while (char_idx < line_content.len and char_idx < content_width) : (char_idx += 1) {
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

                        try writer.writeByte(line_content[char_idx]);
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
                    break :blk try std.fmt.bufPrint(&buf, " {s} | Row: {d}, Col: {d} | Cursors: {d} | ERR: {d} ", .{ mode_str, t.mainCursor().row + 1, t.mainCursor().col + 1, t.cursors.items.len, diag_count });
                } else {
                    break :blk try std.fmt.bufPrint(&buf, " {s} | Row: {d}, Col: {d} | Cursors: {d} ", .{ mode_str, t.mainCursor().row + 1, t.mainCursor().col + 1, t.cursors.items.len });
                }
            } else try std.fmt.bufPrint(&buf, " {s} | No file open ", .{mode_str});

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

        switch (event.key) {
            .Up => {
                if (self.completion_selected > 0) {
                    self.completion_selected -= 1;
                } else if (items.len > 0) {
                    self.completion_selected = items.len - 1;
                }
                return true;
            },
            .Down => {
                if (self.completion_selected < items.len - 1) {
                    self.completion_selected += 1;
                } else {
                    self.completion_selected = 0;
                }
                return true;
            },
            .Enter => {
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
            },
            .Esc => {
                self.completion_active = false;
                return true;
            },
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

pub fn start_editor(io: std.Io, allocator: std.mem.Allocator, cfg: config.Config) !void {
    var editor = try Editor.init(allocator, io, cfg);
    defer editor.deinit();
    try editor.run();
}
