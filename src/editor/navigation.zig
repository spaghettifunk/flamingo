const editor = @import("editor.zig");
const buffer = @import("model/buffer.zig");
const jump_history = @import("state/jump_history.zig");

pub const JumpOptions = struct {
    record_history: bool = false,
};

pub fn currentLocation(ed: *editor.Editor) ?jump_history.JumpLocation {
    const tab = ed.currentTab() orelse return null;
    const mc = tab.mainCursor();
    return .{
        .buffer_id = tab.syntax_buffer_id,
        .row = mc.row,
        .col = mc.col,
    };
}

pub fn recordCurrentJump(ed: *editor.Editor) !void {
    const location = currentLocation(ed) orelse return;
    try ed.state.jump_history.recordJump(ed.allocator, location);
}

pub fn jumpTo(ed: *editor.Editor, row: usize, col: usize, options: JumpOptions) !bool {
    const tab = ed.currentTab() orelse return false;
    const old_location = currentLocation(ed) orelse return false;
    const target = clampLocation(tab, .{
        .buffer_id = tab.syntax_buffer_id,
        .row = row,
        .col = col,
    });

    if (old_location.eql(target)) return false;

    if (options.record_history) {
        try ed.state.jump_history.recordJump(ed.allocator, old_location);
    }

    applyLocationToTab(ed, tab, target);
    return true;
}

pub fn findMatchingBracket(buf: *const buffer.Buffer, start_pos: buffer.TextPoint) ?buffer.TextPoint {
    if (buf.lines.items.len == 0 or start_pos.row >= buf.lines.items.len) return null;

    const start = findBracketOnLine(buf, start_pos) orelse return null;
    const pair = bracketPair(start.char) orelse return null;

    return if (pair.opens)
        findForwardBracket(buf, start.pos, pair.open, pair.close)
    else
        findBackwardBracket(buf, start.pos, pair.open, pair.close);
}

pub fn jumpBack(ed: *editor.Editor) !bool {
    const current = currentLocation(ed) orelse return false;
    const target = ed.state.jump_history.popBack() orelse return false;
    const tab = findTabByBufferId(ed, target.buffer_id) orelse {
        try ed.state.jump_history.pushBack(ed.allocator, target);
        return false;
    };

    try ed.state.jump_history.pushForward(ed.allocator, current);
    applyLocationToTab(ed, tab, clampLocation(tab, target));
    return true;
}

const BracketStart = struct {
    pos: buffer.TextPoint,
    char: u8,
};

const BracketPair = struct {
    open: u8,
    close: u8,
    opens: bool,
};

fn bracketPair(c: u8) ?BracketPair {
    return switch (c) {
        '(' => .{ .open = '(', .close = ')', .opens = true },
        ')' => .{ .open = '(', .close = ')', .opens = false },
        '{' => .{ .open = '{', .close = '}', .opens = true },
        '}' => .{ .open = '{', .close = '}', .opens = false },
        '[' => .{ .open = '[', .close = ']', .opens = true },
        ']' => .{ .open = '[', .close = ']', .opens = false },
        else => null,
    };
}

fn findBracketOnLine(buf: *const buffer.Buffer, start_pos: buffer.TextPoint) ?BracketStart {
    const line = &buf.lines.items[start_pos.row];
    const line_len = line.len();
    var col = start_pos.col;
    while (col < line_len) : (col += 1) {
        const c = line.byteAt(col) orelse return null;
        if (bracketPair(c) != null) {
            return .{
                .pos = .{ .row = start_pos.row, .col = col },
                .char = c,
            };
        }
    }
    return null;
}

fn findForwardBracket(buf: *const buffer.Buffer, start_pos: buffer.TextPoint, open: u8, close: u8) ?buffer.TextPoint {
    var depth: usize = 1;
    var row = start_pos.row;
    var col = start_pos.col + 1;

    while (row < buf.lines.items.len) : (row += 1) {
        const line = &buf.lines.items[row];
        while (col < line.len()) : (col += 1) {
            const c = line.byteAt(col) orelse return null;
            if (c == open) {
                depth += 1;
            } else if (c == close) {
                depth -= 1;
                if (depth == 0) return .{ .row = row, .col = col };
            }
        }
        col = 0;
    }

    return null;
}

fn findBackwardBracket(buf: *const buffer.Buffer, start_pos: buffer.TextPoint, open: u8, close: u8) ?buffer.TextPoint {
    var depth: usize = 1;
    var row = start_pos.row;
    var col = start_pos.col;

    while (true) {
        const line = &buf.lines.items[row];
        var i = @min(col, line.len());
        while (i > 0) {
            i -= 1;
            const c = line.byteAt(i) orelse return null;
            if (c == close) {
                depth += 1;
            } else if (c == open) {
                depth -= 1;
                if (depth == 0) return .{ .row = row, .col = i };
            }
        }

        if (row == 0) break;
        row -= 1;
        col = buf.lines.items[row].len();
    }

    return null;
}

pub fn jumpForward(ed: *editor.Editor) !bool {
    const current = currentLocation(ed) orelse return false;
    const target = ed.state.jump_history.popForward() orelse return false;
    const tab = findTabByBufferId(ed, target.buffer_id) orelse {
        try ed.state.jump_history.pushForward(ed.allocator, target);
        return false;
    };

    try ed.state.jump_history.pushBack(ed.allocator, current);
    applyLocationToTab(ed, tab, clampLocation(tab, target));
    return true;
}

fn findTabByBufferId(ed: *editor.Editor, buffer_id: u64) ?*editor.Tab {
    for (ed.state.tabs.items, 0..) |*tab, i| {
        if (tab.syntax_buffer_id == buffer_id) {
            ed.state.active_tab_index = i;
            return tab;
        }
    }
    return null;
}

fn clampLocation(tab: *editor.Tab, location: jump_history.JumpLocation) jump_history.JumpLocation {
    var clamped = location;
    if (tab.buf.lines.items.len == 0) {
        clamped.row = 0;
        clamped.col = 0;
        return clamped;
    }

    clamped.row = @min(clamped.row, tab.buf.lines.items.len - 1);
    clamped.row = tab.buf.clampToVisibleLine(clamped.row);
    clamped.col = @min(clamped.col, tab.buf.lines.items[clamped.row].len());
    return clamped;
}

fn applyLocationToTab(ed: *editor.Editor, tab: *editor.Tab, location: jump_history.JumpLocation) void {
    const mc = tab.mainCursor();
    mc.row = location.row;
    mc.col = location.col;
    mc.preferred_col = null;
    ed.clampScroll();
}
