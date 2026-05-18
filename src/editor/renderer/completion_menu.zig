const std = @import("std");
const viewport_mod = @import("../navigation/viewport.zig");
const render_mod = @import("virtual_screen.zig");

pub fn renderVirtualCompletionMenu(editor: anytype) void {
    if (!editor.state.lsp_ui.completion_active or editor.state.lsp_ui.completion_items == null) return;
    const tab = editor.currentTab() orelse return;
    const mc = tab.mainCursor();
    const viewport = viewport_mod.bufferViewportGeometry(editor);
    const gutter_width = editor.calculateGutterWidth(tab.buf.lines.items.len);
    const content_width = viewport.width -| gutter_width;
    const rel_row = mc.row -| tab.scroll_row;
    const col = (viewport.start_col -| 1) + gutter_width + viewport_mod.visibleCursorCol(mc.col, tab.scroll_col, content_width);
    const items = editor.state.lsp_ui.completionItems();
    if (items.len == 0) {
        editor.state.lsp_ui.clearCompletion();
        return;
    }

    const max_height = 10;
    const visible_count = @min(items.len, max_height);
    var row = rel_row + 4;
    if (row + visible_count >= editor.height - 1) {
        row = (rel_row + 3) -| visible_count;
    }
    var scroll_top: usize = 0;
    if (editor.state.lsp_ui.completion_selected >= max_height) {
        scroll_top = editor.state.lsp_ui.completion_selected - max_height + 1;
    }

    for (0..visible_count) |i| {
        const item_idx = scroll_top + i;
        if (item_idx >= items.len) break;
        const item = completionItemObject(items[item_idx]) orelse continue;
        const label = completionItemString(item, "label") orelse continue;
        const selected = item_idx == editor.state.lsp_ui.completion_selected;
        const style: render_mod.RenderStyle = if (selected) .completion_selected else .completion;
        const render_row = row + i;
        for (0..@min(@as(usize, 42), editor.width -| col)) |offset| {
            editor.renderer.screen.set(render_row, col + offset, ' ', style);
        }
        const kind_str = completionKindLabel(item);
        var line_buf: [64]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buf, " {s: <6} | {s}", .{ kind_str, label[0..@min(label.len, 30)] }) catch "";
        editor.renderer.screen.writeText(render_row, col, line, style);
        if (selected) {
            if (item.get("detail")) |d| {
                if (d == .string) {
                    const detail_col = col + 42;
                    if (detail_col < editor.width) {
                        const detail = d.string;
                        editor.renderer.screen.writeText(render_row, detail_col, detail[0..@min(detail.len, 40)], .completion_detail);
                    }
                }
            }
        }
    }
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
