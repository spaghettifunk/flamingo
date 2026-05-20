const std = @import("std");
const comments = @import("../comments.zig");
const viewport_mod = @import("../navigation/viewport.zig");
const popup = @import("popup.zig");
const render_mod = @import("virtual_screen.zig");

pub fn renderVirtualCommentsPanel(editor: anytype) void {
    if (!editor.state.comments_panel.visible or editor.width == 0 or editor.height < 6) return;
    const width = viewport_mod.todoPanelWidth(editor);
    if (width == 0 or width >= editor.width) return;

    const status_row = viewport_mod.statusRowIndex(editor);
    if (status_row < 6) return;
    const col = editor.width - width;
    const screen = &editor.renderer.screen;
    const geom = popup.FilesystemPickerGeometry{ .row = 0, .col = col, .width = width, .height = status_row };
    const bottom_row = geom.row + geom.height - 1;
    const inner_end = col + width - 1;
    popup.drawPickerTop(screen, geom, " Comments ", .command_popup_border);
    fillPanelRows(screen, geom);

    var row: usize = 1;
    var write_col = col + 2;
    popup.writeVirtualTruncatedCells(screen, row, &write_col, inner_end, "Comments", .command_popup_prompt, false);
    var count_buf: [48]u8 = undefined;
    const count_text = std.fmt.bufPrint(&count_buf, "{d} threads", .{editor.state.comments_panel.store.threads.items.len}) catch "";
    writeRight(screen, 0, col, width, count_text, .explorer_dim);

    row += 1;
    drawSeparator(screen, row, col, width);
    row += 1;

    if (activeFileWarning(editor)) |warning| {
        writeLine(screen, row, col, width, warning, .popup_error, false, editor.state.comments_panel.focused);
        row += 1;
        drawSeparator(screen, row, col, width);
        row += 1;
    }

    const footer_rows = footerLineCount(width);
    if (status_row <= row + footer_rows + 3) return;
    const footer_start = bottom_row - footer_rows;
    const footer_separator_row = footer_start - 1;
    const body_rows = footer_separator_row -| row;

    editor.state.comments_panel.adjustScroll(body_rows);
    if (editor.state.comments_panel.load_error) |message| {
        writeLine(screen, row, col, width, message, .popup_error, false, editor.state.comments_panel.focused);
    } else if (editor.state.comments_panel.totalRows() == 0) {
        writeLine(screen, row, col, width, "No comments yet.", .explorer_dim, false, editor.state.comments_panel.focused);
        if (row + 1 < footer_start) {
            writeLine(screen, row + 1, col, width, "Select text and run :comment.", .explorer_dim, false, editor.state.comments_panel.focused);
        }
    } else {
        renderRows(editor, row, col, width, body_rows);
    }

    drawSeparator(screen, footer_separator_row, col, width);
    writeFooter(screen, footer_start, col, width, footer_rows);
    popup.drawPickerBottom(screen, bottom_row, col, width, .command_popup_border);
}

fn activeFileWarning(editor: anytype) ?[]const u8 {
    const tab = editor.currentTab() orelse return null;
    const filename = tab.buf.filename orelse return null;
    if (comments.isSupportedFilePath(filename)) return null;
    return comments.unsupported_file_message;
}

fn renderRows(editor: anytype, start_row: usize, col: usize, width: usize, body_rows: usize) void {
    const screen = &editor.renderer.screen;
    var flat_row: usize = 0;
    var rendered: usize = 0;
    for (editor.state.comments_panel.store.threads.items, 0..) |thread, thread_index| {
        if (flat_row >= editor.state.comments_panel.scroll_offset and rendered < body_rows) {
            renderThreadHeader(
                screen,
                start_row + rendered,
                col,
                width,
                thread,
                flat_row == editor.state.comments_panel.selected_row,
                editor.state.comments_panel.focused,
            );
            rendered += 1;
        }
        flat_row += 1;
        for (thread.comments.items, 0..) |message, message_index| {
            if (flat_row >= editor.state.comments_panel.scroll_offset and rendered < body_rows) {
                renderMessageRow(
                    screen,
                    start_row + rendered,
                    col,
                    width,
                    message,
                    flat_row == editor.state.comments_panel.selected_row,
                    editor.state.comments_panel.focused,
                    message_index > 0,
                );
                rendered += 1;
            }
            flat_row += 1;
        }
        _ = thread_index;
        if (rendered >= body_rows) break;
    }
}

fn renderThreadHeader(
    screen: *render_mod.VirtualScreen,
    row: usize,
    col: usize,
    width: usize,
    thread: comments.CommentThread,
    selected: bool,
    focused: bool,
) void {
    const row_style: render_mod.RenderStyle = if (selected) if (focused) .explorer_selected_focus else .explorer_selected else .command_popup;
    popup.drawPickerRow(screen, row, col, width, .command_popup_border, row_style);
    var write_col = col + 2;
    var loc_buf: [160]u8 = undefined;
    const loc = std.fmt.bufPrint(&loc_buf, "{s}:{d}", .{ thread.file_path, thread.anchor.start_line }) catch thread.file_path;
    popup.writeVirtualTruncatedCells(screen, row, &write_col, col + width - 1, loc, .command_popup_prompt, true);
    if (thread.stale) {
        popup.writeVirtualTruncatedCells(screen, row, &write_col, col + width - 1, " [stale]", .popup_error, false);
    }
    if (thread.comments.items.len > 1) {
        var replies_buf: [32]u8 = undefined;
        const replies = std.fmt.bufPrint(&replies_buf, " {d} replies", .{thread.comments.items.len - 1}) catch "";
        writeRight(screen, row, col, width, replies, .explorer_dim);
    }
}

fn renderMessageRow(
    screen: *render_mod.VirtualScreen,
    row: usize,
    col: usize,
    width: usize,
    message: comments.CommentMessage,
    selected: bool,
    focused: bool,
    is_reply: bool,
) void {
    const row_style: render_mod.RenderStyle = if (selected) if (focused) .explorer_selected_focus else .explorer_selected else .command_popup;
    popup.drawPickerRow(screen, row, col, width, .command_popup_border, row_style);
    var write_col = col + 2;
    if (is_reply) {
        popup.writeVirtualTruncatedCells(screen, row, &write_col, col + width - 1, "reply ", .explorer_dim, false);
    }
    popup.writeVirtualTruncatedCells(screen, row, &write_col, col + width - 1, message.author.name, .explorer_header, false);
    popup.writeVirtualTruncatedCells(screen, row, &write_col, col + width - 1, ": ", row_style, false);
    popup.writeVirtualTruncatedCells(screen, row, &write_col, col + width - 1, message.body, row_style, false);
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

fn writeLine(
    screen: *render_mod.VirtualScreen,
    row: usize,
    col: usize,
    width: usize,
    text: []const u8,
    style: render_mod.RenderStyle,
    selected: bool,
    focused: bool,
) void {
    const fill_style: render_mod.RenderStyle = if (selected) if (focused) .explorer_selected_focus else .explorer_selected else .command_popup;
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
    "r reply",
    "e edit",
    "d delete",
    "n new",
    "R reload",
    "enter jump",
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
