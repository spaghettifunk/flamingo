const std = @import("std");
const tab_mod = @import("../model/tab.zig");
const terminal_panel_mod = @import("../terminal_panel.zig");

const Tab = tab_mod.Tab;

pub const HorizontalScrollCommand = enum {
    left_small,
    right_small,
    left_half,
    right_half,
    cursor_start,
    cursor_end,
};

pub const BufferViewportGeometry = struct {
    start_col: usize,
    width: usize,
};

pub fn todoPanelWidth(editor: anytype) usize {
    if ((!editor.state.todo_panel.visible and !editor.state.comments_panel.visible) or editor.width < 72) return 0;
    const preferred: usize = 40;
    const minimum: usize = 32;
    const max_panel = editor.width / 3;
    const width = @min(preferred, max_panel);
    if (width < minimum) return 0;
    return width;
}

pub fn bufferViewportGeometry(editor: anytype) BufferViewportGeometry {
    var buf_start_col: usize = 1;
    var buf_width: usize = editor.width;

    if (editor.state.explorer_visible and editor.state.tree != null) {
        const exp_width = (editor.width * @as(usize, editor.config.explorer.width_percentage)) / 100;
        if (exp_width > 0) {
            buf_start_col = exp_width + 2;
            buf_width = editor.width -| (exp_width + 1);
        }
    }

    const todo_width = todoPanelWidth(editor);
    if (todo_width > 0) {
        buf_width -|= todo_width + 1;
    }

    return .{ .start_col = buf_start_col, .width = buf_width };
}

pub fn terminalPanelHeight(editor: anytype) usize {
    if (!editor.terminal_panel.visible) return 0;
    return terminal_panel_mod.panelHeight(editor.height);
}

pub fn statusRowIndex(editor: anytype) usize {
    const panel_height = terminalPanelHeight(editor);
    if (editor.height == 0) return 0;
    return editor.height - panel_height - 1;
}

pub fn statusTerminalRow(editor: anytype) usize {
    return statusRowIndex(editor) + 1;
}

pub fn editorVisibleRows(editor: anytype) usize {
    const top_reserved = 2;
    const bot_reserved = 1 + terminalPanelHeight(editor);
    return if (editor.height > top_reserved + bot_reserved) editor.height - (top_reserved + bot_reserved) else 0;
}

pub fn textViewportWidthForTab(editor: anytype, tab: *const Tab) usize {
    const viewport = bufferViewportGeometry(editor);
    const gutter_width = editor.calculateGutterWidth(tab.buf.lines.items.len);
    return viewport.width -| gutter_width;
}

pub fn horizontalScrollForCursor(cursor_col: usize, scroll_col: usize, visible_width: usize) usize {
    if (visible_width == 0) return scroll_col;
    if (cursor_col < scroll_col) return cursor_col;
    if (cursor_col >= scroll_col +| visible_width) return cursor_col - visible_width + 1;
    return scroll_col;
}

pub fn visibleCursorCol(cursor_col: usize, scroll_col: usize, visible_width: usize) usize {
    if (visible_width == 0 or cursor_col <= scroll_col) return 0;
    return @min(cursor_col - scroll_col, visible_width - 1);
}

pub fn maxVisibleLineLen(tab: *const Tab, visible_rows: usize) usize {
    const mc = tab.cursors.items[tab.main_cursor_idx];
    var max_len: usize = if (mc.row < tab.buf.lines.items.len) tab.buf.lines.items[mc.row].len() else 0;
    if (tab.buf.lines.items.len == 0) return max_len;
    var row = tab.buf.clampToVisibleLine(tab.scroll_row);
    var remaining = visible_rows;
    while (remaining > 0 and row < tab.buf.lines.items.len) : (remaining -= 1) {
        max_len = @max(max_len, tab.buf.lines.items[row].len());
        const next = tab.buf.nextVisibleLine(row);
        if (next == row) break;
        row = next;
    }
    return max_len;
}

pub fn visibleLineOffset(tab: *const Tab, start_line: usize, target_line: usize, max_rows: usize) ?usize {
    if (tab.buf.lines.items.len == 0) return null;
    var row = tab.buf.clampToVisibleLine(start_line);
    const target = tab.buf.clampToVisibleLine(target_line);
    var offset: usize = 0;
    while (offset < max_rows and row < tab.buf.lines.items.len) : (offset += 1) {
        if (row == target) return offset;
        const next = tab.buf.nextVisibleLine(row);
        if (next == row) break;
        row = next;
    }
    return null;
}

pub fn visibleViewportEndLine(tab: *const Tab, start_line: usize, row_count: usize) usize {
    if (tab.buf.lines.items.len == 0) return 0;
    var row = tab.buf.clampToVisibleLine(start_line);
    var last = row;
    var remaining = row_count;
    while (remaining > 0 and row < tab.buf.lines.items.len) : (remaining -= 1) {
        last = row;
        const next = tab.buf.nextVisibleLine(row);
        if (next == row) break;
        row = next;
    }
    return @min(last + 1, tab.buf.lines.items.len);
}

pub fn clampHorizontalScrollToVisibleLines(editor: anytype, tab: *Tab, visible_width: usize) void {
    const visible_rows = @max(editorVisibleRows(editor), 1);
    const max_len = maxVisibleLineLen(tab, visible_rows);
    if (visible_width == 0) {
        tab.scroll_col = @min(tab.scroll_col, max_len);
        return;
    }
    const max_scroll = max_len -| (visible_width - 1);
    tab.scroll_col = @min(tab.scroll_col, max_scroll);
}

pub fn applyHorizontalScrollCommand(editor: anytype, command: HorizontalScrollCommand) void {
    const tab = editor.currentTab() orelse return;
    const mc = tab.mainCursor();
    const visible_width = textViewportWidthForTab(editor, tab);
    if (visible_width == 0) return;

    const small_step = @max(@as(usize, 1), visible_width / 8);
    const half_step = @max(@as(usize, 1), visible_width / 2);
    switch (command) {
        .left_small => tab.scroll_col -|= small_step,
        .right_small => tab.scroll_col +|= small_step,
        .left_half => tab.scroll_col -|= half_step,
        .right_half => tab.scroll_col +|= half_step,
        .cursor_start => tab.scroll_col = mc.col,
        .cursor_end => tab.scroll_col = mc.col -| (visible_width - 1),
    }
    clampHorizontalScrollToVisibleLines(editor, tab, visible_width);
}

pub fn clampScroll(editor: anytype) void {
    const tab = editor.currentTab() orelse return;
    const mc = tab.mainCursor();
    const before_scroll_row = tab.scroll_row;
    const before_scroll_col = tab.scroll_col;
    const visible_rows = @max(editorVisibleRows(editor), 1);
    mc.row = tab.buf.clampToVisibleLine(mc.row);
    if (mc.row < tab.buf.lines.items.len) {
        mc.col = @min(mc.col, tab.buf.lines.items[mc.row].len());
    }
    tab.scroll_row = tab.buf.clampToVisibleLine(tab.scroll_row);
    if (mc.row < tab.scroll_row) {
        tab.scroll_row = mc.row;
    } else if (visibleLineOffset(tab, tab.scroll_row, mc.row, visible_rows) == null) {
        var row = mc.row;
        var remaining = visible_rows -| 1;
        while (remaining > 0) : (remaining -= 1) {
            const prev = tab.buf.prevVisibleLine(row);
            if (prev == row) break;
            row = prev;
        }
        tab.scroll_row = row;
    }
    const visible_width = textViewportWidthForTab(editor, tab);
    tab.scroll_col = horizontalScrollForCursor(mc.col, tab.scroll_col, visible_width);
    clampHorizontalScrollToVisibleLines(editor, tab, visible_width);
    if (editor.active_keypress_trace) |trace| {
        trace.viewport_scrolled = trace.viewport_scrolled or
            before_scroll_row != tab.scroll_row or
            before_scroll_col != tab.scroll_col;
    }
}
