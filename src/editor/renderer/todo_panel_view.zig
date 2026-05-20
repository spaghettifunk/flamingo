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
    if (status_row < 7) return;
    const col = editor.width - width;
    const screen = &editor.renderer.screen;
    const geom = popup.FilesystemPickerGeometry{ .row = 0, .col = col, .width = width, .height = status_row };
    const bottom_row = geom.row + geom.height - 1;
    const inner_end = col + width - 1;
    popup.drawPickerTop(screen, geom, " TODOs ", .command_popup_border);
    fillPanelRows(screen, geom);

    var row: usize = 1;
    var write_col = col + 2;
    popup.writeVirtualTruncatedCells(screen, row, &write_col, inner_end, "TODOs", .command_popup_prompt, false);
    var count_buf: [48]u8 = undefined;
    const count_text = std.fmt.bufPrint(&count_buf, "{d} code  {d} user", .{
        editor.state.todo_panel.code_items.items.len,
        editor.state.todo_panel.manual_items.items.len,
    }) catch "";
    writeRight(screen, 0, col, width, count_text, .explorer_dim);

    row += 1;
    drawSeparator(screen, row, col, width);
    row += 1;

    writeSection(screen, row, col, width, "Code TODOs", editor.state.todo_panel.code_items.items.len);
    row += 1;

    const footer_rows = footerLineCount(width);
    if (status_row <= row + footer_rows + 4) return;
    const footer_start = bottom_row - footer_rows;
    const footer_separator_row = footer_start - 1;
    const manual_row = footer_separator_row - 1;
    const manual_separator_row = manual_row - 1;
    const body_rows = manual_separator_row -| row;
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

    drawSeparator(screen, manual_separator_row, col, width);
    writeSection(screen, manual_row, col, width, "Manual TODOs", editor.state.todo_panel.manual_items.items.len);
    if (!editor.state.workspace.active) {
        writeRight(screen, manual_row, col, width, "workspace required", .popup_error);
    }

    drawSeparator(screen, footer_separator_row, col, width);
    writeFooter(screen, footer_start, col, width, footer_rows);
    popup.drawPickerBottom(screen, bottom_row, col, width, .command_popup_border);
}

fn drawSeparator(screen: *render_mod.VirtualScreen, row: usize, col: usize, width: usize) void {
    if (width == 0) return;
    popup.drawPickerSeparator(screen, row, col, width, .command_popup_border);
}

fn fillPanelRows(screen: *render_mod.VirtualScreen, geom: popup.FilesystemPickerGeometry) void {
    const bottom_row = geom.row + geom.height - 1;
    var row = geom.row + 1;
    while (row < bottom_row) : (row += 1) {
        popup.drawPickerRow(screen, row, geom.col, geom.width, .command_popup_border, .command_popup);
    }
}

fn writeSection(screen: *render_mod.VirtualScreen, row: usize, col: usize, width: usize, title: []const u8, count: usize) void {
    writeLine(screen, row, col, width, title, .command_popup_prompt, false);
    var buf: [24]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d}", .{count}) catch "";
    writeRight(screen, row, col, width, text, .explorer_dim);
}

fn writeLine(screen: *render_mod.VirtualScreen, row: usize, col: usize, width: usize, text: []const u8, style: render_mod.RenderStyle, selected: bool) void {
    const fill_style: render_mod.RenderStyle = if (selected) .explorer_selected_focus else .command_popup;
    popup.drawPickerRow(screen, row, col, width, .command_popup_border, fill_style);
    var write_col = col + 2;
    popup.writeVirtualTruncatedCells(screen, row, &write_col, col + width - 1, text, style, false);
}

fn writeRight(screen: *render_mod.VirtualScreen, row: usize, col: usize, width: usize, text: []const u8, style: render_mod.RenderStyle) void {
    const text_cells = render_mod.displayCellCount(text);
    if (text_cells + 1 >= width) return;
    screen.writeText(row, col + width - text_cells - 1, text, style);
}

const footer_commands = [_][]const u8{
    "r refresh",
    "n new",
    "e edit",
    "d delete",
    "x done",
    "o open",
    "q close",
};

fn footerLineCount(width: usize) usize {
    const inner_width = width -| 2;
    if (inner_width == 0) return footer_commands.len;

    var rows: usize = 1;
    var line_cells: usize = 0;
    for (footer_commands) |command| {
        const command_cells = render_mod.displayCellCount(command);
        const separator_cells: usize = if (line_cells == 0) 0 else 2;
        if (line_cells > 0 and line_cells + separator_cells + command_cells > inner_width) {
            rows += 1;
            line_cells = command_cells;
        } else {
            line_cells += separator_cells + command_cells;
        }
    }
    return rows;
}

fn writeFooter(screen: *render_mod.VirtualScreen, start_row: usize, col: usize, width: usize, max_rows: usize) void {
    const inner_end = col + width -| 1;
    var row = start_row;
    var write_col = col + 2;

    for (0..max_rows) |offset| {
        popup.drawPickerRow(screen, start_row + offset, col, width, .command_popup_border, .popup_footer);
    }

    for (footer_commands) |command| {
        const command_cells = render_mod.displayCellCount(command);
        const separator: []const u8 = if (write_col == col + 2) "" else "  ";
        const separator_cells = render_mod.displayCellCount(separator);
        if (write_col + separator_cells + command_cells > inner_end and row + 1 < start_row + max_rows) {
            row += 1;
            write_col = col + 2;
        }
        if (separator.len > 0 and write_col + separator_cells <= inner_end) {
            screen.writeText(row, write_col, separator, .popup_footer);
            write_col += separator_cells;
        }
        if (write_col + command_cells <= inner_end) {
            screen.writeText(row, write_col, command, .popup_footer);
            write_col += command_cells;
        }
    }
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
    const row_style: render_mod.RenderStyle = if (selected) if (focused) .explorer_selected_focus else .explorer_selected else .command_popup;
    popup.drawPickerRow(screen, row, col, width, .command_popup_border, row_style);
    var write_col = col + 2;
    var loc_buf: [160]u8 = undefined;
    const loc = std.fmt.bufPrint(&loc_buf, "{s}:{d}", .{ item.display_path, item.line }) catch item.display_path;
    popup.writeVirtualTruncatedCells(screen, row, &write_col, col + width - 1, "[code] ", row_style, false);
    popup.writeVirtualTruncatedCells(screen, row, &write_col, col + width - 1, item.tag.label(), .command_popup_prompt, false);
    popup.writeVirtualTruncatedCells(screen, row, &write_col, col + width - 1, " ", row_style, false);
    popup.writeVirtualTruncatedCells(screen, row, &write_col, col + width - 1, loc, .explorer_dim, true);
    popup.writeVirtualTruncatedCells(screen, row, &write_col, col + width - 1, " ", row_style, false);
    popup.writeVirtualTruncatedCells(screen, row, &write_col, col + width - 1, item.text, row_style, false);
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
    const row_style: render_mod.RenderStyle = if (selected) if (focused) .explorer_selected_focus else .explorer_selected else .command_popup;
    const mark = if (item.status == .done) "[x] " else "[ ] ";
    popup.drawPickerRow(screen, row, col, width, .command_popup_border, row_style);
    var write_col = col + 2;
    popup.writeVirtualTruncatedCells(screen, row, &write_col, col + width - 1, "[user] ", row_style, false);
    popup.writeVirtualTruncatedCells(screen, row, &write_col, col + width - 1, mark, .command_popup_prompt, false);
    popup.writeVirtualTruncatedCells(screen, row, &write_col, col + width - 1, item.title, row_style, false);
}
