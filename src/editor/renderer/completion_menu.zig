const std = @import("std");
const viewport_mod = @import("../navigation/viewport.zig");
const popup = @import("popup.zig");
const render_mod = @import("virtual_screen.zig");

pub fn renderVirtualCompletionMenu(editor: anytype) void {
    if (!editor.state.lsp_ui.completion_active or editor.state.lsp_ui.completion_items == null) return;
    if (editor.width < 24 or editor.height < 8) return;
    const tab = editor.currentTab() orelse return;
    const mc = tab.mainCursor();
    const viewport = viewport_mod.bufferViewportGeometry(editor);
    const gutter_width = editor.calculateGutterWidth(tab.buf.lines.items.len);
    const content_width = viewport.width -| gutter_width;
    const rel_row = mc.row -| tab.scroll_row;
    var col = (viewport.start_col -| 1) + gutter_width + viewport_mod.visibleCursorCol(mc.col, tab.scroll_col, content_width);
    const items = editor.state.lsp_ui.completionItems();
    if (items.len == 0) {
        editor.state.lsp_ui.clearCompletion();
        return;
    }

    const matching_count = matchingCompletionCount(tab, items);
    if (matching_count == 0) {
        editor.state.lsp_ui.clearCompletion();
        return;
    }
    const selected_idx = selectedMatchingCompletionIndex(tab, items, editor.state.lsp_ui.completion_selected) orelse {
        editor.state.lsp_ui.clearCompletion();
        return;
    };
    editor.state.lsp_ui.completion_selected = selected_idx;
    const selected_ordinal = matchingCompletionOrdinal(tab, items, selected_idx) orelse 0;
    const selected_item = completionItemObject(items[selected_idx]);
    const has_detail = if (selected_item) |item| completionItemDetail(item) != null else false;
    const has_docs = if (selected_item) |item| completionItemDocumentation(item) != null else false;
    const detail_rows: usize = if (has_detail or has_docs) 3 else 0;

    const max_width = @min(@as(usize, 72), editor.width -| 2);
    if (max_width < 24) return;
    const width = @max(@as(usize, 36), @min(max_width, content_width + gutter_width));
    if (col + width > editor.width) col = editor.width -| width;

    const max_items = @min(@as(usize, 8), editor.height -| 5);
    const visible_count = @min(matching_count, max_items);
    const extra_rows: usize = if (detail_rows > 0) detail_rows + 1 else 0;
    const total_height = visible_count + extra_rows + 2;
    const drawable_height = editor.height - 1;
    if (total_height > drawable_height) return;

    var row = rel_row + 4;
    if (row + total_height > drawable_height) {
        row = (rel_row + 3) -| total_height;
    }
    if (row + total_height > drawable_height) {
        row = drawable_height - total_height;
    }
    var scroll_top: usize = 0;
    if (selected_ordinal >= max_items) {
        scroll_top = selected_ordinal - max_items + 1;
    }

    const screen = &editor.renderer.screen;
    const geom = popup.FilesystemPickerGeometry{
        .row = row,
        .col = col,
        .width = width,
        .height = total_height,
    };
    popup.drawPickerTop(screen, geom, " Completion ", .command_popup_border);

    var rendered: usize = 0;
    var match_ordinal: usize = 0;
    for (items, 0..) |value, item_idx| {
        const item = completionItemObject(value) orelse continue;
        if (!completionItemMatchesTabPrefix(tab, item)) continue;
        defer match_ordinal += 1;
        if (match_ordinal < scroll_top) continue;
        if (rendered >= visible_count) break;
        const label = completionItemString(item, "label") orelse continue;
        const selected = item_idx == selected_idx;
        const style: render_mod.RenderStyle = if (selected) .command_popup_selected else .command_popup;
        const render_row = row + 1 + rendered;
        popup.drawPickerRow(screen, render_row, col, width, .command_popup_border, style);

        const end_col = col + width - 1;
        const kind_col = col + 2;
        const kind_width: usize = 6;
        const separator_col = kind_col + kind_width;
        const label_col = separator_col + 3;
        const kind_style: render_mod.RenderStyle = if (selected) style else .command_popup_prompt;

        var kind_write_col = kind_col;
        popup.writeVirtualTruncatedCells(screen, render_row, &kind_write_col, @min(separator_col, end_col), completionKindLabel(item), kind_style, false);
        if (separator_col + 3 < end_col) {
            screen.writeText(render_row, separator_col, " | ", style);
            var label_write_col = label_col;
            popup.writeVirtualTruncatedCells(screen, render_row, &label_write_col, end_col, label, style, false);
        }
        rendered += 1;
    }

    if (selected_item) |item| {
        if (detail_rows > 0) {
            const sep_row = row + 1 + visible_count;
            popup.drawPickerSeparator(screen, sep_row, col, width, .command_popup_border);
            renderSelectedItemDetails(screen, item, sep_row + 1, col, width, detail_rows);
        }
    }

    popup.drawPickerBottom(screen, row + total_height - 1, col, width, .command_popup_border);
}

pub fn completionItemObject(value: std.json.Value) ?std.json.ObjectMap {
    if (value != .object) return null;
    return value.object;
}

pub fn completionItemString(item: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = item.get(key) orelse return null;
    if (value != .string) return null;
    return value.string;
}

pub fn completionItemDetail(item: std.json.ObjectMap) ?[]const u8 {
    return completionItemString(item, "detail");
}

pub fn completionItemDocumentation(item: std.json.ObjectMap) ?[]const u8 {
    const value = item.get("documentation") orelse return null;
    if (value == .string) return value.string;
    if (value == .object) {
        const text = value.object.get("value") orelse return null;
        if (text == .string) return text.string;
    }
    return null;
}

pub fn completionItemInsertText(item: std.json.ObjectMap) ?[]const u8 {
    return completionItemString(item, "insertText") orelse completionItemString(item, "filterText");
}

pub fn completionKindLabel(item: std.json.ObjectMap) []const u8 {
    const kind_val = if (item.get("kind")) |k|
        if (k == .integer) @as(u8, @intCast(k.integer)) else @as(u8, 0)
    else
        @as(u8, 0);

    return switch (kind_val) {
        1 => "Text",
        2 => "Method",
        3 => "Fn",
        4 => "Const",
        5 => "Field",
        6 => "Var",
        7 => "Class",
        8 => "Intf",
        9 => "Mod",
        10 => "Prop",
        13 => "Enum",
        14 => "Key",
        15 => "Snip",
        21 => "Const",
        22 => "Struct",
        else => "",
    };
}

fn matchingCompletionCount(tab: anytype, items: []std.json.Value) usize {
    var count: usize = 0;
    for (items) |value| {
        const item = completionItemObject(value) orelse continue;
        if (completionItemMatchesTabPrefix(tab, item)) count += 1;
    }
    return count;
}

fn selectedMatchingCompletionIndex(tab: anytype, items: []std.json.Value, selected_idx: usize) ?usize {
    if (selected_idx < items.len) {
        if (completionItemObject(items[selected_idx])) |item| {
            if (completionItemMatchesTabPrefix(tab, item)) return selected_idx;
        }
    }
    for (items, 0..) |value, idx| {
        const item = completionItemObject(value) orelse continue;
        if (completionItemMatchesTabPrefix(tab, item)) return idx;
    }
    return null;
}

fn matchingCompletionOrdinal(tab: anytype, items: []std.json.Value, selected_idx: usize) ?usize {
    var ordinal: usize = 0;
    for (items, 0..) |value, idx| {
        const item = completionItemObject(value) orelse continue;
        if (!completionItemMatchesTabPrefix(tab, item)) continue;
        if (idx == selected_idx) return ordinal;
        ordinal += 1;
    }
    return null;
}

fn completionItemMatchesTabPrefix(tab: anytype, item: std.json.ObjectMap) bool {
    const candidate = completionItemFilterText(item) orelse return false;
    const mc = tab.mainCursor();
    if (mc.row >= tab.buf.lines.items.len) return false;
    const line = &tab.buf.lines.items[mc.row];
    const prefix_len = identifierPrefixLen(tab);
    if (prefix_len == 0) return true;
    if (candidate.len < prefix_len or mc.col < prefix_len) return false;
    const start_col = mc.col - prefix_len;
    for (0..prefix_len) |i| {
        const ch = line.byteAt(start_col + i) orelse return false;
        if (candidate[i] != ch) return false;
    }
    return true;
}

fn completionItemFilterText(item: std.json.ObjectMap) ?[]const u8 {
    return completionItemString(item, "filterText") orelse
        completionItemInsertText(item) orelse
        completionItemString(item, "label");
}

fn identifierPrefixLen(tab: anytype) usize {
    const mc = tab.mainCursor();
    if (mc.row >= tab.buf.lines.items.len) return 0;
    const line = &tab.buf.lines.items[mc.row];
    var col = @min(mc.col, line.len());
    var count: usize = 0;
    while (col > 0) {
        const ch = line.byteAt(col - 1) orelse break;
        if (!isIdentifierChar(ch)) break;
        count += 1;
        col -= 1;
    }
    return count;
}

fn isIdentifierChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

fn renderSelectedItemDetails(screen: *render_mod.VirtualScreen, item: std.json.ObjectMap, start_row: usize, col: usize, width: usize, rows: usize) void {
    var row = start_row;
    var remaining_rows = rows;
    if (completionItemDetail(item)) |detail| {
        writeDetailRow(screen, row, col, width, "detail", detail);
        row += 1;
        remaining_rows -|= 1;
    }
    if (remaining_rows == 0) return;

    const docs = completionItemDocumentation(item) orelse {
        fillDetailRows(screen, row, col, width, remaining_rows);
        return;
    };
    var text = std.mem.trim(u8, docs, " \t\r\n");
    var wrote_docs_label = false;
    while (remaining_rows > 0) {
        const line = nextDisplayLine(&text);
        writeDetailRow(screen, row, col, width, if (!wrote_docs_label) "docs" else "", line);
        wrote_docs_label = true;
        row += 1;
        remaining_rows -= 1;
        if (text.len == 0) break;
    }
    fillDetailRows(screen, row, col, width, remaining_rows);
}

fn fillDetailRows(screen: *render_mod.VirtualScreen, start_row: usize, col: usize, width: usize, rows: usize) void {
    for (0..rows) |offset| {
        popup.drawPickerRow(screen, start_row + offset, col, width, .command_popup_border, .command_popup);
    }
}

fn writeDetailRow(screen: *render_mod.VirtualScreen, row: usize, col: usize, width: usize, label: []const u8, text: []const u8) void {
    popup.drawPickerRow(screen, row, col, width, .command_popup_border, .command_popup);
    var write_col = col + 2;
    const end_col = col + width - 1;
    if (label.len > 0) {
        popup.writeVirtualTruncatedCells(screen, row, &write_col, end_col, label, .popup_footer, false);
        if (write_col + 2 < end_col) {
            screen.writeText(row, write_col, ": ", .popup_footer);
            write_col += 2;
        }
    }
    popup.writeVirtualTruncatedCells(screen, row, &write_col, end_col, std.mem.trim(u8, text, " \t\r\n"), .completion_detail, false);
}

fn nextDisplayLine(text: *[]const u8) []const u8 {
    const current = text.*;
    const newline = std.mem.indexOfScalar(u8, current, '\n') orelse {
        text.* = "";
        return current;
    };
    text.* = current[newline + 1 ..];
    return current[0..newline];
}

test "completion item documentation accepts string and markup content" {
    const allocator = std.testing.allocator;

    var string_doc = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"label":"foo","documentation":"plain docs"}
    ,
        .{},
    );
    defer string_doc.deinit();
    const string_item = completionItemObject(string_doc.value) orelse return error.ExpectedObject;
    try std.testing.expectEqualStrings("plain docs", completionItemDocumentation(string_item).?);

    var markup_doc = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"label":"bar","documentation":{"kind":"markdown","value":"markdown docs"}}
    ,
        .{},
    );
    defer markup_doc.deinit();
    const markup_item = completionItemObject(markup_doc.value) orelse return error.ExpectedObject;
    try std.testing.expectEqualStrings("markdown docs", completionItemDocumentation(markup_item).?);
}
