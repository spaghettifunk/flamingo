const std = @import("std");
const builtin = @import("builtin");
const terminal = @import("../terminal.zig");
const event_queue = @import("runtime/event_queue.zig");

pub const max_scrollback_lines = 1000;

const supports_pty = builtin.os.tag == .linux or builtin.os.tag == .macos;
const PtyFd = if (supports_pty) std.c.fd_t else i32;
const PtyPid = if (supports_pty) std.c.pid_t else i32;

const c = if (supports_pty) struct {
    extern "c" fn forkpty(
        amaster: *PtyFd,
        name: ?[*:0]u8,
        termp: ?*const anyopaque,
        winp: ?*const anyopaque,
    ) PtyPid;
} else struct {};

const EscapeState = enum {
    none,
    esc,
    csi,
    osc,
};

pub const AnsiColor = enum(u8) {
    black,
    red,
    green,
    yellow,
    blue,
    magenta,
    cyan,
    white,
    bright_black,
    bright_red,
    bright_green,
    bright_yellow,
    bright_blue,
    bright_magenta,
    bright_cyan,
    bright_white,
};

pub const TerminalStyle = struct {
    fg: ?AnsiColor = null,
    bg: ?AnsiColor = null,
    bold: bool = false,

    pub fn eql(self: TerminalStyle, other: TerminalStyle) bool {
        return self.fg == other.fg and self.bg == other.bg and self.bold == other.bold;
    }
};

pub const TerminalCell = struct {
    ch: u8 = ' ',
    style: TerminalStyle = .{},
};

pub const TerminalLine = struct {
    cells: std.ArrayListUnmanaged(TerminalCell) = .empty,

    fn deinit(self: *TerminalLine, allocator: std.mem.Allocator) void {
        self.cells.deinit(allocator);
        self.* = .{};
    }

    fn clearRetainingCapacity(self: *TerminalLine) void {
        self.cells.clearRetainingCapacity();
    }

    fn len(self: *const TerminalLine) usize {
        return self.cells.items.len;
    }

    fn put(self: *TerminalLine, allocator: std.mem.Allocator, col: usize, cell: TerminalCell) !void {
        while (self.cells.items.len < col) {
            try self.cells.append(allocator, .{});
        }
        if (col < self.cells.items.len) {
            self.cells.items[col] = cell;
        } else {
            try self.cells.append(allocator, cell);
        }
    }

    fn truncateFrom(self: *TerminalLine, col: usize) void {
        if (col < self.cells.items.len) {
            self.cells.shrinkRetainingCapacity(col);
        }
    }

    fn removeBefore(self: *TerminalLine, col: usize) void {
        if (col == 0 or col > self.cells.items.len) return;
        std.mem.copyForwards(TerminalCell, self.cells.items[col - 1 .. self.cells.items.len - 1], self.cells.items[col..]);
        self.cells.shrinkRetainingCapacity(self.cells.items.len - 1);
    }

    fn toOwned(self: *TerminalLine, allocator: std.mem.Allocator) !TerminalLine {
        return .{ .cells = .{ .items = try allocator.dupe(TerminalCell, self.cells.items), .capacity = self.cells.items.len } };
    }

    pub fn plainText(self: *const TerminalLine, allocator: std.mem.Allocator) ![]u8 {
        const out = try allocator.alloc(u8, self.cells.items.len);
        for (self.cells.items, 0..) |cell, i| out[i] = cell.ch;
        return out;
    }
};

pub const TerminalError = error{
    UnsupportedPlatform,
    PtySpawnFailed,
    TerminalNotStarted,
    WriteFailed,
};

pub const TerminalPanel = struct {
    allocator: std.mem.Allocator,
    visible: bool = false,
    focused: bool = false,
    output_lines: std.ArrayListUnmanaged(TerminalLine) = .empty,
    current_line: TerminalLine = .{},
    scroll_offset: usize = 0,
    cursor_col: usize = 0,
    saved_cursor_col: usize = 0,
    escape_state: EscapeState = .none,
    csi_buf: [64]u8 = undefined,
    csi_len: usize = 0,
    current_style: TerminalStyle = .{},
    unsupported_reported: bool = false,
    backend_enabled: bool = !builtin.is_test,
    backend: Backend = .{},

    pub fn init(allocator: std.mem.Allocator) TerminalPanel {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *TerminalPanel) void {
        self.backend.stop();
        self.clearOutput();
        self.current_line.deinit(self.allocator);
        self.* = init(self.allocator);
    }

    pub fn show(self: *TerminalPanel) !void {
        self.visible = true;
    }

    pub fn hide(self: *TerminalPanel) void {
        self.visible = false;
        self.blur();
    }

    pub fn toggle(self: *TerminalPanel) !void {
        if (self.visible) {
            self.hide();
        } else {
            try self.show();
            self.focus();
        }
    }

    pub fn focus(self: *TerminalPanel) void {
        self.visible = true;
        self.focused = true;
    }

    pub fn blur(self: *TerminalPanel) void {
        self.focused = false;
    }

    pub fn ensureStarted(self: *TerminalPanel, queue: *event_queue.EventQueue, cols: usize, rows: usize) !void {
        if (self.backend.isStarted()) return;
        if (!self.backend_enabled) return;
        if (!supports_pty) {
            if (!self.unsupported_reported) {
                try self.appendOutput("Integrated terminal is not supported on this platform.\n");
                self.unsupported_reported = true;
            }
            return;
        }
        self.backend.start(self.allocator, queue, cols, rows) catch |err| {
            try self.appendOutput("Failed to start integrated terminal: ");
            try self.appendOutput(@errorName(err));
            try self.appendOutput("\n");
        };
    }

    pub fn resizePty(self: *TerminalPanel, cols: usize, rows: usize) void {
        self.backend.resize(cols, rows);
    }

    pub fn markExited(self: *TerminalPanel, code: ?i32) !void {
        self.backend.markExited();
        try self.appendOutput("\n[terminal exited");
        if (code) |value| {
            var buf: [32]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, " {d}", .{value}) catch "";
            try self.appendOutput(text);
        }
        try self.appendOutput("]\n");
    }

    pub fn appendOutput(self: *TerminalPanel, bytes: []const u8) !void {
        for (bytes) |byte| {
            try self.appendOutputByte(byte);
        }
    }

    pub fn writeInput(self: *TerminalPanel, bytes: []const u8) !void {
        try self.backend.write(bytes);
    }

    pub fn renderLineCount(self: *const TerminalPanel) usize {
        return self.output_lines.items.len + 1;
    }

    pub fn renderLineAt(self: *const TerminalPanel, index: usize) ?*const TerminalLine {
        if (index < self.output_lines.items.len) return &self.output_lines.items[index];
        if (index == self.output_lines.items.len) return &self.current_line;
        return null;
    }

    pub fn cursorRenderIndex(self: *const TerminalPanel) usize {
        return self.output_lines.items.len;
    }

    pub fn clampScroll(self: *TerminalPanel, body_height: usize) void {
        const max_offset = self.maxScrollOffset(body_height);
        if (self.scroll_offset > max_offset) self.scroll_offset = max_offset;
    }

    pub fn scrollUp(self: *TerminalPanel, amount: usize, body_height: usize) void {
        self.scroll_offset = @min(self.scroll_offset + amount, self.maxScrollOffset(body_height));
    }

    pub fn scrollDown(self: *TerminalPanel, amount: usize, body_height: usize) void {
        self.scroll_offset -|= amount;
        self.clampScroll(body_height);
    }

    pub fn scrollToBottom(self: *TerminalPanel) void {
        self.scroll_offset = 0;
    }

    fn maxScrollOffset(self: *const TerminalPanel, body_height: usize) usize {
        const total = self.renderLineCount();
        return total -| @max(body_height, @as(usize, 1));
    }

    fn clearOutput(self: *TerminalPanel) void {
        for (self.output_lines.items) |*line| {
            line.deinit(self.allocator);
        }
        self.output_lines.deinit(self.allocator);
        self.output_lines = .empty;
        self.current_line.clearRetainingCapacity();
        self.cursor_col = 0;
        self.saved_cursor_col = 0;
        self.scroll_offset = 0;
        self.escape_state = .none;
        self.csi_len = 0;
        self.current_style = .{};
    }

    fn appendOutputByte(self: *TerminalPanel, byte: u8) !void {
        switch (self.escape_state) {
            .none => {},
            .esc => {
                self.escape_state = switch (byte) {
                    '[' => blk: {
                        self.csi_len = 0;
                        break :blk .csi;
                    },
                    ']' => .osc,
                    '7' => blk: {
                        self.saved_cursor_col = self.cursor_col;
                        break :blk .none;
                    },
                    '8' => blk: {
                        self.cursor_col = self.saved_cursor_col;
                        break :blk .none;
                    },
                    else => .none,
                };
                return;
            },
            .csi => {
                if (byte >= 0x40 and byte <= 0x7e) {
                    try self.applyCsi(byte, self.csi_buf[0..self.csi_len]);
                    self.escape_state = .none;
                    self.csi_len = 0;
                } else {
                    if (self.csi_len < self.csi_buf.len) {
                        self.csi_buf[self.csi_len] = byte;
                        self.csi_len += 1;
                    }
                }
                return;
            },
            .osc => {
                if (byte == 0x07) {
                    self.escape_state = .none;
                } else if (byte == 0x1b) {
                    self.escape_state = .esc;
                }
                return;
            },
        }

        switch (byte) {
            0x1b => self.escape_state = .esc,
            '\n' => try self.commitCurrentLine(),
            '\r' => self.cursor_col = 0,
            0x08, 0x7f => self.backspaceCurrentLine(),
            '\t' => {
                const spaces = 4 - (self.cursor_col % 4);
                for (0..spaces) |_| try self.putCurrentByte(' ');
            },
            0x20...0x7e => try self.putCurrentByte(byte),
            else => {},
        }
    }

    fn putCurrentByte(self: *TerminalPanel, byte: u8) !void {
        try self.current_line.put(self.allocator, self.cursor_col, .{ .ch = byte, .style = self.current_style });
        self.cursor_col += 1;
    }

    fn backspaceCurrentLine(self: *TerminalPanel) void {
        if (self.cursor_col == 0) return;
        self.cursor_col -= 1;
    }

    fn commitCurrentLine(self: *TerminalPanel) !void {
        const owned = try self.current_line.toOwned(self.allocator);
        errdefer {
            var line = owned;
            line.deinit(self.allocator);
        }
        try self.output_lines.append(self.allocator, owned);
        self.current_line.clearRetainingCapacity();
        self.cursor_col = 0;
        try self.enforceScrollbackLimit();
    }

    fn enforceScrollbackLimit(self: *TerminalPanel) !void {
        while (self.output_lines.items.len > max_scrollback_lines) {
            var old = self.output_lines.orderedRemove(0);
            old.deinit(self.allocator);
            if (self.scroll_offset > 0) self.scroll_offset -= 1;
        }
    }

    fn applyCsi(self: *TerminalPanel, final: u8, raw_params: []const u8) !void {
        var params_buf: [16]usize = undefined;
        const params = parseCsiParams(raw_params, &params_buf);
        const first = if (params.len > 0) params[0] else 0;

        switch (final) {
            'm' => self.applySgr(raw_params, params),
            'K' => {
                if (first == 0) self.current_line.truncateFrom(self.cursor_col);
                if (first == 2) {
                    self.current_line.clearRetainingCapacity();
                    self.cursor_col = 0;
                }
            },
            'G' => self.cursor_col = if (first > 0) first - 1 else 0,
            'C' => self.cursor_col += if (first > 0) first else 1,
            'D' => self.cursor_col -|= if (first > 0) first else 1,
            'A' => {},
            'B' => {},
            's' => self.saved_cursor_col = self.cursor_col,
            'u' => self.cursor_col = self.saved_cursor_col,
            'J' => {
                if (first == 2 or first == 3) self.clearOutput();
            },
            else => {},
        }
    }

    fn applySgr(self: *TerminalPanel, raw_params: []const u8, params: []const usize) void {
        if (raw_params.len == 0) {
            self.current_style = .{};
            return;
        }
        for (params) |param| {
            switch (param) {
                0 => self.current_style = .{},
                1 => self.current_style.bold = true,
                22 => self.current_style.bold = false,
                30...37 => self.current_style.fg = @enumFromInt(param - 30),
                90...97 => self.current_style.fg = @enumFromInt(param - 90 + 8),
                39 => self.current_style.fg = null,
                40...47 => self.current_style.bg = @enumFromInt(param - 40),
                100...107 => self.current_style.bg = @enumFromInt(param - 100 + 8),
                49 => self.current_style.bg = null,
                else => {},
            }
        }
    }
};

fn parseCsiParams(raw: []const u8, out: *[16]usize) []const usize {
    var count: usize = 0;
    var value: usize = 0;
    var saw_digit = false;
    for (raw) |byte| {
        switch (byte) {
            '0'...'9' => {
                saw_digit = true;
                value = value * 10 + (byte - '0');
            },
            ';' => {
                if (count < out.len) {
                    out[count] = if (saw_digit) value else 0;
                    count += 1;
                }
                value = 0;
                saw_digit = false;
            },
            '?', '>', '=' => {},
            else => {},
        }
    }
    if (saw_digit or raw.len == 0 or (raw.len > 0 and raw[raw.len - 1] == ';')) {
        if (count < out.len) {
            out[count] = if (saw_digit) value else 0;
            count += 1;
        }
    }
    return out[0..count];
}

pub fn panelHeight(screen_height: usize) usize {
    if (screen_height < 6) return 0;
    const desired = @min(@as(usize, 12), screen_height / 3);
    const max_panel = screen_height -| 4;
    return @min(@max(desired, @as(usize, 3)), max_panel);
}

pub fn keyEventToInput(event: terminal.KeyEvent, scratch: *[16]u8) ?[]const u8 {
    if (event.key == .Char and event.ctrl) {
        if (event.char >= 'a' and event.char <= 'z') {
            scratch[0] = event.char - 'a' + 1;
            return scratch[0..1];
        }
        if (event.char >= '@' and event.char <= '_') {
            scratch[0] = event.char & 0x1f;
            return scratch[0..1];
        }
        if (event.char == ' ') {
            scratch[0] = 0;
            return scratch[0..1];
        }
        return null;
    }

    switch (event.key) {
        .Char => {
            if (event.alt) return null;
            scratch[0] = event.char;
            return scratch[0..1];
        },
        .Enter => return "\r",
        .Backspace => return "\x7f",
        .Up => return "\x1b[A",
        .Down => return "\x1b[B",
        .Right => return "\x1b[C",
        .Left => return "\x1b[D",
        .Home => return "\x1b[H",
        .End => return "\x1b[F",
        .Delete => return "\x1b[3~",
        else => return null,
    }
}

const Backend = struct {
    allocator: ?std.mem.Allocator = null,
    queue: ?*event_queue.EventQueue = null,
    master_fd: ?PtyFd = null,
    pid: ?PtyPid = null,
    reader_thread: ?std.Thread = null,
    quit: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    started: bool = false,
    cols: usize = 0,
    rows: usize = 0,

    fn isStarted(self: *const Backend) bool {
        return self.started;
    }

    fn start(self: *Backend, allocator: std.mem.Allocator, queue: *event_queue.EventQueue, cols: usize, rows: usize) !void {
        if (!supports_pty) return TerminalError.UnsupportedPlatform;
        if (self.started) return;

        self.allocator = allocator;
        self.queue = queue;
        self.quit.store(false, .seq_cst);

        var master_fd: PtyFd = -1;
        var win_size = makeWinSize(cols, rows);
        const child_pid = c.forkpty(&master_fd, null, null, &win_size);
        if (child_pid < 0) return TerminalError.PtySpawnFailed;
        if (child_pid == 0) childExecShell();

        self.master_fd = master_fd;
        self.pid = child_pid;
        self.started = true;
        self.cols = @max(cols, 1);
        self.rows = @max(rows, 1);
        errdefer self.stop();

        self.reader_thread = try std.Thread.spawn(.{}, readerLoop, .{self});
    }

    fn resize(self: *Backend, cols: usize, rows: usize) void {
        if (!supports_pty or !self.started) return;
        const fd = self.master_fd orelse return;
        const normalized_cols = @max(cols, @as(usize, 1));
        const normalized_rows = @max(rows, @as(usize, 1));
        if (self.cols == normalized_cols and self.rows == normalized_rows) return;

        var win_size = makeWinSize(normalized_cols, normalized_rows);
        _ = std.posix.system.ioctl(fd, tiocswinsz(), @intFromPtr(&win_size));
        self.cols = normalized_cols;
        self.rows = normalized_rows;
    }

    fn stop(self: *Backend) void {
        if (!supports_pty or !self.started) return;

        self.quit.store(true, .seq_cst);
        if (self.pid) |pid| {
            signalProcessGroup(pid, .HUP);
            signalProcessGroup(pid, .TERM);
        }
        if (self.master_fd) |fd| {
            _ = std.c.close(fd);
            self.master_fd = null;
        }
        if (self.pid) |pid| {
            if (!waitForChild(pid)) {
                signalProcessGroup(pid, .KILL);
                waitForChildBlocking(pid);
            }
            self.pid = null;
        }
        if (self.reader_thread) |thread| {
            thread.join();
            self.reader_thread = null;
        }
        self.started = false;
        self.allocator = null;
        self.queue = null;
        self.cols = 0;
        self.rows = 0;
    }

    fn markExited(self: *Backend) void {
        if (!supports_pty or !self.started) return;
        if (self.reader_thread) |thread| {
            thread.join();
            self.reader_thread = null;
        }
        if (self.master_fd) |fd| {
            _ = std.c.close(fd);
            self.master_fd = null;
        }
        if (self.pid) |pid| {
            var status: c_int = 0;
            const waited = std.c.waitpid(pid, &status, std.c.W.NOHANG);
            if (waited == pid) self.pid = null;
        }
        if (self.pid == null) {
            self.started = false;
            self.allocator = null;
            self.queue = null;
            self.cols = 0;
            self.rows = 0;
        }
    }

    fn write(self: *Backend, bytes: []const u8) !void {
        if (!supports_pty) return TerminalError.UnsupportedPlatform;
        const fd = self.master_fd orelse return TerminalError.TerminalNotStarted;

        var written: usize = 0;
        while (written < bytes.len) {
            const n = std.c.write(fd, bytes[written..].ptr, bytes.len - written);
            if (n <= 0) return TerminalError.WriteFailed;
            written += @intCast(n);
        }
    }

    fn readerLoop(self: *Backend) void {
        if (!supports_pty) return;
        const fd = self.master_fd orelse return;
        const allocator = self.allocator orelse return;
        const queue = self.queue orelse return;

        var buf: [4096]u8 = undefined;
        while (!self.quit.load(.seq_cst)) {
            const n = std.c.read(fd, buf[0..].ptr, buf.len);
            if (n <= 0) break;
            const len: usize = @intCast(n);
            const owned = allocator.dupe(u8, buf[0..len]) catch break;
            queue.push(.{ .terminal_output = .{ .bytes = owned } }) catch {
                allocator.free(owned);
                break;
            };
        }

        if (!self.quit.load(.seq_cst)) {
            queue.push(.{ .terminal_exit = .{ .code = null } }) catch {};
        }
    }
};

fn makeWinSize(cols: usize, rows: usize) std.posix.winsize {
    return .{
        .row = @intCast(@min(@max(rows, @as(usize, 1)), std.math.maxInt(u16))),
        .col = @intCast(@min(@max(cols, @as(usize, 1)), std.math.maxInt(u16))),
        .xpixel = 0,
        .ypixel = 0,
    };
}

fn tiocswinsz() c_int {
    return switch (builtin.os.tag) {
        .linux => @bitCast(@as(u32, std.posix.T.IOCSWINSZ)),
        .macos => @bitCast(@as(u32, 0x80087467)),
        else => 0,
    };
}

fn signalProcessGroup(pid: PtyPid, sig: std.posix.SIG) void {
    if (!supports_pty or pid <= 0) return;
    std.posix.kill(-pid, sig) catch {
        std.posix.kill(pid, sig) catch {};
    };
}

fn waitForChild(pid: PtyPid) bool {
    if (!supports_pty) return true;

    for (0..20) |_| {
        var status: c_int = 0;
        const waited = std.c.waitpid(pid, &status, std.c.W.NOHANG);
        if (waited == pid or waited == -1) return true;
        sleepForChildPoll();
    }
    return false;
}

fn waitForChildBlocking(pid: PtyPid) void {
    if (!supports_pty) return;
    var status: c_int = 0;
    _ = std.c.waitpid(pid, &status, 0);
}

fn sleepForChildPoll() void {
    if (!supports_pty) return;
    const req = std.c.timespec{
        .sec = 0,
        .nsec = 10 * std.time.ns_per_ms,
    };
    _ = std.c.nanosleep(&req, null);
}

fn childExecShell() noreturn {
    const shell = shellPath();
    const argv = [_:null]?[*:0]const u8{ shell, null };
    const envp: [*:null]const ?[*:0]const u8 = @ptrCast(std.c.environ);
    _ = std.c.execve(shell, &argv, envp);
    std.c._exit(127);
}

fn shellPath() [*:0]const u8 {
    const shell = std.c.getenv("SHELL") orelse return "/bin/sh";
    if (std.mem.len(shell) == 0) return "/bin/sh";
    return shell;
}

test "TerminalPanel starts hidden and tracks focus transitions" {
    var panel = TerminalPanel.init(std.testing.allocator);
    defer panel.deinit();

    try std.testing.expect(!panel.visible);
    try std.testing.expect(!panel.focused);

    try panel.show();
    panel.focus();
    try std.testing.expect(panel.visible);
    try std.testing.expect(panel.focused);

    panel.blur();
    try std.testing.expect(panel.visible);
    try std.testing.expect(!panel.focused);

    panel.hide();
    try std.testing.expect(!panel.visible);
    try std.testing.expect(!panel.focused);
}

test "terminal panel height reserves bounded bottom space" {
    try std.testing.expectEqual(@as(usize, 8), panelHeight(24));
    try std.testing.expectEqual(@as(usize, 12), panelHeight(60));
    try std.testing.expectEqual(@as(usize, 0), panelHeight(5));
    try std.testing.expectEqual(@as(usize, 3), panelHeight(9));
}

fn expectLineText(line: *const TerminalLine, expected: []const u8) !void {
    const text = try line.plainText(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings(expected, text);
}

test "TerminalPanel sanitizes output and tracks current line" {
    var panel = TerminalPanel.init(std.testing.allocator);
    defer panel.deinit();

    try panel.appendOutput("hello\nwor\x1b[31mld\rWORLD\x08!\nnext");

    try std.testing.expectEqual(@as(usize, 2), panel.output_lines.items.len);
    try expectLineText(&panel.output_lines.items[0], "hello");
    try expectLineText(&panel.output_lines.items[1], "WORL!");
    try expectLineText(&panel.current_line, "next");
    try std.testing.expectEqual(AnsiColor.red, panel.output_lines.items[1].cells.items[3].style.fg.?);
}

test "TerminalPanel handles cursor movement and clear line escapes" {
    var panel = TerminalPanel.init(std.testing.allocator);
    defer panel.deinit();

    try panel.appendOutput("abcdef\rXY\x1b[K");

    try expectLineText(&panel.current_line, "XY");
    try std.testing.expectEqual(@as(usize, 2), panel.cursor_col);
}

test "TerminalPanel preserves right prompt cells while typing at restored cursor" {
    var panel = TerminalPanel.init(std.testing.allocator);
    defer panel.deinit();

    try panel.appendOutput("prompt ");
    try panel.appendOutput("\x1b[s\x1b[20G[fc4e3b5]\x1b[u");
    try panel.appendOutput("echo");

    try std.testing.expectEqual(@as(usize, 11), panel.cursor_col);
    try expectLineText(&panel.current_line, "prompt echo        [fc4e3b5]");
}

test "TerminalPanel backspace does not shift right prompt cells left" {
    var panel = TerminalPanel.init(std.testing.allocator);
    defer panel.deinit();

    try panel.appendOutput("prompt abc");
    try panel.appendOutput("\x1b[s\x1b[20G[fc4e3b5]\x1b[u");
    panel.backspaceCurrentLine();
    try panel.appendOutput(" ");
    panel.backspaceCurrentLine();

    try std.testing.expectEqual(@as(usize, 9), panel.cursor_col);
    try expectLineText(&panel.current_line, "prompt ab          [fc4e3b5]");
}

test "TerminalPanel handles basic SGR color and reset" {
    var panel = TerminalPanel.init(std.testing.allocator);
    defer panel.deinit();

    try panel.appendOutput("\x1b[31mred\x1b[0m normal");

    try expectLineText(&panel.current_line, "red normal");
    try std.testing.expectEqual(AnsiColor.red, panel.current_line.cells.items[0].style.fg.?);
    try std.testing.expect(panel.current_line.cells.items[0].style.fg == panel.current_line.cells.items[2].style.fg);
    try std.testing.expect(panel.current_line.cells.items[4].style.fg == null);
}

test "TerminalPanel clamps and updates scrollback offset" {
    var panel = TerminalPanel.init(std.testing.allocator);
    defer panel.deinit();

    try panel.appendOutput("one\ntwo\nthree\nfour\n");
    panel.scrollUp(10, 2);
    try std.testing.expectEqual(@as(usize, 3), panel.scroll_offset);
    panel.scrollDown(1, 2);
    try std.testing.expectEqual(@as(usize, 2), panel.scroll_offset);
    panel.scrollToBottom();
    try std.testing.expectEqual(@as(usize, 0), panel.scroll_offset);
}

test "TerminalPanel caps scrollback at max lines" {
    var panel = TerminalPanel.init(std.testing.allocator);
    defer panel.deinit();

    for (0..max_scrollback_lines + 5) |_| {
        try panel.appendOutput("x\n");
    }

    try std.testing.expectEqual(@as(usize, max_scrollback_lines), panel.output_lines.items.len);
}

test "terminal input byte mapping covers common shell keys" {
    var scratch: [16]u8 = undefined;

    try std.testing.expectEqualStrings("a", keyEventToInput(.{ .key = .Char, .char = 'a' }, &scratch).?);
    try std.testing.expectEqualStrings("\r", keyEventToInput(.{ .key = .Enter }, &scratch).?);
    try std.testing.expectEqualStrings("\x7f", keyEventToInput(.{ .key = .Backspace }, &scratch).?);
    try std.testing.expectEqualStrings("\x03", keyEventToInput(.{ .key = .Char, .char = 'c', .ctrl = true }, &scratch).?);
    try std.testing.expectEqualStrings("\x04", keyEventToInput(.{ .key = .Char, .char = 'd', .ctrl = true }, &scratch).?);
    try std.testing.expectEqualStrings("\x1b[A", keyEventToInput(.{ .key = .Up }, &scratch).?);
    try std.testing.expectEqualStrings("\x1b[3~", keyEventToInput(.{ .key = .Delete }, &scratch).?);
}
