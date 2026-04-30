//! terminal_test.zig — unit tests for terminal.zig
//!
//! Tests parseKeyChord, KeyEvent.eql, and readKey with a mocked reader.
//! On macOS the user presses the Option key; our code maps this to alt=true.

const std = @import("std");
const terminal = @import("../src/terminal.zig");
const Key = terminal.Key;
const KeyEvent = terminal.KeyEvent;

// ── parseKeyChord ─────────────────────────────────────────────────────────────

test "parseKeyChord: arrow keys" {
    try std.testing.expectEqual(KeyEvent{ .key = .Up }, terminal.parseKeyChord("up"));
    try std.testing.expectEqual(KeyEvent{ .key = .Down }, terminal.parseKeyChord("down"));
    try std.testing.expectEqual(KeyEvent{ .key = .Left }, terminal.parseKeyChord("left"));
    try std.testing.expectEqual(KeyEvent{ .key = .Right }, terminal.parseKeyChord("right"));
}

test "parseKeyChord: special keys" {
    try std.testing.expectEqual(KeyEvent{ .key = .Esc }, terminal.parseKeyChord("esc"));
    try std.testing.expectEqual(KeyEvent{ .key = .Enter }, terminal.parseKeyChord("enter"));
    try std.testing.expectEqual(KeyEvent{ .key = .Backspace }, terminal.parseKeyChord("backspace"));
}

test "parseKeyChord: ctrl modifier" {
    const ctrl_s = terminal.parseKeyChord("ctrl+s");
    try std.testing.expect(ctrl_s.ctrl);
    try std.testing.expectEqual(Key.Char, ctrl_s.key);
    try std.testing.expectEqual(@as(u8, 's'), ctrl_s.char);

    const ctrl_q = terminal.parseKeyChord("ctrl+q");
    try std.testing.expect(ctrl_q.ctrl);
    try std.testing.expectEqual(@as(u8, 'q'), ctrl_q.char);
}

test "parseKeyChord: Option (alt) modifier" {
    // On macOS the Option key sends escape-prefixed sequences that we
    // represent as alt=true in KeyEvent.
    const opt_p = terminal.parseKeyChord("alt+p");
    try std.testing.expect(opt_p.alt);
    try std.testing.expectEqual(Key.Char, opt_p.key);
    try std.testing.expectEqual(@as(u8, 'p'), opt_p.char);

    const opt_f = terminal.parseKeyChord("alt+f");
    try std.testing.expect(opt_f.alt);
    try std.testing.expectEqual(@as(u8, 'f'), opt_f.char);

    const option_left = terminal.parseKeyChord("option+left");
    try std.testing.expect(option_left.alt);
    try std.testing.expectEqual(Key.Left, option_left.key);
}

test "parseKeyChord: shift modifier" {
    const shift_up = terminal.parseKeyChord("shift+up");
    try std.testing.expect(shift_up.shift);
    // Note: shift+arrows from ANSI sequences carry modifier bits set differently
    // than single-char chords; we only verify the shift flag is set here.
}

test "parseKeyChord: tab" {
    const tab = terminal.parseKeyChord("tab");
    try std.testing.expectEqual(Key.Char, tab.key);
    try std.testing.expectEqual(@as(u8, '\t'), tab.char);
}

test "parseKeyChord: ctrl+tab" {
    const ct = terminal.parseKeyChord("ctrl+tab");
    try std.testing.expect(ct.ctrl);
    try std.testing.expectEqual(Key.Char, ct.key);
    try std.testing.expectEqual(@as(u8, '\t'), ct.char);
}

test "parseKeyChord: ctrl+space" {
    const cs = terminal.parseKeyChord("ctrl+space");
    try std.testing.expect(cs.ctrl);
    try std.testing.expectEqual(Key.Char, cs.key);
    try std.testing.expectEqual(@as(u8, ' '), cs.char);
}

// ── KeyEvent.eql ─────────────────────────────────────────────────────────────

test "KeyEvent.eql: identical events" {
    const a = KeyEvent{ .key = .Char, .char = 'a', .ctrl = true };
    const b = KeyEvent{ .key = .Char, .char = 'a', .ctrl = true };
    try std.testing.expect(a.eql(b));
}

test "KeyEvent.eql: different char" {
    const a = KeyEvent{ .key = .Char, .char = 'a' };
    const b = KeyEvent{ .key = .Char, .char = 'b' };
    try std.testing.expect(!a.eql(b));
}

test "KeyEvent.eql: different modifier" {
    const a = KeyEvent{ .key = .Char, .char = 'c', .ctrl = true };
    const b = KeyEvent{ .key = .Char, .char = 'c', .ctrl = false };
    try std.testing.expect(!a.eql(b));
}

// ── readKey with mocked reader ─────────────────────────────────────────────────
// We use a fixed std.Io.Reader to feed raw byte sequences.

fn readKeyFrom(bytes: []const u8) !KeyEvent {
    var reader = std.Io.Reader.fixed(bytes);
    return terminal.readKey(&reader);
}

test "readKey: ASCII printable char 'a'" {
    const ev = try readKeyFrom("a");
    try std.testing.expectEqual(Key.Char, ev.key);
    try std.testing.expectEqual(@as(u8, 'a'), ev.char);
    try std.testing.expect(!ev.ctrl);
    try std.testing.expect(!ev.alt);
}

test "readKey: backspace byte 127" {
    const ev = try readKeyFrom(&[_]u8{127});
    try std.testing.expectEqual(Key.Backspace, ev.key);
}

test "readKey: backspace byte 8 (Ctrl-H)" {
    const ev = try readKeyFrom(&[_]u8{8});
    try std.testing.expectEqual(Key.Backspace, ev.key);
}

test "readKey: Enter (carriage return)" {
    const ev = try readKeyFrom("\r");
    try std.testing.expectEqual(Key.Enter, ev.key);
}

test "readKey: Enter (newline)" {
    const ev = try readKeyFrom("\n");
    try std.testing.expectEqual(Key.Enter, ev.key);
}

test "readKey: ESC alone returns Esc" {
    // Feed ESC followed by EOF (zero bytes) — simulates raw-mode timeout.
    const ev = try readKeyFrom("\x1b");
    try std.testing.expectEqual(Key.Esc, ev.key);
}

test "readKey: Up arrow ESC [ A" {
    const ev = try readKeyFrom("\x1b[A");
    try std.testing.expectEqual(Key.Up, ev.key);
    try std.testing.expect(!ev.shift);
    try std.testing.expect(!ev.ctrl);
    try std.testing.expect(!ev.alt);
}

test "readKey: Down arrow ESC [ B" {
    const ev = try readKeyFrom("\x1b[B");
    try std.testing.expectEqual(Key.Down, ev.key);
}

test "readKey: Right arrow ESC [ C" {
    const ev = try readKeyFrom("\x1b[C");
    try std.testing.expectEqual(Key.Right, ev.key);
}

test "readKey: Left arrow ESC [ D" {
    const ev = try readKeyFrom("\x1b[D");
    try std.testing.expectEqual(Key.Left, ev.key);
}

test "readKey: Shift+Up ESC [ 1;2A" {
    const ev = try readKeyFrom("\x1b[1;2A");
    try std.testing.expectEqual(Key.Up, ev.key);
    try std.testing.expect(ev.shift);
    try std.testing.expect(!ev.ctrl);
}

test "readKey: Ctrl+Right ESC [ 1;5C" {
    const ev = try readKeyFrom("\x1b[1;5C");
    try std.testing.expectEqual(Key.Right, ev.key);
    try std.testing.expect(ev.ctrl);
    try std.testing.expect(!ev.shift);
}

test "readKey: Option+Up (ESC [ 1;3A) — macOS Option key" {
    // On macOS, Option+Up sends ESC [ 1;3A (modifier code 3 = alt/Option).
    const ev = try readKeyFrom("\x1b[1;3A");
    try std.testing.expectEqual(Key.Up, ev.key);
    try std.testing.expect(ev.alt);
}

test "readKey: Option+Down (ESC [ 1;3B) — macOS Option key" {
    const ev = try readKeyFrom("\x1b[1;3B");
    try std.testing.expectEqual(Key.Down, ev.key);
    try std.testing.expect(ev.alt);
}

test "readKey: Option+Left (ESC b) — macOS word-jump" {
    // Many macOS terminals send ESC b for Option+Left.
    const ev = try readKeyFrom("\x1bb");
    try std.testing.expectEqual(Key.Left, ev.key);
    try std.testing.expect(ev.alt);
}

test "readKey: Option+Right (ESC f) — macOS word-jump" {
    const ev = try readKeyFrom("\x1bf");
    try std.testing.expectEqual(Key.Right, ev.key);
    try std.testing.expect(ev.alt);
}

test "readKey: ctrl+char encoding (byte 1 = Ctrl+A)" {
    const ev = try readKeyFrom(&[_]u8{1});
    try std.testing.expect(ev.ctrl);
    try std.testing.expectEqual(Key.Char, ev.key);
    try std.testing.expectEqual(@as(u8, 'a'), ev.char);
}

test "readKey: ctrl+char encoding (byte 3 = Ctrl+C)" {
    const ev = try readKeyFrom(&[_]u8{3});
    try std.testing.expect(ev.ctrl);
    try std.testing.expectEqual(@as(u8, 'c'), ev.char);
}

test "readKey: Home key ESC [ H" {
    const ev = try readKeyFrom("\x1b[H");
    try std.testing.expectEqual(Key.Home, ev.key);
}

test "readKey: End key ESC [ F" {
    const ev = try readKeyFrom("\x1b[F");
    try std.testing.expectEqual(Key.End, ev.key);
}

test "readKey: Delete key ESC [ 3~" {
    const ev = try readKeyFrom("\x1b[3~");
    try std.testing.expectEqual(Key.Delete, ev.key);
}

test "readKey: PageUp ESC [ 5~" {
    const ev = try readKeyFrom("\x1b[5~");
    try std.testing.expectEqual(Key.PageUp, ev.key);
}

test "readKey: PageDown ESC [ 6~" {
    const ev = try readKeyFrom("\x1b[6~");
    try std.testing.expectEqual(Key.PageDown, ev.key);
}
