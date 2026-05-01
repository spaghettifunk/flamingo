//! editor_test.zig — unit tests for editor.zig (Editor struct)
//!
//! Tests tab management, scroll clamping, and gutter width calculations.

const std = @import("std");
const config = @import("../src/config.zig");
const editor_mod = @import("../src/editor/editor.zig");
const buffer_mod = @import("../src/editor/buffer.zig");
const Buffer = buffer_mod.Buffer;
const terminal = @import("../src/terminal.zig");
const th = @import("test_helpers.zig");

const Editor = editor_mod.Editor;
const Line = buffer_mod.Line;

// ── init / deinit ─────────────────────────────────────────────────────────────

test "Editor: init and deinit leave no leaks" {
    const a = std.testing.allocator;
    var ed = try th.makeEmptyEditor(a);
    ed.deinit();
}

// ── tab management ────────────────────────────────────────────────────────────

test "Editor: addTab increases count and sets active index" {
    const a = std.testing.allocator;
    var ed = try th.makeEmptyEditor(a);
    defer ed.deinit();

    const b1 = try Buffer.init(a);
    try ed.addTab(b1);
    try std.testing.expectEqual(@as(usize, 1), ed.state.tabs.items.len);
    try std.testing.expectEqual(@as(usize, 0), ed.state.active_tab_index);

    const b2 = try Buffer.init(a);
    try ed.addTab(b2);
    try std.testing.expectEqual(@as(usize, 2), ed.state.tabs.items.len);
    try std.testing.expectEqual(@as(usize, 1), ed.state.active_tab_index);
}

test "Editor: addTab focuses existing tab for duplicate filename" {
    const a = std.testing.allocator;
    var ed = try th.makeEmptyEditor(a);
    defer ed.deinit();

    var first = try Buffer.init(a);
    try first.setFilename("/tmp/flamingo-duplicate.txt");
    try ed.addTab(first);

    var other = try Buffer.init(a);
    try other.setFilename("/tmp/flamingo-other.txt");
    try ed.addTab(other);
    try std.testing.expectEqual(@as(usize, 2), ed.state.tabs.items.len);
    try std.testing.expectEqual(@as(usize, 1), ed.state.active_tab_index);

    var duplicate = try Buffer.init(a);
    try duplicate.setFilename("/tmp/flamingo-duplicate.txt");
    try ed.addTab(duplicate);

    try std.testing.expectEqual(@as(usize, 2), ed.state.tabs.items.len);
    try std.testing.expectEqual(@as(usize, 0), ed.state.active_tab_index);
}

test "Editor: addTab still allows multiple unsaved tabs" {
    const a = std.testing.allocator;
    var ed = try th.makeEmptyEditor(a);
    defer ed.deinit();

    const first = try Buffer.init(a);
    try ed.addTab(first);

    const second = try Buffer.init(a);
    try ed.addTab(second);

    try std.testing.expectEqual(@as(usize, 2), ed.state.tabs.items.len);
    try std.testing.expectEqual(@as(usize, 1), ed.state.active_tab_index);
}

test "Editor: closeTab on only tab switches to Dashboard" {
    const a = std.testing.allocator;
    var ed = try th.makeEmptyEditor(a);
    defer ed.deinit();

    const b = try Buffer.init(a);
    try ed.addTab(b);
    ed.state.mode = .Normal;

    ed.closeTab();

    try std.testing.expectEqual(@as(usize, 0), ed.state.tabs.items.len);
    try std.testing.expectEqual(editor_mod.EditorMode.Dashboard, ed.state.mode);
    try std.testing.expectEqual(@as(usize, 0), ed.state.active_tab_index);
}

test "Editor: closeTab on multiple tabs adjusts index" {
    const a = std.testing.allocator;
    var ed = try th.makeEmptyEditor(a);
    defer ed.deinit();

    const b0 = try Buffer.init(a);
    try ed.addTab(b0);
    const b1 = try Buffer.init(a);
    try ed.addTab(b1);
    const b2 = try Buffer.init(a);
    try ed.addTab(b2);

    // active is tab 2, close it
    ed.state.active_tab_index = 2;
    ed.closeTab();
    try std.testing.expectEqual(@as(usize, 2), ed.state.tabs.items.len);
    try std.testing.expectEqual(@as(usize, 1), ed.state.active_tab_index);
}

test "Editor: nextTab and prevTab wrap around" {
    const a = std.testing.allocator;
    var ed = try th.makeEmptyEditor(a);
    defer ed.deinit();

    for (0..3) |_| {
        const b = try Buffer.init(a);
        try ed.addTab(b);
    }

    ed.state.active_tab_index = 0;
    ed.nextTab();
    try std.testing.expectEqual(@as(usize, 1), ed.state.active_tab_index);

    ed.state.active_tab_index = 2;
    ed.nextTab();
    try std.testing.expectEqual(@as(usize, 0), ed.state.active_tab_index); // wrap

    ed.state.active_tab_index = 0;
    ed.prevTab();
    try std.testing.expectEqual(@as(usize, 2), ed.state.active_tab_index); // wrap backwards
}

test "Editor: nextTab / prevTab are no-ops with one tab" {
    const a = std.testing.allocator;
    var ed = try th.makeEmptyEditor(a);
    defer ed.deinit();

    const b = try Buffer.init(a);
    try ed.addTab(b);

    ed.state.active_tab_index = 0;
    ed.nextTab();
    try std.testing.expectEqual(@as(usize, 0), ed.state.active_tab_index);

    ed.prevTab();
    try std.testing.expectEqual(@as(usize, 0), ed.state.active_tab_index);
}

test "Editor: closeAllTabs frees everything and sets Dashboard mode" {
    const a = std.testing.allocator;
    var ed = try th.makeEmptyEditor(a);
    defer ed.deinit();

    for (0..4) |_| {
        const b = try Buffer.init(a);
        try ed.addTab(b);
    }

    ed.closeAllTabs();
    try std.testing.expectEqual(@as(usize, 0), ed.state.tabs.items.len);
    try std.testing.expectEqual(editor_mod.EditorMode.Dashboard, ed.state.mode);
    try std.testing.expectEqual(@as(usize, 0), ed.state.active_tab_index);
}

test "Editor: currentTab returns null when no tabs" {
    const a = std.testing.allocator;
    var ed = try th.makeEmptyEditor(a);
    defer ed.deinit();

    try std.testing.expect(ed.currentTab() == null);
}

test "Editor: currentTab returns correct tab" {
    const a = std.testing.allocator;
    var ed = try th.makeEmptyEditor(a);
    defer ed.deinit();

    const b0 = try Buffer.init(a);
    try ed.addTab(b0);
    const b1 = try Buffer.init(a);
    try ed.addTab(b1);

    ed.state.active_tab_index = 0;
    try std.testing.expect(ed.currentTab() != null);
    try std.testing.expectEqual(&ed.state.tabs.items[0], ed.currentTab().?);
}

test "Editor: render includes syntax, selection, and search styling" {
    const a = std.testing.allocator;
    const logger = try th.setupLogger(a);
    defer logger.deinit();

    var ed = try th.makeEditor(a, &[_][]const u8{
        "const value = \"hi\";",
        "const other = 1;",
    });
    defer ed.deinit();

    ed.state.mode = .Normal;
    try ed.currentTab().?.buf.setFilename("main.zig");
    try ed.currentTab().?.syntax_highlighter.ensureForBuffer(&ed.currentTab().?.buf);
    ed.currentTab().?.mainCursor().selection_start = .{ .row = 0, .col = 0 };
    ed.currentTab().?.mainCursor().col = 5;
    try ed.state.search_buffer.appendSlice(a, "value");
    try ed.state.search_system.?.update(&ed.currentTab().?.buf, ed.state.search_buffer.items);

    var reader = std.Io.Reader.fixed("\x11");
    var out = std.Io.Writer.Allocating.init(a);
    defer out.deinit();

    try ed.runWithIO(&reader, &out.writer);

    const rendered = out.written();
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1b[38;5;177m") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1b[48;5;239m") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1b[48;5;214m\x1b[30m") != null);
}

test "Editor: run loop drains repeated cursor movement before rendering" {
    const a = std.testing.allocator;
    const logger = try th.setupLogger(a);
    defer logger.deinit();

    var ed = try th.makeEditor(a, &[_][]const u8{
        "row0",
        "row1",
        "row2",
        "row3",
        "row4",
        "row5",
        "row6",
    });
    defer ed.deinit();

    ed.state.mode = .Normal;
    ed.state.render_dirty = false;
    ed.state.force_full_render = false;

    var reader = std.Io.Reader.fixed("\x1b[B\x1b[B\x1b[B\x1b[B\x1b[B\x11");
    var out = std.Io.Writer.Allocating.init(a);
    defer out.deinit();

    try ed.runWithIO(&reader, &out.writer);

    const tab = ed.currentTab().?;
    try std.testing.expectEqual(@as(usize, 5), tab.mainCursor().row);
    try std.testing.expectEqual(@as(usize, 0), tab.mainCursor().col);
}

test "Editor: mode-changing input renders before draining queued quit" {
    const a = std.testing.allocator;
    const logger = try th.setupLogger(a);
    defer logger.deinit();

    var ed = try th.makeEmptyEditor(a);
    defer ed.deinit();

    var reader = std.Io.Reader.fixed("\x0f\x11");
    var out = std.Io.Writer.Allocating.init(a);
    defer out.deinit();

    try ed.runWithIO(&reader, &out.writer);

    const rendered = out.written();
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Open file:") != null);
    try std.testing.expect(ed.should_quit);
}

test "Editor: tab LSP notification gate only opens once per dirty revision" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{"hello"});
    defer ed.deinit();

    const tab = ed.currentTab().?;
    try tab.buf.setFilename("main.zig");
    tab.lsp_notified_revision = tab.buf.revision;

    try std.testing.expect(!tab.needsLspChangeNotification());
    try tab.buf.insertChar(0, 5, '!');
    try std.testing.expect(tab.needsLspChangeNotification());

    tab.markLspChangeNotified();
    try std.testing.expect(!tab.needsLspChangeNotification());
}

// ── calculateGutterWidth ──────────────────────────────────────────────────────

test "Editor: calculateGutterWidth boundary values" {
    const a = std.testing.allocator;
    const cfg = config.Config{};
    var ed = try Editor.init(a, std.testing.io, cfg);
    defer ed.deinit();
    // No tabs to deinit, just the struct.

    // min is 2 digits → 1 + 2 + 1 = 4
    try std.testing.expectEqual(@as(usize, 4), ed.calculateGutterWidth(0));
    try std.testing.expectEqual(@as(usize, 4), ed.calculateGutterWidth(1));
    try std.testing.expectEqual(@as(usize, 4), ed.calculateGutterWidth(9));
    try std.testing.expectEqual(@as(usize, 4), ed.calculateGutterWidth(10));
    try std.testing.expectEqual(@as(usize, 4), ed.calculateGutterWidth(99));
    // 3 digits → 1 + 3 + 1 = 5
    try std.testing.expectEqual(@as(usize, 5), ed.calculateGutterWidth(100));
    try std.testing.expectEqual(@as(usize, 5), ed.calculateGutterWidth(999));
    // 4 digits → 1 + 4 + 1 = 6
    try std.testing.expectEqual(@as(usize, 6), ed.calculateGutterWidth(1000));
}

// ── clampScroll ───────────────────────────────────────────────────────────────

test "Editor: clampScroll pulls scroll_row up when cursor is above viewport" {
    const a = std.testing.allocator;
    const lines = [_][]const u8{ "a", "b", "c", "d", "e", "f", "g", "h", "i", "j" };
    var ed = try th.makeEditor(a, &lines);
    defer ed.deinit();

    const tab = ed.currentTab().?;
    tab.scroll_row = 5; // viewport shows rows 5-7 (3-row content area in a 24-row terminal)
    tab.mainCursor().row = 2; // cursor is above viewport

    ed.clampScroll();
    try std.testing.expectEqual(@as(usize, 2), tab.scroll_row);
}

test "Editor: clampScroll pushes scroll_row down when cursor is below viewport" {
    const a = std.testing.allocator;
    const lines = [_][]const u8{ "a", "b", "c", "d", "e", "f", "g", "h", "i", "j" };
    var ed = try th.makeEditor(a, &lines);
    defer ed.deinit();

    // terminal height = 24, top_reserved = 2, bot_reserved = 1 → visible = 21
    const tab = ed.currentTab().?;
    tab.scroll_row = 0;
    tab.mainCursor().row = 22; // below viewport (0 + 21 = 21)

    ed.clampScroll();
    try std.testing.expect(tab.scroll_row > 0);
    // cursor should be within [scroll_row, scroll_row + 21)
    try std.testing.expect(tab.mainCursor().row >= tab.scroll_row);
}
