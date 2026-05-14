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
    output_lines: std.ArrayListUnmanaged([]u8) = .empty,
    current_line: std.ArrayListUnmanaged(u8) = .empty,
    scroll_offset: usize = 0,
    cursor_col: usize = 0,
    escape_state: EscapeState = .none,
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

    pub fn ensureStarted(self: *TerminalPanel, queue: *event_queue.EventQueue) !void {
        if (self.backend.isStarted()) return;
        if (!self.backend_enabled) return;
        if (!supports_pty) {
            if (!self.unsupported_reported) {
                try self.appendOutput("Integrated terminal is not supported on this platform.\n");
                self.unsupported_reported = true;
            }
            return;
        }
        self.backend.start(self.allocator, queue) catch |err| {
            try self.appendOutput("Failed to start integrated terminal: ");
            try self.appendOutput(@errorName(err));
            try self.appendOutput("\n");
        };
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
        return self.output_lines.items.len + if (self.current_line.items.len > 0) @as(usize, 1) else 0;
    }

    pub fn renderLineAt(self: *const TerminalPanel, index: usize) ?[]const u8 {
        if (index < self.output_lines.items.len) return self.output_lines.items[index];
        if (index == self.output_lines.items.len and self.current_line.items.len > 0) return self.current_line.items;
        return null;
    }

    fn clearOutput(self: *TerminalPanel) void {
        for (self.output_lines.items) |line| {
            self.allocator.free(line);
        }
        self.output_lines.deinit(self.allocator);
        self.output_lines = .empty;
        self.current_line.clearRetainingCapacity();
        self.cursor_col = 0;
        self.scroll_offset = 0;
        self.escape_state = .none;
    }

    fn appendOutputByte(self: *TerminalPanel, byte: u8) !void {
        switch (self.escape_state) {
            .none => {},
            .esc => {
                self.escape_state = switch (byte) {
                    '[' => .csi,
                    ']' => .osc,
                    else => .none,
                };
                return;
            },
            .csi => {
                if (byte >= 0x40 and byte <= 0x7e) self.escape_state = .none;
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
        if (self.cursor_col < self.current_line.items.len) {
            self.current_line.items[self.cursor_col] = byte;
        } else {
            while (self.cursor_col > self.current_line.items.len) {
                try self.current_line.append(self.allocator, ' ');
            }
            try self.current_line.append(self.allocator, byte);
        }
        self.cursor_col += 1;
    }

    fn backspaceCurrentLine(self: *TerminalPanel) void {
        if (self.cursor_col == 0) return;
        self.cursor_col -= 1;
        if (self.cursor_col >= self.current_line.items.len) return;
        const len = self.current_line.items.len;
        std.mem.copyForwards(u8, self.current_line.items[self.cursor_col .. len - 1], self.current_line.items[self.cursor_col + 1 .. len]);
        self.current_line.shrinkRetainingCapacity(len - 1);
    }

    fn commitCurrentLine(self: *TerminalPanel) !void {
        const owned = try self.allocator.dupe(u8, self.current_line.items);
        errdefer self.allocator.free(owned);
        try self.output_lines.append(self.allocator, owned);
        self.current_line.clearRetainingCapacity();
        self.cursor_col = 0;
        try self.enforceScrollbackLimit();
    }

    fn enforceScrollbackLimit(self: *TerminalPanel) !void {
        while (self.output_lines.items.len > max_scrollback_lines) {
            const old = self.output_lines.orderedRemove(0);
            self.allocator.free(old);
            if (self.scroll_offset > 0) self.scroll_offset -= 1;
        }
    }
};

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

    fn isStarted(self: *const Backend) bool {
        return self.started;
    }

    fn start(self: *Backend, allocator: std.mem.Allocator, queue: *event_queue.EventQueue) !void {
        if (!supports_pty) return TerminalError.UnsupportedPlatform;
        if (self.started) return;

        self.allocator = allocator;
        self.queue = queue;
        self.quit.store(false, .seq_cst);

        var master_fd: PtyFd = -1;
        const child_pid = c.forkpty(&master_fd, null, null, null);
        if (child_pid < 0) return TerminalError.PtySpawnFailed;
        if (child_pid == 0) childExecShell();

        self.master_fd = master_fd;
        self.pid = child_pid;
        self.started = true;
        errdefer self.stop();

        self.reader_thread = try std.Thread.spawn(.{}, readerLoop, .{self});
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

test "TerminalPanel sanitizes output and tracks current line" {
    var panel = TerminalPanel.init(std.testing.allocator);
    defer panel.deinit();

    try panel.appendOutput("hello\nwor\x1b[31mld\rWORLD\x08!\nnext");

    try std.testing.expectEqual(@as(usize, 2), panel.output_lines.items.len);
    try std.testing.expectEqualStrings("hello", panel.output_lines.items[0]);
    try std.testing.expectEqualStrings("WORL!", panel.output_lines.items[1]);
    try std.testing.expectEqualStrings("next", panel.current_line.items);
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
