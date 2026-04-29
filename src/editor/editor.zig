const std = @import("std");
const logz = @import("logz");
const config = @import("../config.zig");
const terminal = @import("../terminal.zig");
const buffer = @import("buffer.zig");
const dashboard = @import("dashboard.zig");
const explorer = @import("explorer.zig");
const input = @import("input.zig");
const search = @import("search.zig");

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

    pub fn init(allocator: std.mem.Allocator, cfg: config.Config) Editor {
        return Editor{
            .allocator = allocator,
            .config = cfg,
            .tabs = std.ArrayList(Tab).empty,
            .search_system = search.SearchSystem.init(allocator),
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
        if (self.search_system) |*s| {
            s.deinit();
            self.search_system = null;
        }
        if (self.clipboard) |c| {
            self.allocator.free(c);
            self.clipboard = null;
        }
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
        const stdout = std.fs.File.stdout();
        var render_buffer = std.ArrayListUnmanaged(u8).empty;
        defer render_buffer.deinit(self.allocator);
        const writer = render_buffer.writer(self.allocator);

        const stdin = std.fs.File.stdin();

        try terminal.enableRawMode();
        defer terminal.disableRawMode();

        while (!self.should_quit) {
            const size = try terminal.getSize();
            if (self.width != size.cols or self.height != size.rows) {
                logz.info().fmt("msg", "terminal resized: {d}x{d}", .{ size.cols, size.rows }).log();
                self.width = size.cols;
                self.height = size.rows;
            }

            render_buffer.clearRetainingCapacity();
            try terminal.hideCursor(writer);
            try self.render(writer);
            try terminal.showCursor(writer);
            try stdout.writeAll(render_buffer.items);

            const event = try terminal.readKey(stdin);
            if (event.key == .None) continue;

            logz.debug().fmt("msg", "key event: key={s}, char={c}, ctrl={}, alt={}", .{ @tagName(event.key), event.char, event.ctrl, event.alt }).log();

            // Global quit sequence matching flamingo.toml config
            // For now hardcoded to Ctrl+Q
            if (event.ctrl and event.key == .Char and event.char == 'q') {
                self.should_quit = true;
                continue;
            }

            try input.handleInput(self, event);
        }

        try terminal.clearScreen(writer);
        try terminal.moveCursor(writer, 1, 1);
        try stdout.writeAll(render_buffer.items);
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
            const status_text = if (tab) |t| 
                try std.fmt.bufPrint(&buf, " {s} | Row: {d}, Col: {d} | Cursors: {d} ", .{ mode_str, t.mainCursor().row + 1, t.mainCursor().col + 1, t.cursors.items.len })
            else 
                try std.fmt.bufPrint(&buf, " {s} | No file open ", .{mode_str});
            
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
};

test "Editor.calculateGutterWidth" {
    const cfg = config.Config{};
    const ed = Editor.init(std.testing.allocator, cfg);

    // 1-99 lines => 2 digits min => 1 + 2 + 1 = 4
    try std.testing.expectEqual(@as(usize, 4), ed.calculateGutterWidth(5));
    try std.testing.expectEqual(@as(usize, 4), ed.calculateGutterWidth(99));

    // 100-999 lines => 3 digits => 1 + 3 + 1 = 5
    try std.testing.expectEqual(@as(usize, 5), ed.calculateGutterWidth(100));
    try std.testing.expectEqual(@as(usize, 5), ed.calculateGutterWidth(999));
}

pub fn start_editor(allocator: std.mem.Allocator, cfg: config.Config) !void {
    var editor = Editor.init(allocator, cfg);
    defer editor.deinit();
    try editor.run();
}
