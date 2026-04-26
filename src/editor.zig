const std = @import("std");
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

pub const Editor = struct {
    ctx: *context.FlamingoContext,
    allocator: std.mem.Allocator = std.heap.page_allocator,
    mode: EditorMode = .Dashboard,
    dash: dashboard.Dashboard = .{},
    buf: ?buffer.Buffer = null,
    command_buffer: std.ArrayList(u8) = std.ArrayList(u8).empty,
    error_message: ?[]const u8 = null,
    cursor_row: usize = 0,
    cursor_col: usize = 0,
    scroll_row: usize = 0,
    width: usize = 0,
    height: usize = 0,
    should_quit: bool = false,
    tree: ?explorer.Explorer = null,
    explorer_visible: bool = false,
    explorer_focused: bool = false,

    pub fn init(ctx: *context.FlamingoContext) Editor {
        return Editor{
            .ctx = ctx,
        };
    }

    pub fn deinit(self: *Editor) void {
        if (self.buf) |*b| {
            if (b.filename) |f| self.allocator.free(f);
            b.deinit();
        }
        if (self.tree) |*t| {
            t.deinit();
        }
        self.command_buffer.deinit(self.allocator);
    }

    pub fn run(self: *Editor) !void {
        const stdout = std.fs.File.stdout();
        var out_buf: [4096]u8 = undefined;
        var fw = stdout.writer(&out_buf);
        const writer = &fw.interface;

        const stdin = std.fs.File.stdin();

        try terminal.enableRawMode();
        defer terminal.disableRawMode();

        while (!self.should_quit) {
            const size = try terminal.getSize();
            self.width = size.cols;
            self.height = size.rows;

            try terminal.hideCursor(writer);
            try self.render(writer);
            try terminal.showCursor(writer);
            try writer.flush();

            const event = try terminal.readKey(stdin);
            if (event.key == .None) continue;

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
        try writer.flush();
    }

    fn handleInput(self: *Editor, event: terminal.KeyEvent) !void {
        if (self.error_message != null) {
            self.error_message = null;
        }

        const is_ctrl_e = event.ctrl and event.key == .Char and event.char == 'e';
        const is_ctrl_w = event.ctrl and event.key == .Char and event.char == 'w';

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

        if (is_ctrl_w) {
            if (self.explorer_visible) {
                self.explorer_focused = !self.explorer_focused;
            }
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
                                if (self.buf) |*old_b| {
                                    if (old_b.filename) |f| self.allocator.free(f);
                                    old_b.deinit();
                                }
                                self.buf = b;
                                self.cursor_row = 0;
                                self.cursor_col = 0;
                                self.explorer_focused = false;
                                self.mode = .Normal;
                            } else |_| {
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
                        self.buf = try buffer.Buffer.init(self.allocator);
                    },
                    .OpenFile => {
                        self.mode = .OpenFilePrompt;
                        self.command_buffer.clearRetainingCapacity();
                    },
                    .OpenFolder => {
                        self.mode = .Normal;
                        if (self.tree) |*t| {
                            t.deinit();
                        }
                        self.tree = explorer.Explorer.init(self.allocator, ".") catch null;
                        self.explorer_visible = self.tree != null;
                        self.explorer_focused = self.tree != null;
                    },
                    .Quit => self.should_quit = true,
                    else => {},
                }
            },
            .Normal => {
                if (self.handleMovement(event)) {
                    // Handled
                } else if (event.key == .Char and event.char == 'i') {
                    self.mode = .Insert;
                } else if (event.key == .Char and event.char == ':') {
                    self.mode = .Command;
                    self.command_buffer.clearRetainingCapacity();
                }

                // Keep cursor within line bounds
                if (self.buf) |b| {
                    if (self.cursor_row >= b.lines.items.len) {
                        self.cursor_row = b.lines.items.len - 1;
                    }
                    const line = b.lines.items[self.cursor_row];
                    if (self.cursor_col > line.items.len) {
                        self.cursor_col = line.items.len;
                    }
                }
            },
            .Insert => {
                if (self.handleMovement(event)) {
                    // Handled
                } else if (event.key == .Esc) {
                    self.mode = .Normal;
                } else if (event.key == .Enter) {
                    if (self.buf) |*b| {
                        try b.insertNewline(self.cursor_row, self.cursor_col);
                        self.cursor_row += 1;
                        self.cursor_col = 0;
                    }
                } else if (event.key == .Backspace) {
                    if (self.buf) |*b| {
                        const row = self.cursor_row;
                        var prev_len: usize = 0;
                        if (row > 0) {
                            prev_len = b.lines.items[row - 1].items.len;
                        }

                        if (try b.deleteCharBack(self.cursor_row, self.cursor_col)) {
                            self.cursor_row -= 1;
                            self.cursor_col = prev_len;
                        } else {
                            if (self.cursor_col > 0) self.cursor_col -= 1;
                        }
                    }
                } else if (event.key == .Char and !event.ctrl and !event.alt) {
                    if (self.buf) |*b| {
                        if (event.char == '\t') {
                            for (0..4) |_| {
                                try b.insertChar(self.cursor_row, self.cursor_col, ' ');
                                self.cursor_col += 1;
                            }
                        } else {
                            try b.insertChar(self.cursor_row, self.cursor_col, event.char);
                            self.cursor_col += 1;
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
                            if (self.buf) |*old_b| {
                                if (old_b.filename) |f| self.allocator.free(f);
                                old_b.deinit();
                            }
                            self.buf = b;
                            self.mode = .Normal;
                            self.cursor_row = 0;
                            self.cursor_col = 0;
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

    fn executeCommand(self: *Editor) !void {
        if (self.command_buffer.items.len == 0) {
            self.mode = .Normal;
            return;
        }

        var it = std.mem.splitScalar(u8, self.command_buffer.items, ' ');
        const cmd = it.next() orelse return;

        if (std.mem.eql(u8, cmd, "q")) {
            if (self.buf) |b| {
                if (b.is_dirty) {
                    self.error_message = "No write since last change (add ! to override)";
                    self.mode = .Normal;
                    return;
                }
            }
            self.should_quit = true;
        } else if (std.mem.eql(u8, cmd, "q!")) {
            self.should_quit = true;
        } else if (std.mem.eql(u8, cmd, "w")) {
            const filename = it.next();
            if (self.buf) |*b| {
                if (filename) |f| {
                    if (b.filename) |old_f| self.allocator.free(old_f);
                    b.filename = try self.allocator.dupe(u8, f);
                }
                if (b.filename) |f| {
                    b.saveToFile(f) catch {
                        self.error_message = "Failed to save file";
                    };
                } else {
                    self.error_message = "No file name";
                }
            }
            self.mode = .Normal;
        } else if (std.mem.eql(u8, cmd, "wq")) {
            const filename = it.next();
            if (self.buf) |*b| {
                if (filename) |f| {
                    if (b.filename) |old_f| self.allocator.free(old_f);
                    b.filename = try self.allocator.dupe(u8, f);
                }
                if (b.filename) |f| {
                    b.saveToFile(f) catch {
                        self.error_message = "Failed to save file";
                        self.mode = .Normal;
                        return;
                    };
                    self.should_quit = true;
                } else {
                    self.error_message = "No file name";
                    self.mode = .Normal;
                }
            } else {
                self.should_quit = true;
            }
        } else {
            self.error_message = "Not an editor command";
            self.mode = .Normal;
        }
    }

    fn handleMovement(self: *Editor, event: terminal.KeyEvent) bool {
        if (event.key == .Up) {
            if (event.alt) {
                if (self.buf) |b| {
                    self.cursor_col = b.lines.items[self.cursor_row].items.len;
                }
            } else {
                if (self.cursor_row > 0) self.cursor_row -= 1;
                // Clamp col to the new line's length after vertical movement
                if (self.buf) |b| {
                    const new_line_len = b.lines.items[self.cursor_row].items.len;
                    if (self.cursor_col > new_line_len) self.cursor_col = new_line_len;
                }
            }
            self.clampScroll();
            return true;
        } else if (event.key == .Down) {
            if (event.alt) {
                self.cursor_col = 0;
            } else {
                if (self.buf) |b| {
                    if (self.cursor_row < b.lines.items.len - 1) self.cursor_row += 1;
                    // Clamp col to the new line's length after vertical movement
                    const new_line_len = b.lines.items[self.cursor_row].items.len;
                    if (self.cursor_col > new_line_len) self.cursor_col = new_line_len;
                }
            }
            self.clampScroll();
            return true;
        } else if (event.key == .Left) {
            if (event.alt) {
                self.jumpWordLeft();
            } else {
                if (self.cursor_col > 0) self.cursor_col -= 1;
            }
            return true;
        } else if (event.key == .Right) {
            if (event.alt) {
                self.jumpWordRight();
            } else {
                if (self.buf) |b| {
                    const line = b.lines.items[self.cursor_row];
                    if (self.cursor_col < line.items.len) self.cursor_col += 1;
                }
            }
            return true;
        }
        return false;
    }

    /// Adjust scroll_row so cursor_row is always within the visible viewport.
    fn clampScroll(self: *Editor) void {
        const visible_rows = if (self.height > 1) self.height - 1 else 1; // reserve status bar
        if (self.cursor_row < self.scroll_row) {
            self.scroll_row = self.cursor_row;
        } else if (self.cursor_row >= self.scroll_row + visible_rows) {
            self.scroll_row = self.cursor_row - visible_rows + 1;
        }
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

        try terminal.clearScreen(writer);

        var buf_start_col: usize = 1;
        var buf_width: usize = self.width;

        if (self.explorer_visible and self.tree != null) {
            const exp_width = (self.width * @as(usize, self.ctx.config.explorer.width_percentage)) / 100;
            if (exp_width > 0) {
                try self.tree.?.render(writer, exp_width, self.height, self.explorer_focused);
                
                for (1..self.height) |r| {
                    try terminal.moveCursor(writer, r, exp_width + 1);
                    try writer.writeAll("│");
                }
                buf_start_col = exp_width + 2;
                buf_width = self.width -| (exp_width + 1);
            }
        }

        // Hybrid (Vim-style) line number gutter: absolute on current line, relative elsewhere.
        const gutter_width: usize = if (self.buf) |b|
            @max(countDigits(b.lines.items.len), 2) + 2 // digits + " " left-pad + " " separator
        else
            0;

        if (self.buf) |b| {
            const total_lines = b.lines.items.len;
            const num_digits = @max(countDigits(total_lines), 2);
            const content_width = buf_width -| gutter_width;
            const visible_rows = if (self.height > 1) self.height - 1 else 1;
            const first_line = self.scroll_row;
            const last_line = @min(first_line + visible_rows, total_lines);
            for (first_line..last_line) |r| {
                const screen_row = r - first_line + 1;

                // --- Gutter ---
                try terminal.moveCursor(writer, screen_row, buf_start_col);
                const is_current = (r == self.cursor_row);
                const line_num: usize = if (is_current)
                    r + 1 // absolute 1-based
                else if (r > self.cursor_row)
                    r - self.cursor_row
                else
                    self.cursor_row - r;

                if (is_current) {
                    try writer.writeAll("\x1b[33;1m"); // bold yellow — current line
                } else {
                    try writer.writeAll("\x1b[2;37m"); // dim grey  — relative distance
                }
                // Right-align the number inside num_digits columns, then a space separator
                const num_used = countDigits(line_num);
                const pad = num_digits - num_used;
                for (0..pad) |_| try writer.writeByte(' ');
                try writer.print("{d} \x1b[0m", .{line_num});

                // --- Line content ---
                try terminal.moveCursor(writer, screen_row, buf_start_col + gutter_width);
                const line = b.lines.items[r];
                if (line.items.len > content_width) {
                    try writer.writeAll(line.items[0..content_width]);
                } else {
                    try writer.writeAll(line.items);
                }
            }
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
            try writer.print(" {s} | Row: {d}, Col: {d} ", .{ mode_str, self.cursor_row + 1, self.cursor_col + 1 });

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
        } else {
            // Offset cursor past the line-number gutter
            const content_width = buf_width -| gutter_width;
            const vis_col = if (self.cursor_col > content_width) content_width else self.cursor_col;
            const vis_row = self.cursor_row - self.scroll_row + 1;
            try terminal.moveCursor(writer, vis_row, buf_start_col + gutter_width + vis_col);
        }
    }

    fn jumpWordLeft(self: *Editor) void {
        if (self.buf) |b| {
            if (self.cursor_col == 0) {
                if (self.cursor_row > 0) {
                    self.cursor_row -= 1;
                    self.cursor_col = b.lines.items[self.cursor_row].items.len;
                }
                return;
            }
            const line = b.lines.items[self.cursor_row].items;
            
            // Skip spaces first (moving left)
            while (self.cursor_col > 0 and self.getCharClass(line[self.cursor_col - 1]) == .Space) {
                self.cursor_col -= 1;
            }
            
            if (self.cursor_col == 0) return;
            
            const start_class = self.getCharClass(line[self.cursor_col - 1]);
            while (self.cursor_col > 0 and self.getCharClass(line[self.cursor_col - 1]) == start_class) {
                self.cursor_col -= 1;
            }
        }
    }

    fn jumpWordRight(self: *Editor) void {
        if (self.buf) |b| {
            const line = b.lines.items[self.cursor_row].items;
            if (self.cursor_col >= line.len) {
                if (self.cursor_row < b.lines.items.len - 1) {
                    self.cursor_row += 1;
                    self.cursor_col = 0;
                }
                return;
            }
            
            // Skip spaces first
            while (self.cursor_col < line.len and self.getCharClass(line[self.cursor_col]) == .Space) {
                self.cursor_col += 1;
            }
            
            if (self.cursor_col >= line.len) return;
            
            const start_class = self.getCharClass(line[self.cursor_col]);
            while (self.cursor_col < line.len and self.getCharClass(line[self.cursor_col]) == start_class) {
                self.cursor_col += 1;
            }
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
};

pub fn start_editor(ctx: *context.FlamingoContext) !void {
    var editor = Editor.init(ctx);
    defer editor.deinit();
    try editor.run();
}
