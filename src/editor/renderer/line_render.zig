const std = @import("std");
const buffer = @import("../model/buffer.zig");
const search = @import("../search.zig");
const syntax = @import("../syntax.zig");
const tab_mod = @import("../model/tab.zig");
const comments = @import("../comments.zig");
const render_mod = @import("virtual_screen.zig");

const Cursor = tab_mod.Cursor;
const Tab = tab_mod.Tab;

pub const SelectionRange = struct {
    start_col: usize,
    end_col: usize,

    fn contains(self: SelectionRange, col: usize) bool {
        return col >= self.start_col and col < self.end_col;
    }
};

pub const LineRenderState = struct {
    line: *const buffer.Line,
    content_width: usize,
    syntax_cursor: syntax.HighlightRunCursor,
    search_match: ?search.Match,
    active_match_col: ?usize,
    selection_ranges: []const SelectionRange,
    comment_ranges: []const comments.RenderRange,

    fn syntaxStyleAt(self: *LineRenderState, col: usize) ?syntax.Style {
        return self.syntax_cursor.styleAt(col);
    }

    fn isSelected(self: *const LineRenderState, col: usize) bool {
        for (self.selection_ranges) |range| {
            if (range.contains(col)) return true;
        }
        return false;
    }

    fn commentStyleAt(self: *const LineRenderState, col: usize) ?render_mod.RenderStyle {
        for (self.comment_ranges) |range| {
            if (range.contains(col)) return if (range.stale) .comment_stale_highlight else .comment_highlight;
        }
        return null;
    }
};

pub fn buildLineRenderState(
    editor: anytype,
    tab: *Tab,
    buffer_line_idx: usize,
    content_width: usize,
    selection_storage: *[64]SelectionRange,
    comment_storage: *[64]comments.RenderRange,
) LineRenderState {
    const search_match = if (editor.state.search_buffer.items.len > 0)
        if (editor.state.search_system) |s| s.matchForRow(buffer_line_idx) else null
    else
        null;
    const active_match_col = if (editor.state.search_buffer.items.len > 0)
        if (editor.state.search_system) |s|
            if (s.activeMatchRow()) |active_row|
                if (active_row == buffer_line_idx) s.getActiveMatch().?.col else null
            else
                null
        else
            null
    else
        null;

    const selection_ranges = buildSelectionRanges(tab, buffer_line_idx, selection_storage);
    const comment_ranges = if (tab.buf.filename) |filename|
        comments.buildRenderRangesForLine(&editor.state.comments_panel.store, editor.state.workspace.root_path, filename, buffer_line_idx, comment_storage)
    else
        comment_storage[0..0];
    return .{
        .line = &tab.buf.lines.items[buffer_line_idx],
        .content_width = content_width,
        .syntax_cursor = tab.syntax_highlighter.highlightRunCursor(buffer_line_idx),
        .search_match = search_match,
        .active_match_col = active_match_col,
        .selection_ranges = selection_ranges,
        .comment_ranges = comment_ranges,
    };
}

pub fn buildSelectionRanges(tab: *const Tab, row: usize, storage: *[64]SelectionRange) []const SelectionRange {
    var count: usize = 0;
    for (tab.cursors.items) |cursor| {
        const range = selectionRangeForRow(cursor, row) orelse continue;
        if (count == storage.len) break;
        storage[count] = range;
        count += 1;
    }
    if (tab.multi_cursor.active) {
        for (tab.multi_cursor.selections.items) |range| {
            if (count == storage.len) break;
            if (row > range.start_line and row < range.end_line) {
                storage[count] = .{ .start_col = 0, .end_col = std.math.maxInt(usize) };
                count += 1;
            } else if (row == range.start_line and row == range.end_line) {
                storage[count] = .{ .start_col = range.start_col, .end_col = range.end_col };
                count += 1;
            } else if (row == range.start_line) {
                storage[count] = .{ .start_col = range.start_col, .end_col = std.math.maxInt(usize) };
                count += 1;
            } else if (row == range.end_line) {
                storage[count] = .{ .start_col = 0, .end_col = range.end_col };
                count += 1;
            }
        }
    }
    return storage[0..count];
}

pub fn selectionRangeForRow(cursor: Cursor, row: usize) ?SelectionRange {
    const ss = cursor.selection_start orelse return null;
    const s_row = @min(ss.row, cursor.row);
    const e_row = @max(ss.row, cursor.row);
    const s_col = if (ss.row < cursor.row) ss.col else if (ss.row > cursor.row) cursor.col else @min(ss.col, cursor.col);
    const e_col = if (ss.row < cursor.row) cursor.col else if (ss.row > cursor.row) ss.col else @max(ss.col, cursor.col);

    if (row > s_row and row < e_row) return .{ .start_col = 0, .end_col = std.math.maxInt(usize) };
    if (row == s_row and row == e_row) return .{ .start_col = s_col, .end_col = e_col };
    if (row == s_row) return .{ .start_col = s_col, .end_col = std.math.maxInt(usize) };
    if (row == e_row) return .{ .start_col = 0, .end_col = e_col };
    return null;
}

pub fn renderStyleFromSyntax(style: syntax.Style) render_mod.RenderStyle {
    return switch (style) {
        .keyword => .keyword,
        .string => .string,
        .comment => .comment,
        .number => .number,
        .constant => .constant,
        .type => .type_name,
        .function => .function_name,
        .property => .property,
        .operator => .operator,
        .punctuation => .punctuation,
    };
}

pub fn renderVirtualLine(editor: anytype, tab: *Tab, buffer_line_idx: usize, row: usize, ctx: anytype) void {
    const trace = editor.active_keypress_trace;
    if (trace) |keypress_trace| keypress_trace.visible_rows += 1;

    const start_col = ctx.buf_start_col -| 1;
    const mc = tab.mainCursor();
    const is_current = buffer_line_idx == mc.row;
    const line_num = buffer_line_idx + 1;

    var gutter_buf: [32]u8 = undefined;
    const num_digits = @max(buffer.countDigits(tab.buf.lines.items.len), 2);
    const gutter = std.fmt.bufPrint(&gutter_buf, "{d}", .{line_num}) catch "";
    var gutter_col: usize = 1;
    if (num_digits > gutter.len) {
        gutter_col += num_digits - gutter.len;
    }
    editor.renderer.screen.writeText(row, start_col + gutter_col, gutter, if (is_current) .gutter_current else .dim);
    if (tab.buf.filename) |filename| {
        if (editor.state.git_diff.getLineChange(filename, buffer_line_idx)) |change| {
            const marker_col = start_col + ctx.gutter_width -| 2;
            const style: render_mod.RenderStyle = switch (change.kind) {
                .added => .git_diff_added,
                .modified => .git_diff_modified,
                .deleted => .git_diff_deleted,
            };
            editor.renderer.screen.setGlyph(row, marker_col, "▌", style);
        }
    }

    const content_col = start_col + ctx.gutter_width;
    const content_width = ctx.buf_width -| ctx.gutter_width;
    const line = tab.buf.lines.items[buffer_line_idx];
    const line_len = line.len();

    var selection_storage: [64]SelectionRange = undefined;
    var comment_storage: [64]comments.RenderRange = undefined;
    var line_state = buildLineRenderState(editor, tab, buffer_line_idx, content_width, &selection_storage, &comment_storage);

    var char_idx: usize = tab.scroll_col;
    var m_idx: usize = 0;
    if (line_state.search_match) |m| {
        while (m_idx < m.indices.len and m.indices[m_idx] < tab.scroll_col) : (m_idx += 1) {}
    }
    const end_col = @min(line_len, tab.scroll_col +| content_width);
    while (char_idx < end_col) : (char_idx += 1) {
        const ch = line.byteAt(char_idx) orelse ' ';
        if (trace) |keypress_trace| {
            keypress_trace.visible_chars += 1;
            keypress_trace.line_byte_reads += 1;
        }
        var style: render_mod.RenderStyle = if (line_state.syntaxStyleAt(char_idx)) |syntax_style|
            renderStyleFromSyntax(syntax_style)
        else
            .normal;

        if (line_state.commentStyleAt(char_idx)) |comment_style| {
            style = comment_style;
        }

        if (line_state.isSelected(char_idx)) {
            style = .selection;
        }

        const is_match = if (line_state.search_match) |m| m_idx < m.indices.len and m.indices[m_idx] == char_idx else false;
        if (is_match) {
            if (line_state.active_match_col != null and line_state.active_match_col.? == char_idx) {
                style = .search_active;
            } else {
                style = .search_match;
            }
            m_idx += 1;
        }

        editor.renderer.screen.set(row, content_col + (char_idx - tab.scroll_col), ch, style);
    }

    if (tab.multi_cursor.active and tab.multi_cursor.cursors.items.len > 0) {
        for (tab.multi_cursor.cursors.items) |cursor| {
            if (cursor.row != buffer_line_idx) continue;
            if (cursor.row == mc.row and cursor.col == mc.col) continue;
            if (cursor.col < tab.scroll_col or cursor.col >= tab.scroll_col +| content_width) continue;
            const screen_col = content_col + (cursor.col - tab.scroll_col);
            const ch = if (cursor.col < line_len) line.byteAt(cursor.col) orelse ' ' else ' ';
            editor.renderer.screen.set(row, screen_col, ch, .multi_cursor);
        }
    }

    if (tab.buf.foldStartingAt(buffer_line_idx)) |fold| {
        var marker_buf: [48]u8 = undefined;
        const marker = std.fmt.bufPrint(&marker_buf, "  ⋯ {d} lines folded", .{fold.end_line - fold.start_line}) catch "";
        const marker_offset = line_len -| tab.scroll_col;
        if (tab.scroll_col <= line_len and marker_offset < content_width) {
            editor.renderer.screen.writeText(row, content_col + marker_offset, marker, .dim);
        }
    }
}
