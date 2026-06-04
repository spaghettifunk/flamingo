const editor = @import("editor.zig");

pub fn deleteSelection(ed: *editor.Editor) !bool {
    const tab = ed.currentTab() orelse return false;
    const mc = tab.mainCursor();
    const ss = mc.selection_start orelse return false;
    const start = if (ss.row < mc.row or (ss.row == mc.row and ss.col < mc.col)) ss else editor.Pos{ .row = mc.row, .col = mc.col };
    const end = if (ss.row < mc.row or (ss.row == mc.row and ss.col < mc.col)) editor.Pos{ .row = mc.row, .col = mc.col } else ss;

    if (start.row == end.row and start.col == end.col) {
        mc.selection_start = null;
        return false;
    }

    try tab.buf.deleteRange(start.row, start.col, end.row, end.col);
    mc.row = start.row;
    mc.col = start.col;
    mc.selection_start = null;
    mc.preferred_col = null;
    return true;
}

pub fn copy(ed: *editor.Editor) !void {
    const tab = ed.currentTab() orelse return;
    const mc = tab.mainCursor();

    if (mc.selection_start) |ss| {
        const start = if (ss.row < mc.row or (ss.row == mc.row and ss.col < mc.col)) ss else editor.Pos{ .row = mc.row, .col = mc.col };
        const end = if (ss.row < mc.row or (ss.row == mc.row and ss.col < mc.col)) editor.Pos{ .row = mc.row, .col = mc.col } else ss;

        if (ed.state.clipboard) |c| ed.allocator.free(c);
        ed.state.clipboard = try tab.buf.getRange(start.row, start.col, end.row, end.col);
    } else {
        // Copy current line
        const line_data = try tab.buf.lines.items[mc.row].slice(ed.allocator);
        defer ed.allocator.free(line_data);

        if (ed.state.clipboard) |c| ed.allocator.free(c);
        ed.state.clipboard = try ed.allocator.dupe(u8, line_data);
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
        try deleteLine(ed);
    }
}

pub fn paste(ed: *editor.Editor) !void {
    const tab = ed.currentTab() orelse return;
    const content = ed.state.clipboard orelse return;
    const mc = tab.mainCursor();

    tab.buf.beginUndoGroup();
    defer tab.buf.endUndoGroup();

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

pub fn deleteWordBack(ed: *editor.Editor) !void {
    if (try deleteSelection(ed)) return;

    const tab = ed.currentTab() orelse return;
    const mc = tab.mainCursor();
    const end = editor.Pos{ .row = mc.row, .col = mc.col };
    var start = end;

    try tab.buf.jumpWordLeft(&start.row, &start.col);
    if (start.row == end.row and start.col == end.col) return;

    try tab.buf.deleteRange(start.row, start.col, end.row, end.col);
    mc.row = start.row;
    mc.col = start.col;
    mc.selection_start = null;
}

pub fn undo(ed: *editor.Editor) !void {
    const tab = ed.currentTab() orelse return;
    if (try tab.buf.undo()) {
        const mc = tab.mainCursor();
        if (mc.row >= tab.buf.lines.items.len) mc.row = tab.buf.lines.items.len - 1;
        mc.col = @min(mc.col, tab.buf.lines.items[mc.row].len());
        mc.selection_start = null;
        ed.clampScroll();
    }
}

pub fn redo(ed: *editor.Editor) !void {
    const tab = ed.currentTab() orelse return;
    if (try tab.buf.redo()) {
        const mc = tab.mainCursor();
        if (mc.row >= tab.buf.lines.items.len) mc.row = tab.buf.lines.items.len - 1;
        mc.col = @min(mc.col, tab.buf.lines.items[mc.row].len());
        mc.selection_start = null;
        ed.clampScroll();
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
    const line_len = tab.buf.lines.items[mc.row].len();

    tab.buf.beginUndoGroup();
    defer tab.buf.endUndoGroup();

    try tab.buf.insertNewline(mc.row, line_len);
    for (line_data, 0..) |c, i| {
        try tab.buf.insertChar(mc.row + 1, i, c);
    }
}

pub fn deleteLine(ed: *editor.Editor) !void {
    const tab = ed.currentTab() orelse return;
    const mc = tab.mainCursor();

    if (tab.buf.lines.items.len == 1) {
        try tab.buf.deleteRange(0, 0, 0, tab.buf.lines.items[0].len());
    } else if (mc.row + 1 < tab.buf.lines.items.len) {
        try tab.buf.deleteRange(mc.row, 0, mc.row + 1, 0);
    } else {
        const previous_row = mc.row - 1;
        const previous_len = tab.buf.lines.items[previous_row].len();
        try tab.buf.deleteRange(previous_row, previous_len, mc.row, tab.buf.lines.items[mc.row].len());
        mc.row = previous_row;
    }

    if (mc.row >= tab.buf.lines.items.len) mc.row = tab.buf.lines.items.len - 1;
    mc.col = 0;
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
    tab.multi_cursor.clear(ed.allocator);
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
