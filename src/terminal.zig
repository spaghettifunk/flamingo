const std = @import("std");

pub const Key = enum {
    None,
    Backspace,
    Enter,
    Esc,
    Up,
    Down,
    Right,
    Left,
    Delete,
    Home,
    End,
    PageUp,
    PageDown,
    Char,
};

pub const KeyEvent = struct {
    key: Key = .None,
    char: u8 = 0,
    ctrl: bool = false,
    alt: bool = false,
    shift: bool = false,

    pub fn eql(self: KeyEvent, other: KeyEvent) bool {
        return self.key == other.key and
            self.char == other.char and
            self.ctrl == other.ctrl and
            self.alt == other.alt and
            self.shift == other.shift;
    }
};

pub fn parseKeyChord(chord: []const u8) KeyEvent {
    var event = KeyEvent{};
    if (std.mem.eql(u8, chord, "up")) {
        event.key = .Up;
    } else if (std.mem.eql(u8, chord, "down")) {
        event.key = .Down;
    } else if (std.mem.eql(u8, chord, "left")) {
        event.key = .Left;
    } else if (std.mem.eql(u8, chord, "right")) {
        event.key = .Right;
    } else if (std.mem.eql(u8, chord, "esc")) {
        event.key = .Esc;
    } else if (std.mem.eql(u8, chord, "enter")) {
        event.key = .Enter;
    } else if (std.mem.eql(u8, chord, "backspace")) {
        event.key = .Backspace;
    } else {
        // Parse modifiers: ctrl+n, alt+p
        var it = std.mem.splitScalar(u8, chord, '+');
        var last_part: ?[]const u8 = null;
        while (it.next()) |part| {
            if (std.mem.eql(u8, part, "ctrl")) {
                event.ctrl = true;
            } else if (std.mem.eql(u8, part, "alt")) {
                event.alt = true;
            } else if (std.mem.eql(u8, part, "shift")) {
                event.shift = true;
            } else {
                last_part = part;
            }
        }
        if (last_part) |part| {
            if (part.len == 1) {
                event.key = .Char;
                event.char = part[0];
            } else if (std.mem.eql(u8, part, "tab")) {
                event.key = .Char;
                event.char = '\t';
            }
        }
    }
    return event;
}

var orig_termios: ?std.posix.termios = null;

pub fn enableRawMode() !void {
    const fd = std.posix.STDIN_FILENO;
    const termios = try std.posix.tcgetattr(fd);
    orig_termios = termios;

    var raw = termios;

    // input flags: no break, no CR to NL, no parity check, no strip char, no start/stop output control
    raw.iflag.BRKINT = false;
    raw.iflag.ICRNL = false;
    raw.iflag.INPCK = false;
    raw.iflag.ISTRIP = false;
    raw.iflag.IXON = false;

    // output flags: disable post processing
    raw.oflag.OPOST = false;

    // local flags: choing off, canonical off, no extended functions, no signal chars (^Z,^C)
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.IEXTEN = false;
    raw.lflag.ISIG = false;

    raw.cc[@intFromEnum(std.posix.V.MIN)] = 0;
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 1; // 100ms timeout

    try std.posix.tcsetattr(fd, .FLUSH, raw);

    var stdout = std.fs.File.stdout();
    try stdout.writeAll("\x1b[?1049h"); // enter alt screen
    try stdout.writeAll("\x1b[?25l"); // hide cursor
}

pub fn disableRawMode() void {
    if (orig_termios) |termios| {
        std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, termios) catch {};
        orig_termios = null;
    }
}

pub fn getSize() !struct { rows: usize, cols: usize } {
    var winsize: std.posix.winsize = undefined;
    const rc = std.posix.system.ioctl(std.posix.STDOUT_FILENO, std.posix.T.IOCGWINSZ, @intFromPtr(&winsize));
    if (rc != 0) {
        return error.IoctlError;
    }
    return .{ .rows = winsize.row, .cols = winsize.col };
}

pub fn clearScreen(writer: anytype) !void {
    try writer.writeAll("\x1b[2J\x1b[H");
}

/// Move cursor to top-left without erasing anything.
pub fn moveHome(writer: anytype) !void {
    try writer.writeAll("\x1b[H");
}

/// Erase from the current cursor position to the end of the screen.
pub fn eraseToEnd(writer: anytype) !void {
    try writer.writeAll("\x1b[J");
}

pub fn clearLine(writer: anytype) !void {
    try writer.writeAll("\x1b[2K");
}

/// Erase from the current cursor position to the end of the line.
pub fn eraseToLineEnd(writer: anytype) !void {
    try writer.writeAll("\x1b[K");
}

pub fn moveCursor(writer: anytype, row: usize, col: usize) !void {
    try writer.print("\x1b[{d};{d}H", .{ row, col });
}

pub fn hideCursor(writer: anytype) !void {
    try writer.writeAll("\x1b[?25l");
}

pub fn showCursor(writer: anytype) !void {
    try writer.writeAll("\x1b[?25h");
}

pub fn readKey(reader: anytype) !KeyEvent {
    var buf: [1]u8 = undefined;
    const n = try reader.read(&buf);
    if (n == 0) return KeyEvent{}; // Timeout or EOF

    const c = buf[0];
    var event = KeyEvent{};

    // Handle escape sequences
    if (c == '\x1b') {
        var seq: [16]u8 = undefined;
        var seq_len: usize = 0;

        if ((try reader.read(seq[seq_len .. seq_len + 1])) == 0) {
            event.key = .Esc;
            return event;
        }
        seq_len += 1;

        var alt_prefix = false;
        if (seq[0] == '\x1b') {
            alt_prefix = true;
            if ((try reader.read(seq[seq_len .. seq_len + 1])) == 0) {
                event.key = .Esc;
                return event;
            }
            seq[0] = seq[1];
        }

        if (seq[0] == '[' or seq[0] == 'O') {
            while (seq_len < seq.len) {
                if ((try reader.read(seq[seq_len .. seq_len + 1])) == 0) break;
                const ch = seq[seq_len];
                seq_len += 1;
                if ((ch >= 'A' and ch <= 'Z') or (ch >= 'a' and ch <= 'z') or ch == '~') {
                    break;
                }
            }

            if (seq[0] == '[') {
                const last_ch = seq[seq_len - 1];

                var alt = false;
                var ctrl = false;
                var shift = false;

                if (std.mem.indexOfScalar(u8, seq[0..seq_len], ';')) |idx| {
                    if (idx + 1 < seq_len) {
                        const mod_char = seq[idx + 1];
                        switch (mod_char) {
                            '2' => shift = true,
                            '3' => alt = true,
                            '4' => {
                                shift = true;
                                alt = true;
                            },
                            '5' => ctrl = true,
                            '6' => {
                                shift = true;
                                ctrl = true;
                            },
                            '7' => {
                                alt = true;
                                ctrl = true;
                            },
                            '8' => {
                                shift = true;
                                alt = true;
                                ctrl = true;
                            },
                            else => {},
                        }
                    }
                }

                event.alt = alt or alt_prefix;
                event.ctrl = ctrl;
                event.shift = shift;

                switch (last_ch) {
                    'A' => event.key = .Up,
                    'B' => event.key = .Down,
                    'C' => event.key = .Right,
                    'D' => event.key = .Left,
                    'H' => event.key = .Home,
                    'F' => event.key = .End,
                    'Z' => {
                        event.key = .Char;
                        event.char = '\t';
                        event.shift = true;
                    },
                    '~' => {
                        if (seq_len > 1) {
                            switch (seq[1]) {
                                '1', '7' => event.key = .Home,
                                '3' => event.key = .Delete,
                                '4', '8' => event.key = .End,
                                '5' => event.key = .PageUp,
                                '6' => event.key = .PageDown,
                                else => {},
                            }
                        }
                    },
                    else => {
                        // If we only have \x1b[, it's ALT+[
                        if (seq_len == 1 and seq[0] == '[') {
                            event.alt = true;
                            event.key = .Char;
                            event.char = '[';
                        } else if (seq_len == 1 and seq[0] == ']') {
                            event.alt = true;
                            event.key = .Char;
                            event.char = ']';
                        }
                    },
                }
            } else if (seq[0] == 'O') {
                switch (seq[seq_len - 1]) {
                    'H' => event.key = .Home,
                    'F' => event.key = .End,
                    else => {},
                }
                if (alt_prefix) event.alt = true;
            }
        } else {
            // Meta + Char
            if (seq[0] == 'b') {
                event.alt = true;
                event.key = .Left;
                return event;
            } else if (seq[0] == 'f') {
                event.alt = true;
                event.key = .Right;
                return event;
            }

            event.alt = true;
            event.key = .Char;
            event.char = seq[0];
        }
        return event;
    }

    // Handle Control characters (0-31)
    if (c <= 31 and c != 13 and c != 10 and c != 9 and c != 8) {
        event.ctrl = true;
        event.key = .Char;
        if (c == 0) {
            event.char = ' ';
        } else if (c <= 26) {
            // Map 1-26 to 'a'-'z'
            event.char = c + 'a' - 1;
        } else {
            // Handle 27-31: Ctrl+[, Ctrl+\, Ctrl+], Ctrl+^, Ctrl+_
            const map = "[\\]^_";
            event.char = map[c - 27];
        }
        return event;
    }

    switch (c) {
        '\r', '\n' => event.key = .Enter,
        '\t' => {
            event.key = .Char;
            event.char = '\t';
        },
        127, 8 => event.key = .Backspace, // Backspace or Ctrl-H
        else => {
            // Handle UTF-8 or Option keys on Mac
            if (c >= 128) {
                var utf8_buf: [4]u8 = undefined;
                utf8_buf[0] = c;
                const len: usize = if (c & 0xe0 == 0xc0) 2 else if (c & 0xf0 == 0xe0) 3 else if (c & 0xf8 == 0xf0) 4 else 1;

                for (1..len) |i| {
                    _ = try reader.read(utf8_buf[i .. i + 1]);
                }

                // Common Mac Option shortcuts in UTF-8
                if (len == 3 and utf8_buf[0] == 0xe2 and utf8_buf[1] == 0x80) {
                    if (utf8_buf[2] == 0x9c or utf8_buf[2] == 0x9d) { // “ or ”
                        event.alt = true;
                        event.key = .Char;
                        event.char = '[';
                        return event;
                    } else if (utf8_buf[2] == 0x98 or utf8_buf[2] == 0x99) { // ‘ or ’
                        event.alt = true;
                        event.key = .Char;
                        event.char = ']';
                        return event;
                    }
                }

                event.key = .Char;
                event.char = c;
                return event;
            }

            event.key = .Char;
            event.char = c;
        },
    }

    return event;
}

pub fn restoreTerminal(writer: std.fs.File) void {
    // Restore termios first
    disableRawMode();

    // Best-effort ANSI reset (ignore errors)
    writer.writeAll("\x1b[?1049l") catch {}; // leave alt screen
    writer.writeAll("\x1b[?25h") catch {}; // show cursor
    writer.writeAll("\x1b[0m") catch {}; // reset styles
    writer.writeAll("\x1b[2J\x1b[H") catch {}; // clear + home

    // Flush if possible (depends on writer type)
    if (@hasDecl(@TypeOf(writer), "context")) {
        writer.context.flush() catch {};
    }
}
