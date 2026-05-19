const std = @import("std");
const todos = @import("../todos.zig");
const viewport_mod = @import("../navigation/viewport.zig");
const popup = @import("popup.zig");
const render_mod = @import("virtual_screen.zig");

pub fn renderVirtualTodoPanel(editor: anytype) void {
    if (!editor.state.todo_panel.visible or editor.width == 0 or editor.height < 6) return;
    const width = viewport_mod.todoPanelWidth(editor);
    if (width == 0 or width >= editor.width) return;

    const status_row = viewport_mod.statusRowIndex(editor);
    if (status_row < 5) return;
    const col = editor.width - width;
    const divider_col = col -| 1;
    for (0..status_row) |row| {
        editor.renderer.screen.writeText(row, divider_col, "│", .dim);
    }

    const screen = &editor.renderer.screen;
    const right = col + width;
    for (0..status_row) |row| {
        for (col..right) |x| screen.set(row, x, ' ', .explorer_bg);
    }

    var write_col = col + 1;
    popup.writeVirtualTruncatedCells(screen, 0, &write_col, right, "TODOs", .explorer_header, false);
    var count_buf: [48]u8 = undefined;
    const count_text = std.fmt.bufPrint(&count_buf, "{d} code  {d} user", .{
        editor.state.todo_panel.code_items.items.len,
        editor.state.todo_panel.manual_items.items.len,
    }) catch "";
    writeRight(screen, 0, col, width, count_text, .explorer_dim);

    drawSeparator(screen, 1, col, width);

    var row: usize = 2;
    writeSection(screen, row, col, width, "Code TODOs", editor.state.todo_panel.code_items.items.len);
    row += 1;

    const body_rows = status_row -| 5;
    editor.state.todo_panel.adjustScroll(body_rows);
    const total = editor.state.todo_panel.totalItems();
    if (total == 0) {
        writeLine(screen, row, col, width, "No TODOs found.", .explorer_dim, false);
        if (editor.state.workspace.active) {
            writeLine(screen, row + 1, col, width, "Press n to create a manual TODO.", .explorer_dim, false);
        } else {
            writeLine(screen, row + 1, col, width, "Manual TODOs require a workspace.", .explorer_dim, false);
        }
    } else {
        var item_index = editor.state.todo_panel.scroll_offset;
        var rendered: usize = 0;
        while (rendered < body_rows and item_index < total) : ({
            rendered += 1;
            item_index += 1;
        }) {
            const selected = item_index == editor.state.todo_panel.selected_index;
            if (item_index < editor.state.todo_panel.code_items.items.len) {
                renderCodeItem(screen, row + rendered, col, width, editor.state.todo_panel.code_items.items[item_index], selected, editor.state.todo_panel.focused);
            } else {
                const manual_index = item_index - editor.state.todo_panel.code_items.items.len;
                renderManualItem(screen, row + rendered, col, width, editor.state.todo_panel.manual_items.items[manual_index], selected, editor.state.todo_panel.focused);
            }
        }
    }

    const manual_row = status_row - 2;
    drawSeparator(screen, manual_row - 1, col, width);
    writeSection(screen, manual_row, col, width, "Manual TODOs", editor.state.todo_panel.manual_items.items.len);
    if (!editor.state.workspace.active) {
        writeRight(screen, manual_row, col, width, "workspace required", .popup_error);
    }

    const footer = "r refresh  n new  e edit  x done  o open  q close";
    writeLine(screen, status_row - 1, col, width, footer, .popup_footer, false);
}

fn drawSeparator(screen: *render_mod.VirtualScreen, row: usize, col: usize, width: usize) void {
    if (width == 0) return;
    for (0..width) |offset| screen.setGlyph(row, col + offset, "─", .command_popup_border);
}

fn writeSection(screen: *render_mod.VirtualScreen, row: usize, col: usize, width: usize, title: []const u8, count: usize) void {
    writeLine(screen, row, col, width, title, .command_popup_prompt, false);
    var buf: [24]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d}", .{count}) catch "";
    writeRight(screen, row, col, width, text, .explorer_dim);
}

fn writeLine(screen: *render_mod.VirtualScreen, row: usize, col: usize, width: usize, text: []const u8, style: render_mod.RenderStyle, selected: bool) void {
    const fill_style: render_mod.RenderStyle = if (selected) .explorer_selected_focus else .explorer_bg;
    for (0..width) |offset| screen.set(row, col + offset, ' ', fill_style);
    var write_col = col + 1;
    popup.writeVirtualTruncatedCells(screen, row, &write_col, col + width, text, style, false);
}

fn writeRight(screen: *render_mod.VirtualScreen, row: usize, col: usize, width: usize, text: []const u8, style: render_mod.RenderStyle) void {
    const text_cells = render_mod.displayCellCount(text);
    if (text_cells + 1 >= width) return;
    screen.writeText(row, col + width - text_cells - 1, text, style);
}

fn renderCodeItem(
    screen: *render_mod.VirtualScreen,
    row: usize,
    col: usize,
    width: usize,
    item: todos.CodeTodo,
    selected: bool,
    focused: bool,
) void {
    const row_style: render_mod.RenderStyle = if (selected) if (focused) .explorer_selected_focus else .explorer_selected else .explorer_bg;
    for (0..width) |offset| screen.set(row, col + offset, ' ', row_style);
    var write_col = col + 1;
    var loc_buf: [160]u8 = undefined;
    const loc = std.fmt.bufPrint(&loc_buf, "{s}:{d}", .{ item.display_path, item.line }) catch item.display_path;
    popup.writeVirtualTruncatedCells(screen, row, &write_col, col + width, "[code] ", row_style, false);
    popup.writeVirtualTruncatedCells(screen, row, &write_col, col + width, item.tag.label(), .command_popup_prompt, false);
    popup.writeVirtualTruncatedCells(screen, row, &write_col, col + width, " ", row_style, false);
    popup.writeVirtualTruncatedCells(screen, row, &write_col, col + width, loc, .explorer_dim, true);
    popup.writeVirtualTruncatedCells(screen, row, &write_col, col + width, " ", row_style, false);
    popup.writeVirtualTruncatedCells(screen, row, &write_col, col + width, item.text, row_style, false);
}

fn renderManualItem(
    screen: *render_mod.VirtualScreen,
    row: usize,
    col: usize,
    width: usize,
    item: todos.ManualTodo,
    selected: bool,
    focused: bool,
) void {
    const row_style: render_mod.RenderStyle = if (selected) if (focused) .explorer_selected_focus else .explorer_selected else .explorer_bg;
    const mark = if (item.status == .done) "[x] " else "[ ] ";
    for (0..width) |offset| screen.set(row, col + offset, ' ', row_style);
    var write_col = col + 1;
    popup.writeVirtualTruncatedCells(screen, row, &write_col, col + width, "[user] ", row_style, false);
    popup.writeVirtualTruncatedCells(screen, row, &write_col, col + width, mark, .command_popup_prompt, false);
    popup.writeVirtualTruncatedCells(screen, row, &write_col, col + width, item.title, row_style, false);
}
