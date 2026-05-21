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
    } else if (std.mem.eql(u8, chord, "delete")) {
        event.key = .Delete;
    } else if (std.mem.eql(u8, chord, "home")) {
        event.key = .Home;
    } else if (std.mem.eql(u8, chord, "end")) {
        event.key = .End;
    } else if (std.mem.eql(u8, chord, "pageup")) {
        event.key = .PageUp;
    } else if (std.mem.eql(u8, chord, "pagedown")) {
        event.key = .PageDown;
    } else {
        // Parse modifiers: ctrl+n, alt+p
        var it = std.mem.splitScalar(u8, chord, '+');
        var last_part: ?[]const u8 = null;
        while (it.next()) |part| {
            if (std.mem.eql(u8, part, "ctrl")) {
                event.ctrl = true;
            } else if (std.mem.eql(u8, part, "alt") or std.mem.eql(u8, part, "option")) {
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
            } else if (std.mem.eql(u8, part, "space")) {
                event.key = .Char;
                event.char = ' ';
            } else if (std.mem.eql(u8, part, "up")) {
                event.key = .Up;
            } else if (std.mem.eql(u8, part, "down")) {
                event.key = .Down;
            } else if (std.mem.eql(u8, part, "left")) {
                event.key = .Left;
            } else if (std.mem.eql(u8, part, "right")) {
                event.key = .Right;
            } else if (std.mem.eql(u8, part, "esc")) {
                event.key = .Esc;
            } else if (std.mem.eql(u8, part, "enter")) {
                event.key = .Enter;
            } else if (std.mem.eql(u8, part, "backspace")) {
                event.key = .Backspace;
            } else if (std.mem.eql(u8, part, "delete")) {
                event.key = .Delete;
            } else if (std.mem.eql(u8, part, "home")) {
                event.key = .Home;
            } else if (std.mem.eql(u8, part, "end")) {
                event.key = .End;
            } else if (std.mem.eql(u8, part, "pageup")) {
                event.key = .PageUp;
            } else if (std.mem.eql(u8, part, "pagedown")) {
                event.key = .PageDown;
            }
        }
    }
    return event;
}

var orig_termios: ?std.posix.termios = null;

fn DeclType(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .pointer => |ptr| ptr.child,
        else => T,
    };
}

fn readShort(reader: anytype, buffer: []u8) !usize {
    if (comptime @hasDecl(DeclType(@TypeOf(reader)), "readSliceShort")) {
        return reader.readSliceShort(buffer);
    }
    return reader.read(buffer);
}

fn readContinuationByte(reader: anytype, buffer: []u8) !usize {
    const max_attempts = 3;
    var attempts: usize = 0;
    while (attempts < max_attempts) : (attempts += 1) {
        const n = try readShort(reader, buffer);
        if (n != 0) return n;
        if (attempts + 1 == max_attempts) break;
        const req = std.c.timespec{
            .sec = 0,
            .nsec = std.time.ns_per_ms,
        };
        _ = std.c.nanosleep(&req, null);
    }
    return 0;
}

fn utf8Len(first: u8) usize {
    return if (first & 0xe0 == 0xc0) 2 else if (first & 0xf0 == 0xe0) 3 else if (first & 0xf8 == 0xf0) 4 else 1;
}

fn macOptionUtf8Char(bytes: []const u8) ?u8 {
    if (bytes.len == 2) {
        if (bytes[0] == 0xc3 and bytes[1] == 0xb8) return 'o'; // ø, Option+O
        if (bytes[0] == 0xcb and bytes[1] == 0x9c) return 'n'; // ˜, Option+N
        if (bytes[0] == 0xc3 and bytes[1] == 0xb1) return 'n'; // ñ, Option+N dead key followed by n
        if (bytes[0] == 0xcc and bytes[1] == 0x83) return 'n'; // combining tilde, Option+N
        if (bytes[0] == 0xc2 and bytes[1] == 0xae) return 'r'; // ®, Option+R
        if (bytes[0] == 0xcf and bytes[1] == 0x80) return 'p'; // π, Option+P
        if (bytes[0] == 0xcb and bytes[1] == 0x86) return 'i'; // ˆ, Option+I
        if (bytes[0] == 0xcc and bytes[1] == 0x82) return 'i'; // combining circumflex, Option+I
    }

    if (bytes.len == 3 and bytes[0] == 0xe2 and bytes[1] == 0x80) {
        if (bytes[2] == 0x9c or bytes[2] == 0x9d) return '['; // “ or ”
        if (bytes[2] == 0x98 or bytes[2] == 0x99) return ']'; // ‘ or ’
    }
    if (bytes.len == 3 and bytes[0] == 0xe2 and bytes[1] == 0x88 and bytes[2] == 0x82) return 'd'; // ∂, Option+D

    return null;
}

pub fn enableRawMode(io: std.Io) !void {
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
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 0; // nonblocking reads; the editor loop owns pacing

    try std.posix.tcsetattr(fd, .FLUSH, raw);

    const stdout: std.Io.File = .stdout();
    try stdout.writeStreamingAll(io, "\x1b[?1049h"); // enter alt screen
    try stdout.writeStreamingAll(io, "\x1b[?25l"); // hide cursor
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
    const n = try readShort(reader, &buf);
    if (n == 0) return KeyEvent{}; // Timeout or EOF

    const c = buf[0];
    var event = KeyEvent{};

    // Handle escape sequences
    if (c == '\x1b') {
        var seq: [16]u8 = undefined;
        var seq_len: usize = 0;

        if ((try readContinuationByte(reader, seq[seq_len .. seq_len + 1])) == 0) {
            event.key = .Esc;
            return event;
        }
        seq_len += 1;

        var alt_prefix = false;
        if (seq[0] == '\x1b') {
            alt_prefix = true;
            if ((try readContinuationByte(reader, seq[seq_len .. seq_len + 1])) == 0) {
                event.key = .Esc;
                return event;
            }
            seq[0] = seq[1];
        }

        if (seq[0] == '[' or seq[0] == 'O') {
            while (seq_len < seq.len) {
                if ((try readShort(reader, seq[seq_len .. seq_len + 1])) == 0) break;
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
                    'u' => {
                        if (std.mem.indexOfScalar(u8, seq[0..seq_len], ';')) |idx| {
                            const codepoint = std.fmt.parseInt(u21, seq[1..idx], 10) catch 0;
                            if (codepoint > 0 and codepoint <= 127) {
                                event.key = .Char;
                                event.char = @intCast(codepoint);
                                if (event.char >= 'A' and event.char <= 'Z') {
                                    event.char = event.char - 'A' + 'a';
                                    event.shift = true;
                                }
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
            } else if (seq[0] == 127 or seq[0] == 8) {
                event.alt = true;
                event.key = .Backspace;
                return event;
            }

            if (seq[0] >= 128) {
                var utf8_buf: [4]u8 = .{ 0, 0, 0, 0 };
                utf8_buf[0] = seq[0];
                const len = utf8Len(seq[0]);
                for (1..len) |i| {
                    if ((try readContinuationByte(reader, utf8_buf[i .. i + 1])) == 0) break;
                }
                if (macOptionUtf8Char(utf8_buf[0..len])) |mapped| {
                    event.alt = true;
                    event.key = .Char;
                    event.char = mapped;
                    return event;
                }
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
                var utf8_buf: [4]u8 = .{ 0, 0, 0, 0 };
                utf8_buf[0] = c;
                const len = utf8Len(c);

                for (1..len) |i| {
                    if ((try readContinuationByte(reader, utf8_buf[i .. i + 1])) == 0) break;
                }

                if (macOptionUtf8Char(utf8_buf[0..len])) |mapped| {
                    event.alt = true;
                    event.key = .Char;
                    event.char = mapped;
                    return event;
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

pub fn restoreTerminal(io: std.Io, writer: std.Io.File) void {
    // Restore termios first
    disableRawMode();

    // Best-effort ANSI reset (ignore errors)
    writer.writeStreamingAll(io, "\x1b[?1049l") catch {}; // leave alt screen
    writer.writeStreamingAll(io, "\x1b[?25h") catch {}; // show cursor
    writer.writeStreamingAll(io, "\x1b[0m") catch {}; // reset styles
    writer.writeStreamingAll(io, "\x1b[2J\x1b[H") catch {}; // clear + home

    // Flush if possible (depends on writer type)
    if (@hasDecl(@TypeOf(writer), "context")) {
        writer.context.flush() catch {};
    }
}
