//! input_test.zig — behavioral / integration tests for input.zig
//!
//! Feeds KeyEvents directly into handleInput() and asserts editor state.
//! No real TTY is required. All Option-key bindings use alt=true as that
//! is how the macOS Option key is represented after terminal decoding.

const std = @import("std");
const input_mod = @import("../src/editor/input.zig");
const editor_mod = @import("../src/editor/editor.zig");
const buffer_mod = @import("../src/editor/buffer.zig");
const Buffer = buffer_mod.Buffer;
const Line = buffer_mod.Line;
const terminal = @import("../src/terminal.zig");
const th = @import("test_helpers.zig");

// ── Helpers ───────────────────────────────────────────────────────────────────

fn feed(ed: *editor_mod.Editor, events: []const terminal.KeyEvent) !void {
    for (events) |ev| try input_mod.handleInput(ed, ev);
}

fn expectLine(a: std.mem.Allocator, ed: *editor_mod.Editor, row: usize, expected: []const u8) !void {
    const s = try th.lineText(a, ed, row);
    defer a.free(s);
    try std.testing.expectEqualStrings(expected, s);
}

// ── Mode transitions ──────────────────────────────────────────────────────────

test "Dashboard → Normal via Enter on 'New File'" {
    const a = std.testing.allocator;
    var ed = try th.makeEmptyEditor(a);
    defer ed.deinit();

    try std.testing.expectEqual(editor_mod.EditorMode.Dashboard, ed.mode);
    // Dashboard: selected_index starts at 0 ("New File"), press Enter to confirm.
    try feed(&ed, &[_]terminal.KeyEvent{th.keySpecial(.Enter)});
    try std.testing.expectEqual(editor_mod.EditorMode.Normal, ed.mode);
    try std.testing.expectEqual(@as(usize, 1), ed.tabs.items.len);
}

test "Normal → Insert via 'i'" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{""});
    defer ed.deinit();

    try feed(&ed, &[_]terminal.KeyEvent{th.keyChar('i')});
    try std.testing.expectEqual(editor_mod.EditorMode.Insert, ed.mode);
}

test "Insert → Normal via Esc" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{""});
    defer ed.deinit();

    ed.mode = .Insert;
    try feed(&ed, &[_]terminal.KeyEvent{th.keySpecial(.Esc)});
    try std.testing.expectEqual(editor_mod.EditorMode.Normal, ed.mode);
}

test "Normal → Command via ':'" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{""});
    defer ed.deinit();

    try feed(&ed, &[_]terminal.KeyEvent{th.keyChar(':')});
    try std.testing.expectEqual(editor_mod.EditorMode.Command, ed.mode);
    try std.testing.expectEqual(@as(usize, 0), ed.command_buffer.items.len);
}

test "Command → Normal via Esc" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{""});
    defer ed.deinit();

    ed.mode = .Command;
    try feed(&ed, &[_]terminal.KeyEvent{th.keySpecial(.Esc)});
    try std.testing.expectEqual(editor_mod.EditorMode.Normal, ed.mode);
}

test "Normal → Search via '/'" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{"hello world"});
    defer ed.deinit();

    try feed(&ed, &[_]terminal.KeyEvent{th.keyChar('/')});
    try std.testing.expectEqual(editor_mod.EditorMode.Search, ed.mode);
    try std.testing.expectEqual(@as(usize, 0), ed.search_buffer.items.len);
}

test "Search → Normal via Esc clears search" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{"hello world"});
    defer ed.deinit();

    ed.mode = .Search;
    try ed.search_buffer.append(a, 'h');
    try feed(&ed, &[_]terminal.KeyEvent{th.keySpecial(.Esc)});
    try std.testing.expectEqual(editor_mod.EditorMode.Normal, ed.mode);
    try std.testing.expectEqual(@as(usize, 0), ed.search_buffer.items.len);
}

test "Search → Normal via Enter" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{"hello world"});
    defer ed.deinit();

    ed.mode = .Search;
    try feed(&ed, &[_]terminal.KeyEvent{th.keySpecial(.Enter)});
    try std.testing.expectEqual(editor_mod.EditorMode.Normal, ed.mode);
}

// ── Typing in Insert mode ─────────────────────────────────────────────────────

test "Insert: typing ASCII chars updates buffer" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{""});
    defer ed.deinit();

    ed.mode = .Insert;
    try feed(&ed, &[_]terminal.KeyEvent{
        th.keyChar('H'), th.keyChar('i'),
    });
    try expectLine(a, &ed, 0, "Hi");
}

test "Insert: Tab expands to 4 spaces" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{""});
    defer ed.deinit();

    ed.mode = .Insert;
    try feed(&ed, &[_]terminal.KeyEvent{
        .{ .key = .Char, .char = '\t' },
    });
    try expectLine(a, &ed, 0, "    ");
}

test "Insert: Enter splits line" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{""});
    defer ed.deinit();

    ed.mode = .Insert;
    try feed(&ed, &[_]terminal.KeyEvent{
        th.keyChar('a'),
        th.keySpecial(.Enter),
        th.keyChar('b'),
    });

    const tab = ed.currentTab().?;
    try std.testing.expectEqual(@as(usize, 2), tab.buf.lines.items.len);
    try expectLine(a, &ed, 0, "a");
    try expectLine(a, &ed, 1, "b");
}

test "Insert: Backspace removes previous char" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{""});
    defer ed.deinit();

    ed.mode = .Insert;
    try feed(&ed, &[_]terminal.KeyEvent{
        th.keyChar('a'),           th.keyChar('b'), th.keyChar('c'),
        th.keySpecial(.Backspace),
    });
    try expectLine(a, &ed, 0, "ab");
}

test "Insert: Backspace at col 0 merges with previous line" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{ "first", "second" });
    defer ed.deinit();

    ed.mode = .Insert;
    const tab = ed.currentTab().?;
    tab.mainCursor().row = 1;
    tab.mainCursor().col = 0;

    try feed(&ed, &[_]terminal.KeyEvent{th.keySpecial(.Backspace)});

    try std.testing.expectEqual(@as(usize, 1), tab.buf.lines.items.len);
    try expectLine(a, &ed, 0, "firstsecond");
}

test "Insert: Option+Delete deletes previous word" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{"hello world"});
    defer ed.deinit();

    ed.mode = .Insert;
    const tab = ed.currentTab().?;
    tab.mainCursor().col = 11;

    try feed(&ed, &[_]terminal.KeyEvent{th.keyOption(.Delete)});

    try expectLine(a, &ed, 0, "hello ");
    try std.testing.expectEqual(@as(usize, 6), tab.mainCursor().col);
}

test "Insert: Option+Delete deletes previous word when terminal sends Alt+Backspace" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{"hello world"});
    defer ed.deinit();

    ed.mode = .Insert;
    const tab = ed.currentTab().?;
    tab.mainCursor().col = 11;

    try feed(&ed, &[_]terminal.KeyEvent{.{ .key = .Backspace, .alt = true }});

    try expectLine(a, &ed, 0, "hello ");
    try std.testing.expectEqual(@as(usize, 6), tab.mainCursor().col);
}

test "Insert: Ctrl+Z undo and Ctrl+Y redo text edit" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{""});
    defer ed.deinit();

    ed.mode = .Insert;
    try feed(&ed, &[_]terminal.KeyEvent{th.keyChar('x')});
    try expectLine(a, &ed, 0, "x");

    try feed(&ed, &[_]terminal.KeyEvent{th.keyCtrl('z')});
    try expectLine(a, &ed, 0, "");

    try feed(&ed, &[_]terminal.KeyEvent{th.keyCtrl('y')});
    try expectLine(a, &ed, 0, "x");
}

// ── Command mode ──────────────────────────────────────────────────────────────

test "Command: :q on clean tab closes it" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{"hello"});
    defer ed.deinit();

    // Mark as not dirty
    ed.currentTab().?.buf.is_dirty = false;

    try feed(&ed, &[_]terminal.KeyEvent{
        th.keyChar(':'),
        th.keyChar('q'),
        th.keySpecial(.Enter),
    });

    // After :q the tab is closed → Dashboard
    try std.testing.expectEqual(editor_mod.EditorMode.Dashboard, ed.mode);
    try std.testing.expectEqual(@as(usize, 0), ed.tabs.items.len);
}

test "Command: :q on dirty buffer shows error" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{"hello"});
    defer ed.deinit();

    ed.currentTab().?.buf.is_dirty = true;

    try feed(&ed, &[_]terminal.KeyEvent{
        th.keyChar(':'),
        th.keyChar('q'),
        th.keySpecial(.Enter),
    });

    // Tab stays open, error is set
    try std.testing.expectEqual(@as(usize, 1), ed.tabs.items.len);
    try std.testing.expect(ed.error_message != null);
}

test "Command: :q! force-closes dirty tab" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{"hello"});
    defer ed.deinit();

    ed.currentTab().?.buf.is_dirty = true;

    try feed(&ed, &[_]terminal.KeyEvent{
        th.keyChar(':'),
        th.keyChar('q'),
        th.keyChar('!'),
        th.keySpecial(.Enter),
    });

    try std.testing.expectEqual(@as(usize, 0), ed.tabs.items.len);
}

test "Command: :w saves file to disk" {
    const a = std.testing.allocator;
    const log = try th.setupLogger(a);
    defer log.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = path_buf[0..try tmp.dir.realPath(std.testing.io, &path_buf)];
    const file_path = try std.fmt.allocPrint(a, "{s}/saved.txt", .{dir_path});
    defer a.free(file_path);

    var ed = try th.makeEditor(a, &[_][]const u8{"flamingo rocks"});
    defer ed.deinit();

    // Set filename so :w knows where to write.
    try ed.currentTab().?.buf.setFilename(file_path);

    try feed(&ed, &[_]terminal.KeyEvent{
        th.keyChar(':'),
        th.keyChar('w'),
        th.keySpecial(.Enter),
    });

    // File should exist on disk.
    const stat = try std.Io.Dir.cwd().statFile(std.testing.io, file_path, .{});
    try std.testing.expect(stat.size > 0);
    try std.testing.expect(!ed.currentTab().?.buf.is_dirty);
}

test "Command: unknown command shows error, stays Normal" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{""});
    defer ed.deinit();

    try feed(&ed, &[_]terminal.KeyEvent{
        th.keyChar(':'),
        th.keyChar('z'),
        th.keyChar('z'),
        th.keyChar('z'),
        th.keySpecial(.Enter),
    });

    try std.testing.expectEqual(editor_mod.EditorMode.Normal, ed.mode);
    try std.testing.expect(ed.error_message != null);
}

// ── Search ────────────────────────────────────────────────────────────────────

test "Search: typing query finds matches" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{
        "flamingo editor",
        "another flamingo line",
        "nothing here",
    });
    defer ed.deinit();

    try feed(&ed, &[_]terminal.KeyEvent{
        th.keyChar('/'),
        th.keyChar('f'),
        th.keyChar('l'),
        th.keyChar('a'),
    });

    const ss = ed.search_system.?;
    try std.testing.expect(ss.matches.items.len >= 2);
}

test "Search: Down cycles to next match" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{
        "foo bar",
        "baz foo",
        "foo end",
    });
    defer ed.deinit();

    // Manually populate search (avoids needing a fully initialised search UI path)
    ed.mode = .Search;
    try ed.search_buffer.appendSlice(a, "foo");
    try ed.search_system.?.update(&ed.currentTab().?.buf, "foo");

    const first_idx = ed.search_system.?.active_match_idx;
    try feed(&ed, &[_]terminal.KeyEvent{th.keySpecial(.Down)});
    const second_idx = ed.search_system.?.active_match_idx;
    try std.testing.expect(first_idx != second_idx);
}

test "Search: Up cycles to previous match" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{
        "foo bar",
        "baz foo",
    });
    defer ed.deinit();

    ed.mode = .Search;
    try ed.search_buffer.appendSlice(a, "foo");
    try ed.search_system.?.update(&ed.currentTab().?.buf, "foo");
    // Start at index 0, go back → should wrap to last
    ed.search_system.?.active_match_idx = 0;

    try feed(&ed, &[_]terminal.KeyEvent{th.keySpecial(.Up)});
    const idx = ed.search_system.?.active_match_idx.?;
    try std.testing.expect(idx > 0); // wrapped to last match
}

test "Search: cursor jumps to active match row" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{
        "nothing",
        "flamingo here",
    });
    defer ed.deinit();

    ed.mode = .Search;
    try feed(&ed, &[_]terminal.KeyEvent{
        th.keyChar('f'), th.keyChar('l'), th.keyChar('a'),
    });

    const mc = ed.currentTab().?.mainCursor();
    try std.testing.expectEqual(@as(usize, 1), mc.row); // match is on row 1
}

test "Search: Backspace shrinks query and re-runs search" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{"flamingo"});
    defer ed.deinit();

    ed.mode = .Search;
    try feed(&ed, &[_]terminal.KeyEvent{
        th.keyChar('z'), th.keyChar('z'), th.keyChar('z'),
    });
    try std.testing.expectEqual(@as(usize, 0), ed.search_system.?.matches.items.len);

    try feed(&ed, &[_]terminal.KeyEvent{th.keySpecial(.Backspace)});
    try std.testing.expectEqual(@as(usize, 2), ed.search_buffer.items.len);
}

// ── Navigation with macOS Option key ─────────────────────────────────────────

test "Option+Up: moves cursor col to end-of-line" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{ "hello", "world" });
    defer ed.deinit();

    const tab = ed.currentTab().?;
    tab.mainCursor().row = 1;
    tab.mainCursor().col = 2;

    // Option+Up in handleMovement sets col = line.len()
    try feed(&ed, &[_]terminal.KeyEvent{th.keyOption(.Up)});
    // Cursor stays on same row, col moves to end (5 for "world")
    try std.testing.expectEqual(@as(usize, 1), tab.mainCursor().row);
    try std.testing.expectEqual(@as(usize, 5), tab.mainCursor().col);
}

test "Option+Down: moves cursor col to start-of-line" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{ "hello", "world" });
    defer ed.deinit();

    const tab = ed.currentTab().?;
    tab.mainCursor().row = 0;
    tab.mainCursor().col = 3;

    try feed(&ed, &[_]terminal.KeyEvent{th.keyOption(.Down)});
    // Option+Down in handleMovement: alt=true, ctrl=false → sets col=0.
    try std.testing.expectEqual(@as(usize, 0), tab.mainCursor().row);
    try std.testing.expectEqual(@as(usize, 0), tab.mainCursor().col);
}

test "Option+Left: word jump moves cursor left" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{"hello world"});
    defer ed.deinit();

    const tab = ed.currentTab().?;
    tab.mainCursor().col = 11; // end of line

    try feed(&ed, &[_]terminal.KeyEvent{th.keyOption(.Left)});
    try std.testing.expect(tab.mainCursor().col < 11);
}

test "Option+Right: word jump moves cursor right" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{"hello world"});
    defer ed.deinit();

    const tab = ed.currentTab().?;
    tab.mainCursor().col = 0;

    try feed(&ed, &[_]terminal.KeyEvent{th.keyOption(.Right)});
    try std.testing.expect(tab.mainCursor().col > 0);
}

test "Vertical movement preserves preferred column across short lines" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{ "abcdefghij", "xy", "abcdefghij" });
    defer ed.deinit();

    const tab = ed.currentTab().?;
    tab.mainCursor().row = 0;
    tab.mainCursor().col = 8;

    try feed(&ed, &[_]terminal.KeyEvent{th.keySpecial(.Down)});
    try std.testing.expectEqual(@as(usize, 1), tab.mainCursor().row);
    try std.testing.expectEqual(@as(usize, 2), tab.mainCursor().col);
    try std.testing.expectEqual(@as(?usize, 8), tab.mainCursor().preferred_col);

    try feed(&ed, &[_]terminal.KeyEvent{th.keySpecial(.Down)});
    try std.testing.expectEqual(@as(usize, 2), tab.mainCursor().row);
    try std.testing.expectEqual(@as(usize, 8), tab.mainCursor().col);
    try std.testing.expectEqual(@as(?usize, 8), tab.mainCursor().preferred_col);
}

test "Horizontal movement resets preferred column" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{ "abcdefghij", "xy", "abcdefghij" });
    defer ed.deinit();

    const tab = ed.currentTab().?;
    tab.mainCursor().row = 0;
    tab.mainCursor().col = 8;

    try feed(&ed, &[_]terminal.KeyEvent{ th.keySpecial(.Down), th.keySpecial(.Left) });
    try std.testing.expectEqual(@as(usize, 1), tab.mainCursor().row);
    try std.testing.expectEqual(@as(usize, 1), tab.mainCursor().col);
    try std.testing.expectEqual(@as(?usize, null), tab.mainCursor().preferred_col);
}

test "Option+[ cycles to next tab" {
    const a = std.testing.allocator;
    var ed = try th.makeEmptyEditor(a);
    defer ed.deinit();

    const b0 = try buffer_mod.Buffer.init(a);
    try ed.addTab(b0);
    const b1 = try buffer_mod.Buffer.init(a);
    try ed.addTab(b1);
    ed.active_tab_index = 0;

    // Option+[ is represented as alt=true, key=Char, char='['
    try feed(&ed, &[_]terminal.KeyEvent{th.keyOptionChar('[')});
    try std.testing.expectEqual(@as(usize, 1), ed.active_tab_index);
}

test "Option+] cycles to previous tab" {
    const a = std.testing.allocator;
    var ed = try th.makeEmptyEditor(a);
    defer ed.deinit();

    const b0 = try buffer_mod.Buffer.init(a);
    try ed.addTab(b0);
    const b1 = try buffer_mod.Buffer.init(a);
    try ed.addTab(b1);
    ed.active_tab_index = 1;

    try feed(&ed, &[_]terminal.KeyEvent{th.keyOptionChar(']')});
    try std.testing.expectEqual(@as(usize, 0), ed.active_tab_index);
}

test "Ctrl+Option+Up: addCursorAbove" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{ "row0", "row1", "row2" });
    defer ed.deinit();

    // Must be in Normal mode for ctrl+alt shortcuts to be processed.
    ed.mode = .Normal;
    ed.currentTab().?.mainCursor().row = 2;
    try feed(&ed, &[_]terminal.KeyEvent{th.keyCtrlOption(.Up)});
    try std.testing.expectEqual(@as(usize, 2), ed.currentTab().?.cursors.items.len);
}

test "Ctrl+Option+Down: addCursorBelow" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{ "row0", "row1", "row2" });
    defer ed.deinit();

    // Must be in Normal mode for ctrl+alt shortcuts to be processed.
    ed.mode = .Normal;
    ed.currentTab().?.mainCursor().row = 0;
    try feed(&ed, &[_]terminal.KeyEvent{th.keyCtrlOption(.Down)});
    try std.testing.expectEqual(@as(usize, 2), ed.currentTab().?.cursors.items.len);
}

test "Shift+Up: extends selection" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{ "line0", "line1" });
    defer ed.deinit();

    const tab = ed.currentTab().?;
    tab.mainCursor().row = 1;
    tab.mainCursor().col = 3;

    try feed(&ed, &[_]terminal.KeyEvent{th.keyShift(.Up)});
    try std.testing.expect(tab.mainCursor().selection_start != null);
}

// ── Explorer & tab control ────────────────────────────────────────────────────

test "configured default Ctrl+B toggles explorer_visible" {
    const a = std.testing.allocator;
    // Explorer.init calls logz.info(), so we must set up the logger first.
    const log = try th.setupLogger(a);
    defer log.deinit();

    var ed = try th.makeEditor(a, &[_][]const u8{""});
    defer ed.deinit();

    try std.testing.expect(!ed.explorer_visible);
    try feed(&ed, &[_]terminal.KeyEvent{th.keyCtrl('b')});
    try std.testing.expect(ed.explorer_visible);
    try feed(&ed, &[_]terminal.KeyEvent{th.keyCtrl('b')});
    try std.testing.expect(!ed.explorer_visible);
}

test "configured toggle_explorer key is used" {
    const a = std.testing.allocator;
    const log = try th.setupLogger(a);
    defer log.deinit();

    var ed = try th.makeEditor(a, &[_][]const u8{""});
    defer ed.deinit();
    ed.config.keybindings.toggle_explorer = "ctrl+t";
    ed.refreshKeybindings();

    try feed(&ed, &[_]terminal.KeyEvent{th.keyCtrl('b')});
    try std.testing.expect(!ed.explorer_visible);

    try feed(&ed, &[_]terminal.KeyEvent{th.keyCtrl('t')});
    try std.testing.expect(ed.explorer_visible);
}

test "Ctrl+W closes current tab" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{"hello"});
    defer ed.deinit();

    try std.testing.expectEqual(@as(usize, 1), ed.tabs.items.len);
    try feed(&ed, &[_]terminal.KeyEvent{th.keyCtrl('w')});
    try std.testing.expectEqual(@as(usize, 0), ed.tabs.items.len);
}

test "configured close_tab key is used" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{"hello"});
    defer ed.deinit();
    ed.config.keybindings.close_tab = "ctrl+u";
    ed.refreshKeybindings();

    try feed(&ed, &[_]terminal.KeyEvent{th.keyCtrl('w')});
    try std.testing.expectEqual(@as(usize, 1), ed.tabs.items.len);

    try feed(&ed, &[_]terminal.KeyEvent{th.keyCtrl('u')});
    try std.testing.expectEqual(@as(usize, 0), ed.tabs.items.len);
}

test "configured Ctrl+Shift+K delete_line works when terminal reports Ctrl+K" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{ "keep", "delete", "also keep" });
    defer ed.deinit();

    ed.currentTab().?.mainCursor().row = 1;
    try feed(&ed, &[_]terminal.KeyEvent{th.keyCtrl('k')});

    const tab = ed.currentTab().?;
    try std.testing.expectEqual(@as(usize, 2), tab.buf.lines.items.len);
    try expectLine(a, &ed, 0, "keep");
    try expectLine(a, &ed, 1, "also keep");
}

test "configured Ctrl+E switches explorer focus" {
    const a = std.testing.allocator;
    const log = try th.setupLogger(a);
    defer log.deinit();

    var ed = try th.makeEditor(a, &[_][]const u8{""});
    defer ed.deinit();
    ed.config.keybindings.switch_focus = "ctrl+e";

    try feed(&ed, &[_]terminal.KeyEvent{th.keyCtrl('b')});
    try std.testing.expect(ed.explorer_visible);
    try std.testing.expect(ed.explorer_focused);

    try feed(&ed, &[_]terminal.KeyEvent{th.keyCtrl('e')});
    try std.testing.expect(!ed.explorer_focused);
}

test "plain Tab inserts indentation when explorer is visible" {
    const a = std.testing.allocator;
    const log = try th.setupLogger(a);
    defer log.deinit();

    var ed = try th.makeEditor(a, &[_][]const u8{""});
    defer ed.deinit();
    ed.config.keybindings.switch_focus = "ctrl+e";

    try feed(&ed, &[_]terminal.KeyEvent{th.keyCtrl('b')});
    try std.testing.expect(ed.explorer_visible);
    try std.testing.expect(ed.explorer_focused);

    ed.mode = .Insert;
    ed.explorer_focused = false;

    try feed(&ed, &[_]terminal.KeyEvent{th.keyChar('\t')});
    try expectLine(a, &ed, 0, "    ");
    try std.testing.expect(!ed.explorer_focused);
}

test "Ctrl+S saves current file" {
    const a = std.testing.allocator;
    const log = try th.setupLogger(a);
    defer log.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = path_buf[0..try tmp.dir.realPath(std.testing.io, &path_buf)];
    const file_path = try std.fmt.allocPrint(a, "{s}/ctrl_s.txt", .{dir_path});
    defer a.free(file_path);

    var ed = try th.makeEditor(a, &[_][]const u8{"saved by ctrl+s"});
    defer ed.deinit();

    try ed.currentTab().?.buf.setFilename(file_path);
    ed.currentTab().?.buf.is_dirty = true;
    ed.mode = .Normal;

    try feed(&ed, &[_]terminal.KeyEvent{th.keyCtrl('s')});

    try std.testing.expect(!ed.currentTab().?.buf.is_dirty);
}
