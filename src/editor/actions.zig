const std = @import("std");
const editor = @import("editor.zig");
const buffer = @import("buffer.zig");

pub fn copy(ed: *editor.Editor) !void {
    const tab = ed.currentTab() orelse return;
    const mc = tab.mainCursor();

    if (mc.selection_start) |ss| {
        const start = if (ss.row < mc.row or (ss.row == mc.row and ss.col < mc.col)) ss else editor.Pos{ .row = mc.row, .col = mc.col };
        const end = if (ss.row < mc.row or (ss.row == mc.row and ss.col < mc.col)) editor.Pos{ .row = mc.row, .col = mc.col } else ss;

        if (ed.clipboard) |c| ed.allocator.free(c);
        ed.clipboard = try tab.buf.getRange(start.row, start.col, end.row, end.col);
    } else {
        // Copy current line
        const line_data = try tab.buf.lines.items[mc.row].slice(ed.allocator);
        defer ed.allocator.free(line_data);

        if (ed.clipboard) |c| ed.allocator.free(c);
        ed.clipboard = try ed.allocator.dupe(u8, line_data);
    }
}

pub fn cut(ed: *editor.Editor) !void {
    const tab = ed.currentTab() orelse return;
    const mc = tab.mainCursor();

    if (mc.selection_start) |ss| {
        try copy(ed);
        const start = if (ss.row < mc.row or (ss.row == mc.row and ss.col < mc.col)) ss else editor.Pos{ .row = mc.row, .col = mc.col };
        const end = if (ss.row < mc.row or (ss.row == mc.row and ss.col < mc.col)) editor.Pos{ .row = mc.row, .col = mc.col } else ss;

        try tab.buf.deleteRange(start.row, start.col, end.row, end.col);
        mc.row = start.row;
        mc.col = start.col;
        mc.selection_start = null;
    } else {
        try copy(ed);
        // Delete current line
        var removed = tab.buf.lines.orderedRemove(mc.row);
        removed.deinit();
        if (tab.buf.lines.items.len == 0) {
            try tab.buf.lines.append(ed.allocator, try buffer.Line.init(ed.allocator));
        }
        if (mc.row >= tab.buf.lines.items.len) mc.row = tab.buf.lines.items.len - 1;
        mc.col = 0;
    }
}

pub fn paste(ed: *editor.Editor) !void {
    const tab = ed.currentTab() orelse return;
    const content = ed.clipboard orelse return;
    const mc = tab.mainCursor();

    // If selection exists, delete it first
    if (mc.selection_start) |ss| {
        const start = if (ss.row < mc.row or (ss.row == mc.row and ss.col < mc.col)) ss else editor.Pos{ .row = mc.row, .col = mc.col };
        const end = if (ss.row < mc.row or (ss.row == mc.row and ss.col < mc.col)) editor.Pos{ .row = mc.row, .col = mc.col } else ss;
        try tab.buf.deleteRange(start.row, start.col, end.row, end.col);
        mc.row = start.row;
        mc.col = start.col;
        mc.selection_start = null;
    }

    for (content) |c| {
        if (c == '\n') {
            try tab.buf.insertNewline(mc.row, mc.col);
            mc.row += 1;
            mc.col = 0;
        } else {
            try tab.buf.insertChar(mc.row, mc.col, c);
            mc.col += 1;
        }
    }
}

pub fn moveLineUp(ed: *editor.Editor) void {
    const tab = ed.currentTab() orelse return;
    const mc = tab.mainCursor();
    if (mc.row == 0) return;

    tab.buf.swapLines(mc.row, mc.row - 1);
    mc.row -= 1;
    ed.clampScroll();
}

pub fn moveLineDown(ed: *editor.Editor) void {
    const tab = ed.currentTab() orelse return;
    const mc = tab.mainCursor();
    if (mc.row >= tab.buf.lines.items.len - 1) return;

    tab.buf.swapLines(mc.row, mc.row + 1);
    mc.row += 1;
    ed.clampScroll();
}

pub fn duplicateLine(ed: *editor.Editor) !void {
    const tab = ed.currentTab() orelse return;
    const mc = tab.mainCursor();

    const line_data = try tab.buf.lines.items[mc.row].slice(ed.allocator);
    defer ed.allocator.free(line_data);

    const new_line = try buffer.Line.fromSlice(ed.allocator, line_data);
    try tab.buf.lines.insert(ed.allocator, mc.row + 1, new_line);
    tab.buf.is_dirty = true;
}

pub fn deleteLine(ed: *editor.Editor) !void {
    const tab = ed.currentTab() orelse return;
    const mc = tab.mainCursor();

    var removed = tab.buf.lines.orderedRemove(mc.row);
    removed.deinit();

    if (tab.buf.lines.items.len == 0) {
        try tab.buf.lines.append(ed.allocator, try buffer.Line.init(ed.allocator));
    }

    if (mc.row >= tab.buf.lines.items.len) mc.row = tab.buf.lines.items.len - 1;
    mc.col = 0;
    tab.buf.is_dirty = true;
}

pub fn handleSelection(tab: *editor.Tab, shift: bool) void {
    const mc = tab.mainCursor();
    if (shift) {
        if (mc.selection_start == null) {
            // Need to know where we WERE before moving.
            // This is handled in input.zig now.
        }
    } else {
        mc.selection_start = null;
    }
}

pub fn addCursorAbove(ed: *editor.Editor) !void {
    const tab = ed.currentTab() orelse return;
    const mc = tab.mainCursor();
    if (mc.row == 0) return;

    const new_cursor = editor.Cursor{
        .row = mc.row - 1,
        .col = @min(mc.col, tab.buf.lines.items[mc.row - 1].len()),
    };
    try tab.cursors.insert(ed.allocator, 0, new_cursor);
    tab.main_cursor_idx += 1;
}

pub fn addCursorBelow(ed: *editor.Editor) !void {
    const tab = ed.currentTab() orelse return;
    const mc = tab.mainCursor();
    if (mc.row >= tab.buf.lines.items.len - 1) return;

    const new_cursor = editor.Cursor{
        .row = mc.row + 1,
        .col = @min(mc.col, tab.buf.lines.items[mc.row + 1].len()),
    };
    try tab.cursors.append(ed.allocator, new_cursor);
}

pub fn clearSelections(ed: *editor.Editor) void {
    const tab = ed.currentTab() orelse return;
    for (tab.cursors.items) |*c| {
        c.selection_start = null;
    }
    // Keep only the main cursor?
    if (tab.cursors.items.len > 1) {
        const mc = tab.cursors.items[tab.main_cursor_idx];
        tab.cursors.clearRetainingCapacity();
        tab.cursors.append(ed.allocator, mc) catch {};
        tab.main_cursor_idx = 0;
    }
}

pub fn selectAll(ed: *editor.Editor) void {
    const tab = ed.currentTab() orelse return;
    clearSelections(ed);
    const mc = tab.mainCursor();
    mc.selection_start = editor.Pos{ .row = 0, .col = 0 };
    mc.row = tab.buf.lines.items.len - 1;
    mc.col = tab.buf.lines.items[mc.row].len();
}
