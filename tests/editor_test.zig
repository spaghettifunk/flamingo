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
    try std.testing.expectEqual(@as(usize, 1), ed.tabs.items.len);
    try std.testing.expectEqual(@as(usize, 0), ed.active_tab_index);

    const b2 = try Buffer.init(a);
    try ed.addTab(b2);
    try std.testing.expectEqual(@as(usize, 2), ed.tabs.items.len);
    try std.testing.expectEqual(@as(usize, 1), ed.active_tab_index);
}

test "Editor: closeTab on only tab switches to Dashboard" {
    const a = std.testing.allocator;
    var ed = try th.makeEmptyEditor(a);
    defer ed.deinit();

    const b = try Buffer.init(a);
    try ed.addTab(b);
    ed.mode = .Normal;

    ed.closeTab();

    try std.testing.expectEqual(@as(usize, 0), ed.tabs.items.len);
    try std.testing.expectEqual(editor_mod.EditorMode.Dashboard, ed.mode);
    try std.testing.expectEqual(@as(usize, 0), ed.active_tab_index);
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
    ed.active_tab_index = 2;
    ed.closeTab();
    try std.testing.expectEqual(@as(usize, 2), ed.tabs.items.len);
    try std.testing.expectEqual(@as(usize, 1), ed.active_tab_index);
}

test "Editor: nextTab and prevTab wrap around" {
    const a = std.testing.allocator;
    var ed = try th.makeEmptyEditor(a);
    defer ed.deinit();

    for (0..3) |_| {
        const b = try Buffer.init(a);
        try ed.addTab(b);
    }

    ed.active_tab_index = 0;
    ed.nextTab();
    try std.testing.expectEqual(@as(usize, 1), ed.active_tab_index);

    ed.active_tab_index = 2;
    ed.nextTab();
    try std.testing.expectEqual(@as(usize, 0), ed.active_tab_index); // wrap

    ed.active_tab_index = 0;
    ed.prevTab();
    try std.testing.expectEqual(@as(usize, 2), ed.active_tab_index); // wrap backwards
}

test "Editor: nextTab / prevTab are no-ops with one tab" {
    const a = std.testing.allocator;
    var ed = try th.makeEmptyEditor(a);
    defer ed.deinit();

    const b = try Buffer.init(a);
    try ed.addTab(b);

    ed.active_tab_index = 0;
    ed.nextTab();
    try std.testing.expectEqual(@as(usize, 0), ed.active_tab_index);

    ed.prevTab();
    try std.testing.expectEqual(@as(usize, 0), ed.active_tab_index);
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
    try std.testing.expectEqual(@as(usize, 0), ed.tabs.items.len);
    try std.testing.expectEqual(editor_mod.EditorMode.Dashboard, ed.mode);
    try std.testing.expectEqual(@as(usize, 0), ed.active_tab_index);
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

    ed.active_tab_index = 0;
    try std.testing.expect(ed.currentTab() != null);
    try std.testing.expectEqual(&ed.tabs.items[0], ed.currentTab().?);
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
