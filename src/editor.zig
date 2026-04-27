const std = @import("std");
const logz = @import("logz");
const context = @import("context.zig");
const terminal = @import("terminal.zig");
const buffer = @import("buffer.zig");
const dashboard = @import("dashboard.zig");
const explorer = @import("explorer.zig");

pub const EditorMode = enum {
    Dashboard,
    Normal,
    Insert,
    Command,
    OpenFilePrompt,
};

pub const Tab = struct {
    buf: buffer.Buffer,
    cursor_row: usize = 0,
    cursor_col: usize = 0,
    scroll_row: usize = 0,

    pub fn deinit(self: *Tab) void {
        self.buf.deinit();
    }
};

pub const Editor = struct {
    ctx: *context.FlamingoContext,
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

    pub fn init(allocator: std.mem.Allocator, ctx: *context.FlamingoContext) Editor {
        return Editor{
            .allocator = allocator,
            .ctx = ctx,
            .tabs = std.ArrayList(Tab).empty,
        };
    }

    pub fn deinit(self: *Editor) void {
        for (self.tabs.items) |*tab| {
            tab.deinit();
        }
        self.tabs.deinit(self.allocator);

        if (self.tree) |*t| {
            t.deinit();
            self.tree = null;
        }
        self.command_buffer.deinit(self.allocator);
        self.command_buffer = .empty;
    }

    pub fn currentTab(self: *Editor) ?*Tab {
        if (self.tabs.items.len == 0) return null;
        return &self.tabs.items[self.active_tab_index];
    }

    fn addTab(self: *Editor, buf: buffer.Buffer) !void {
        try self.tabs.append(self.allocator, .{ .buf = buf });
        self.active_tab_index = self.tabs.items.len - 1;
    }

    fn closeTab(self: *Editor) void {
        if (self.tabs.items.len == 0) return;
        var tab = self.tabs.orderedRemove(self.active_tab_index);
        tab.deinit();

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

    fn nextTab(self: *Editor) void {
        if (self.tabs.items.len <= 1) return;
        self.active_tab_index = (self.active_tab_index + 1) % self.tabs.items.len;
    }

    fn prevTab(self: *Editor) void {
        if (self.tabs.items.len <= 1) return;
        if (self.active_tab_index == 0) {
            self.active_tab_index = self.tabs.items.len - 1;
        } else {
            self.active_tab_index -= 1;
        }
    }

    fn closeAllTabs(self: *Editor) void {
        for (self.tabs.items) |*tab| {
            tab.deinit();
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

            try self.handleInput(event);
        }

        try terminal.clearScreen(writer);
        try terminal.moveCursor(writer, 1, 1);
        try stdout.writeAll(render_buffer.items);
    }

    fn handleInput(self: *Editor, event: terminal.KeyEvent) !void {
        if (self.error_message != null) {
            self.error_message = null;
        }

        const switch_focus_key = terminal.parseKeyChord(self.ctx.config.keybindings.switch_focus);
        const is_ctrl_e = event.ctrl and event.key == .Char and event.char == 'e';
        const is_ctrl_w = event.ctrl and event.key == .Char and event.char == 'w';
        const is_alt_open_bracket = event.alt and event.key == .Char and event.char == '[';
        const is_alt_close_bracket = event.alt and event.key == .Char and event.char == ']';

        if (is_ctrl_e) {
            if (self.tree == null) {
                self.tree = explorer.Explorer.init(self.allocator, ".") catch null;
            }
            self.explorer_visible = !self.explorer_visible;
            if (self.explorer_visible) {
                self.explorer_focused = true;
            } else {
                self.explorer_focused = false;
            }
            return;
        }

        const is_tab = event.key == .Char and event.char == '\t';
        if (event.eql(switch_focus_key) or (is_tab and std.mem.eql(u8, self.ctx.config.keybindings.switch_focus, "ctrl+tab"))) {
            if (self.explorer_visible) {
                self.explorer_focused = !self.explorer_focused;
            }
            return;
        }

        if (is_ctrl_w) {
            if (self.mode != .Dashboard) {
                self.closeTab();
            }
            return;
        }

        if (is_alt_open_bracket) {
            self.nextTab();
            return;
        }

        if (is_alt_close_bracket) {
            self.prevTab();
            return;
        }

        if (self.explorer_focused and self.explorer_visible and self.tree != null) {
            if (self.mode == .Normal or self.mode == .Insert) {
                if (event.key == .Up) {
                    self.tree.?.moveUp();
                    return;
                } else if (event.key == .Down) {
                    self.tree.?.moveDown();
                    return;
                } else if (event.key == .Enter) {
                    if (self.tree.?.nodes.items.len > 0) {
                        const node = self.tree.?.nodes.items[self.tree.?.selected_index];
                        if (node.is_dir) {
                            self.tree.?.toggleExpand() catch {};
                        } else {
                            if (buffer.Buffer.loadFromFile(self.allocator, node.absolute_path)) |b| {
                                try self.addTab(b);
                                self.explorer_focused = false;
                                self.mode = .Normal;
                            } else |err| {
                                logz.err().fmt("msg", "failed to open file {s}: {s}", .{ node.absolute_path, @errorName(err) }).log();
                                self.error_message = "Could not open file";
                            }
                        }
                    }
                    return;
                }
            }
        }

        switch (self.mode) {
            .Dashboard => {
                const action = self.dash.handleInput(event);
                switch (action) {
                    .NewFile => {
                        self.mode = .Normal;
                        try self.addTab(try buffer.Buffer.init(self.allocator));
                    },
                    .OpenFile => {
                        self.mode = .OpenFilePrompt;
                        self.command_buffer.clearRetainingCapacity();
                    },
                    .OpenFolder => {
                        logz.info().string("msg", "action: OpenFolder").log();
                        self.closeAllTabs();
                        self.mode = .Normal;
                        if (self.tree) |*t| {
                            t.deinit();
                        }
                        self.tree = explorer.Explorer.init(self.allocator, ".") catch |err| {
                            logz.err().fmt("msg", "failed to init explorer: {s}", .{@errorName(err)}).log();
                            return;
                        };
                        self.explorer_visible = self.tree != null;
                        self.explorer_focused = self.tree != null;
                    },
                    .Quit => self.should_quit = true,
                    else => {},
                }
            },
            .Normal => {
                if (try self.handleMovement(event)) {
                    // Handled
                } else if (event.key == .Char and event.char == 'i') {
                    self.mode = .Insert;
                } else if (event.key == .Char and event.char == ':') {
                    self.mode = .Command;
                    self.command_buffer.clearRetainingCapacity();
                }

                // Keep cursor within line bounds
                if (self.currentTab()) |tab| {
                    if (tab.cursor_row >= tab.buf.lines.items.len) {
                        tab.cursor_row = tab.buf.lines.items.len - 1;
                    }
                    const line = tab.buf.lines.items[tab.cursor_row];
                    const len = line.len();
                    if (tab.cursor_col > len) {
                        tab.cursor_col = len;
                    }
                }
            },
            .Insert => {
                if (try self.handleMovement(event)) {
                    // Handled
                } else if (event.key == .Esc) {
                    self.mode = .Normal;
                } else if (event.key == .Enter) {
                    if (self.currentTab()) |tab| {
                        try tab.buf.insertNewline(tab.cursor_row, tab.cursor_col);
                        tab.cursor_row += 1;
                        tab.cursor_col = 0;
                    }
                } else if (event.key == .Backspace) {
                    if (self.currentTab()) |tab| {
                        const row = tab.cursor_row;
                        var prev_len: usize = 0;
                        if (row > 0) {
                            prev_len = tab.buf.lines.items[row - 1].len();
                        }

                        if (try tab.buf.deleteCharBack(tab.cursor_row, tab.cursor_col)) {
                            tab.cursor_row -= 1;
                            tab.cursor_col = prev_len;
                        } else {
                            if (tab.cursor_col > 0) tab.cursor_col -= 1;
                        }
                    }
                } else if (event.key == .Char and !event.ctrl and !event.alt) {
                    if (self.currentTab()) |tab| {
                        if (event.char == '\t') {
                            for (0..4) |_| {
                                try tab.buf.insertChar(tab.cursor_row, tab.cursor_col, ' ');
                                tab.cursor_col += 1;
                            }
                        } else {
                            try tab.buf.insertChar(tab.cursor_row, tab.cursor_col, event.char);
                            tab.cursor_col += 1;
                        }
                    }
                }
            },
            .Command => {
                if (event.key == .Esc) {
                    self.mode = .Normal;
                } else if (event.key == .Backspace) {
                    if (self.command_buffer.items.len > 0) {
                        self.command_buffer.shrinkRetainingCapacity(self.command_buffer.items.len - 1);
                    }
                } else if (event.key == .Enter) {
                    try self.executeCommand();
                } else if (event.key == .Char and !event.ctrl and !event.alt) {
                    try self.command_buffer.append(self.allocator, event.char);
                }
            },
            .OpenFilePrompt => {
                if (event.key == .Esc) {
                    self.mode = .Dashboard;
                } else if (event.key == .Backspace) {
                    if (self.command_buffer.items.len > 0) {
                        self.command_buffer.shrinkRetainingCapacity(self.command_buffer.items.len - 1);
                    }
                } else if (event.key == .Enter) {
                    if (self.command_buffer.items.len > 0) {
                        if (buffer.Buffer.loadFromFile(self.allocator, self.command_buffer.items)) |b| {
                            try self.addTab(b);
                            self.mode = .Normal;
                        } else |_| {
                            self.error_message = "Could not open file";
                            self.mode = .Dashboard;
                        }
                    } else {
                        self.mode = .Dashboard;
                    }
                } else if (event.key == .Char and !event.ctrl and !event.alt) {
                    try self.command_buffer.append(self.allocator, event.char);
                }
            },
        }
    }

    /// Close the current buffer and return to the Dashboard home screen.
    fn closeBuffer(self: *Editor) void {
        if (self.buf) |*b| {
            b.deinit();
            self.buf = null;
        }
        self.cursor_row = 0;
        self.cursor_col = 0;
        self.scroll_row = 0;
        self.explorer_visible = false;
        self.explorer_focused = false;
        self.mode = .Dashboard;
    }

    fn executeCommand(self: *Editor) !void {
        if (self.command_buffer.items.len == 0) {
            self.mode = .Normal;
            return;
        }

        var it = std.mem.splitScalar(u8, self.command_buffer.items, ' ');
        const cmd = it.next() orelse return;

        if (std.mem.eql(u8, cmd, "q")) {
            if (self.currentTab()) |tab| {
                if (tab.buf.is_dirty) {
                    self.error_message = "No write since last change (add ! to override)";
                    self.mode = .Normal;
                    return;
                }
            }
            self.closeTab();
        } else if (std.mem.eql(u8, cmd, "q!")) {
            self.closeTab();
        } else if (std.mem.eql(u8, cmd, "w")) {
            const filename = it.next();
            if (self.currentTab()) |tab| {
                if (filename) |f| {
                    try tab.buf.setFilename(f);
                }
                if (tab.buf.filename) |f| {
                    tab.buf.saveToFile(f) catch {
                        self.error_message = "Failed to save file";
                    };
                } else {
                    self.error_message = "No file name";
                }
            }
            self.mode = .Normal;
        } else if (std.mem.eql(u8, cmd, "wq")) {
            const filename = it.next();
            if (self.currentTab()) |tab| {
                if (filename) |f| {
                    try tab.buf.setFilename(f);
                }
                if (tab.buf.filename) |f| {
                    tab.buf.saveToFile(f) catch {
                        self.error_message = "Failed to save file";
                        self.mode = .Normal;
                        return;
                    };
                    self.closeTab();
                } else {
                    self.error_message = "No file name";
                    self.mode = .Normal;
                }
            } else {
                self.closeTab();
            }
        } else {
            self.error_message = "Not an editor command";
            self.mode = .Normal;
        }
    }

    fn handleMovement(self: *Editor, event: terminal.KeyEvent) !bool {
        const tab = self.currentTab() orelse return false;

        if (event.key == .Up) {
            if (event.alt) {
                tab.cursor_col = tab.buf.lines.items[tab.cursor_row].len();
            } else {
                if (tab.cursor_row > 0) tab.cursor_row -= 1;
                // Clamp col to the new line's length after vertical movement
                const new_line_len = tab.buf.lines.items[tab.cursor_row].len();
                if (tab.cursor_col > new_line_len) tab.cursor_col = new_line_len;
            }
            self.clampScroll();
            return true;
        } else if (event.key == .Down) {
            if (event.alt) {
                tab.cursor_col = 0;
            } else {
                if (tab.cursor_row < tab.buf.lines.items.len - 1) tab.cursor_row += 1;
                // Clamp col to the new line's length after vertical movement
                const new_line_len = tab.buf.lines.items[tab.cursor_row].len();
                if (tab.cursor_col > new_line_len) tab.cursor_col = new_line_len;
            }
            self.clampScroll();
            return true;
        } else if (event.key == .Left) {
            if (event.alt) {
                try self.jumpWordLeft();
            } else {
                if (tab.cursor_col > 0) tab.cursor_col -= 1;
            }
            return true;
        } else if (event.key == .Right) {
            if (event.alt) {
                try self.jumpWordRight();
            } else {
                const line = tab.buf.lines.items[tab.cursor_row];
                if (tab.cursor_col < line.len()) tab.cursor_col += 1;
            }
            return true;
        }
        return false;
    }

    /// Adjust scroll_row so cursor_row is always within the visible viewport.
    fn clampScroll(self: *Editor) void {
        const tab = self.currentTab() orelse return;
        const top_reserved = 1; // tabs
        const bot_reserved = 1; // status bar
        const visible_rows = if (self.height > (top_reserved + bot_reserved)) self.height - (top_reserved + bot_reserved) else 1;
        if (tab.cursor_row < tab.scroll_row) {
            tab.scroll_row = tab.cursor_row;
        } else if (tab.cursor_row >= tab.scroll_row + visible_rows) {
            tab.scroll_row = tab.cursor_row - visible_rows + 1;
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

        var buf_start_col: usize = 1;
        var buf_width: usize = self.width;

        // Move to top-left (row 2, because of tabs) WITHOUT blanking the screen — eliminates flicker.
        // Each line erases its own tail via \x1b[K; leftover rows cleared below with \x1b[J.
        try terminal.moveHome(writer);

        if (self.explorer_visible and self.tree != null) {
            const exp_width = (self.width * @as(usize, self.ctx.config.explorer.width_percentage)) / 100;
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

        const visible_rows = if (self.height > 3) self.height - 3 else 1;
        for (1..visible_rows + 1) |screen_row| {
            // 1. Move to the correct column for the right-hand panel (start at row 3)
            try terminal.moveCursor(writer, screen_row + 2, buf_start_col);

            if (tab) |t| {
                const buffer_line_idx = screen_row + t.scroll_row - 1;
                if (buffer_line_idx < t.buf.lines.items.len) {
                    // --- Gutter ---
                    const is_current = (buffer_line_idx == t.cursor_row);
                    const line_num: usize = if (is_current)
                        buffer_line_idx + 1 // absolute 1-based
                    else if (buffer_line_idx > t.cursor_row)
                        buffer_line_idx - t.cursor_row
                    else
                        t.cursor_row - buffer_line_idx;

                    const num_digits = @max(countDigits(t.buf.lines.items.len), 2);

                    if (is_current) {
                        try writer.writeAll("\x1b[33;1m"); // bold yellow — current line
                    } else {
                        try writer.writeAll("\x1b[2;37m"); // dim grey  — relative distance
                    }

                    // --- Render Gutter ---
                    // Format: " " (1 space) + number (num_digits wide) + " " (1 space)
                    try writer.writeByte(' ');
                    const num_used = countDigits(line_num);
                    const pad = num_digits - num_used;
                    for (0..pad) |_| try writer.writeByte(' ');
                    try writer.print("{d} ", .{line_num});
                    try writer.writeAll("\x1b[0m"); // Reset

                    // --- Line content ---
                    // No need to moveCursor; we are exactly at buf_start_col + gutter_width
                    const content_width = buf_width -| gutter_width;
                    const line = t.buf.lines.items[buffer_line_idx];
                    try line.writeTo(writer, content_width);
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
        } else if (self.error_message) |err_msg| {
            try writer.writeAll("\x1b[31;1m"); // Red, Bold
            try writer.print("{s}", .{err_msg});
            try writer.writeAll("\x1b[0m"); // Reset
        } else {
            try writer.writeAll("\x1b[7m"); // Invert colors
            const mode_str = if (self.mode == .Normal) "-- NORMAL --" else "-- INSERT --";
            const tab_idx = if (tab) |t| t.cursor_row + 1 else 0;
            const col_idx = if (tab) |t| t.cursor_col + 1 else 0;
            try writer.print(" {s} | Row: {d}, Col: {d} ", .{ mode_str, tab_idx, col_idx });

            // Pad status bar
            var padding: usize = 0;
            if (self.width > 40) {
                padding = self.width - 40;
            }
            for (0..padding) |_| {
                try writer.writeAll(" ");
            }
            try writer.writeAll("\x1b[0m"); // Reset
        }

        // Move cursor to proper location
        if (self.mode == .Command) {
            try terminal.moveCursor(writer, self.height, 2 + self.command_buffer.items.len);
        } else if (self.explorer_focused and self.explorer_visible and self.tree != null) {
            try terminal.moveCursor(writer, self.height, self.width);
        } else if (tab) |t| {
            // Offset cursor past the line-number gutter
            const content_width = buf_width -| gutter_width;
            const vis_col = if (t.cursor_col > content_width) content_width else t.cursor_col;
            const vis_row = if (t.cursor_row >= t.scroll_row)
                t.cursor_row - t.scroll_row + 3 // +1 for 1-based, +2 for tabs+sep
            else
                3;
            try terminal.moveCursor(writer, vis_row, buf_start_col + gutter_width + vis_col);
        }
    }

    fn jumpWordLeft(self: *Editor) !void {
        const tab = self.currentTab() orelse return;
        if (tab.cursor_col == 0) {
            if (tab.cursor_row > 0) {
                tab.cursor_row -= 1;
                tab.cursor_col = tab.buf.lines.items[tab.cursor_row].len();
            }
            return;
        }
        const l = tab.buf.lines.items[tab.cursor_row];
        const line = try l.slice(self.allocator);
        defer self.allocator.free(line);

        // Skip spaces first (moving left)
        while (tab.cursor_col > 0 and self.getCharClass(line[tab.cursor_col - 1]) == .Space) {
            tab.cursor_col -= 1;
        }

        if (tab.cursor_col == 0) return;

        const start_class = self.getCharClass(line[tab.cursor_col - 1]);
        while (tab.cursor_col > 0 and self.getCharClass(line[tab.cursor_col - 1]) == start_class) {
            tab.cursor_col -= 1;
        }
    }

    fn jumpWordRight(self: *Editor) !void {
        const tab = self.currentTab() orelse return;
        const l = tab.buf.lines.items[tab.cursor_row];
        const line = try l.slice(self.allocator);
        defer self.allocator.free(line);
        if (tab.cursor_col >= line.len) {
            if (tab.cursor_row < tab.buf.lines.items.len - 1) {
                tab.cursor_row += 1;
                tab.cursor_col = 0;
            }
            return;
        }

        // Skip spaces first
        while (tab.cursor_col < line.len and self.getCharClass(line[tab.cursor_col]) == .Space) {
            tab.cursor_col += 1;
        }

        if (tab.cursor_col >= line.len) return;

        const start_class = self.getCharClass(line[tab.cursor_col]);
        while (tab.cursor_col < line.len and self.getCharClass(line[tab.cursor_col]) == start_class) {
            tab.cursor_col += 1;
        }
    }

    const CharClass = enum { Space, Alphanum, Punctuation };

    /// Returns the number of decimal digits needed to represent `n` (minimum 1).
    fn countDigits(n: usize) usize {
        if (n == 0) return 1;
        var v = n;
        var d: usize = 0;
        while (v > 0) : (v /= 10) d += 1;
        return d;
    }

    fn getCharClass(self: *Editor, c: u8) CharClass {
        _ = self;
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') return .Space;
        if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_') return .Alphanum;
        return .Punctuation;
    }

    /// Calculates total gutter width: 1 space + num_digits + 1 space separator.
    pub fn calculateGutterWidth(self: *const Editor, total_lines: usize) usize {
        _ = self;
        return @max(countDigits(total_lines), 2) + 2;
    }
};

test "Editor.calculateGutterWidth" {
    var ctx = context.FlamingoContext{
        .log_level = 0,
        .start_time = 0,
        .config = .{},
    };
    const ed = Editor.init(std.testing.allocator, &ctx);

    // 1-99 lines => 2 digits min => 1 + 2 + 1 = 4
    try std.testing.expectEqual(@as(usize, 4), ed.calculateGutterWidth(5));
    try std.testing.expectEqual(@as(usize, 4), ed.calculateGutterWidth(99));

    // 100-999 lines => 3 digits => 1 + 3 + 1 = 5
    try std.testing.expectEqual(@as(usize, 5), ed.calculateGutterWidth(100));
    try std.testing.expectEqual(@as(usize, 5), ed.calculateGutterWidth(999));
}

pub fn start_editor(allocator: std.mem.Allocator, ctx: *context.FlamingoContext) !void {
    var editor = Editor.init(allocator, ctx);
    defer editor.deinit();
    try editor.run();
}
