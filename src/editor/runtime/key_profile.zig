const terminal = @import("../../terminal.zig");
const perf = @import("../../perf/perf.zig");

pub const KeypressProfilePosition = struct {
    row: usize = 0,
    col: usize = 0,
    scroll_row: usize = 0,
    selection_active: bool = false,
};

pub fn noteKeypressMovementHandled(editor: anytype, handled: bool) void {
    if (!handled) return;
    editor.last_input_movement_handled = true;
    if (editor.active_keypress_trace) |trace| {
        trace.movement_handled = true;
    }
}

pub fn captureKeypressProfilePosition(editor: anytype) KeypressProfilePosition {
    const tab = editor.currentTab() orelse return .{};
    if (tab.cursors.items.len == 0) return .{ .scroll_row = tab.scroll_row };
    const mc = tab.mainCursor();
    return .{
        .row = mc.row,
        .col = mc.col,
        .scroll_row = tab.scroll_row,
        .selection_active = mc.selection_start != null,
    };
}

pub fn initKeypressTrace(editor: anytype, event: terminal.KeyEvent, key_name: []const u8) perf.KeypressTrace {
    const pos = captureKeypressProfilePosition(editor);
    return .{
        .key = key_name,
        .mode = @tagName(editor.state.mode),
        .before_row = pos.row,
        .before_col = pos.col,
        .after_row = pos.row,
        .after_col = pos.col,
        .before_scroll_row = pos.scroll_row,
        .after_scroll_row = pos.scroll_row,
        .dirty = keypressDirtyState(editor),
        .explorer_visible = editor.state.explorer_visible,
        .explorer_focused = editor.state.explorer_focused,
        .completion_active = editor.state.lsp_ui.completion_active,
        .search_active = editor.state.search_buffer.items.len > 0,
        .selection_active = pos.selection_active or event.shift,
    };
}

pub fn updateKeypressTraceAfterDispatch(editor: anytype, trace: *perf.KeypressTrace) void {
    const pos = captureKeypressProfilePosition(editor);
    trace.after_row = pos.row;
    trace.after_col = pos.col;
    trace.after_scroll_row = pos.scroll_row;
    trace.scroll_delta = signedDelta(trace.before_scroll_row, pos.scroll_row);
    trace.cursor_moved = trace.before_row != pos.row or trace.before_col != pos.col;
    trace.viewport_scrolled = trace.viewport_scrolled or trace.before_scroll_row != pos.scroll_row;
    trace.explorer_visible = editor.state.explorer_visible;
    trace.explorer_focused = editor.state.explorer_focused;
    trace.completion_active = editor.state.lsp_ui.completion_active;
    trace.search_active = editor.state.search_buffer.items.len > 0;
    trace.selection_active = trace.selection_active or pos.selection_active;
}

pub fn signedDelta(before: usize, after: usize) i64 {
    if (after >= before) return @intCast(after - before);
    return -@as(i64, @intCast(before - after));
}

pub fn keypressDirtyState(editor: anytype) perf.KeypressDirtyState {
    if (!editor.state.render_dirty) return .clean;
    if (editor.state.force_full_render) return .full;
    return .partial;
}

pub fn formatKeyName(event: terminal.KeyEvent, buf: *[32]u8) []const u8 {
    var idx: usize = 0;
    idx = appendKeyPart(buf, idx, event.ctrl, "Ctrl+");
    idx = appendKeyPart(buf, idx, event.alt, "Alt+");
    idx = appendKeyPart(buf, idx, event.shift, "Shift+");

    const base = switch (event.key) {
        .None => "None",
        .Backspace => "Backspace",
        .Enter => "Enter",
        .Esc => "Esc",
        .Up => "Up",
        .Down => "Down",
        .Right => "Right",
        .Left => "Left",
        .Delete => "Delete",
        .Home => "Home",
        .End => "End",
        .PageUp => "PageUp",
        .PageDown => "PageDown",
        .Char => blk: {
            if (event.char == '\t') break :blk "Tab";
            if (event.char == ' ') break :blk "Space";
            if (event.char >= 0x21 and event.char <= 0x7e and idx + 1 <= buf.len) {
                buf[idx] = event.char;
                return buf[0 .. idx + 1];
            }
            break :blk "Char";
        },
    };

    idx = appendKeyBytes(buf, idx, base);
    return buf[0..idx];
}

fn appendKeyPart(buf: *[32]u8, idx: usize, enabled: bool, text: []const u8) usize {
    if (!enabled) return idx;
    return appendKeyBytes(buf, idx, text);
}

fn appendKeyBytes(buf: *[32]u8, start: usize, text: []const u8) usize {
    var idx = start;
    for (text) |ch| {
        if (idx >= buf.len) break;
        buf[idx] = ch;
        idx += 1;
    }
    return idx;
}
