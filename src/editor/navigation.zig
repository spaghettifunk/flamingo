const editor = @import("editor.zig");
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
