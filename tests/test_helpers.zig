//! test_helpers.zig — shared utilities for Flamingo's test suite.
//!
//! Import from any test file with:
//!   const th = @import("../test_helpers.zig");
//! or the appropriate relative path.

const std = @import("std");
const logz = @import("logz");
const logger = @import("../src/logger.zig");
const config = @import("../src/config.zig");
const editor_mod = @import("../src/editor/editor.zig");
const buffer_mod = @import("../src/editor/buffer.zig");
const terminal = @import("../src/terminal.zig");

// ── Logger helpers ────────────────────────────────────────────────────────────

/// Call at the top of any test that triggers code paths that call logz.
/// Returns a helper you can defer-shutdown.
pub const LoggerHandle = struct {
    pub fn deinit(self: LoggerHandle) void {
        _ = self;
        logger.shutdown() catch {};
    }
};

pub fn setupLogger(allocator: std.mem.Allocator) !LoggerHandle {
    try logger.init(std.testing.io, allocator, true);
    return LoggerHandle{};
}

// ── Editor factory ────────────────────────────────────────────────────────────

/// Creates an Editor with a single tab whose buffer is pre-populated with
/// `lines`. The caller must call `ed.deinit()` when done.
pub fn makeEditor(allocator: std.mem.Allocator, lines: []const []const u8) !editor_mod.Editor {
    const cfg = config.Config{};
    var ed = try editor_mod.Editor.init(allocator, std.testing.io, cfg);
    errdefer ed.deinit();

    var buf = try buffer_mod.Buffer.init(allocator);
    errdefer buf.deinit();

    // Replace the initial empty line with the provided content.
    // Buffer.init always adds one empty line; clear it.
    var first = buf.lines.orderedRemove(0);
    first.deinit();

    for (lines) |text| {
        const line = try buffer_mod.Line.fromSlice(allocator, text);
        try buf.lines.append(allocator, line);
    }

    // Guard: a buffer must have at least one line.
    if (buf.lines.items.len == 0) {
        try buf.lines.append(allocator, try buffer_mod.Line.init(allocator));
    }

    try ed.addTab(buf);
    ed.state.mode = .Normal;

    // Provide sensible terminal dimensions for scroll / gutter tests.
    ed.width = 80;
    ed.height = 24;

    return ed;
}

/// Creates an Editor in Dashboard mode with no tabs (simulates a fresh start).
pub fn makeEmptyEditor(allocator: std.mem.Allocator) !editor_mod.Editor {
    const cfg = config.Config{};
    var ed = try editor_mod.Editor.init(allocator, std.testing.io, cfg);
    ed.width = 80;
    ed.height = 24;
    return ed;
}

// ── KeyEvent builders ─────────────────────────────────────────────────────────

pub fn keyChar(c: u8) terminal.KeyEvent {
    return .{ .key = .Char, .char = c };
}

pub fn keyCtrl(c: u8) terminal.KeyEvent {
    return .{ .key = .Char, .char = c, .ctrl = true };
}

/// On macOS the Option key generates escape sequences that the terminal
/// maps to `alt = true` in our KeyEvent. This helper makes it explicit
/// in test code that we are pressing Option (≡ Alt) + a key.
pub fn keyOption(k: terminal.Key) terminal.KeyEvent {
    return .{ .key = k, .alt = true };
}

pub fn keyOptionChar(c: u8) terminal.KeyEvent {
    return .{ .key = .Char, .char = c, .alt = true };
}

pub fn keyCtrlOption(k: terminal.Key) terminal.KeyEvent {
    return .{ .key = k, .ctrl = true, .alt = true };
}

pub fn keyShift(k: terminal.Key) terminal.KeyEvent {
    return .{ .key = k, .shift = true };
}

pub fn keySpecial(k: terminal.Key) terminal.KeyEvent {
    return .{ .key = k };
}

// ── Feed key sequences into an editor ─────────────────────────────────────────

/// Convenience: feed a slice of KeyEvents through `input.handleInput`.
pub fn feedKeys(ed: *editor_mod.Editor, events: []const terminal.KeyEvent) !void {
    const input_mod = @import("../src/editor/input.zig");
    for (events) |ev| {
        try input_mod.handleInput(ed, ev);
    }
}

// ── Buffer content helpers ────────────────────────────────────────────────────

/// Returns a freshly allocated slice with the text content of `row`.
/// Caller must free.
pub fn lineText(allocator: std.mem.Allocator, ed: *editor_mod.Editor, row: usize) ![]u8 {
    const tab = ed.currentTab() orelse return error.NoTab;
    return tab.buf.lines.items[row].slice(allocator);
}
