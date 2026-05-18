const viewport_mod = @import("../navigation/viewport.zig");
const terminal_panel_mod = @import("../terminal_panel.zig");
const render_mod = @import("virtual_screen.zig");

const horizontal_line = "─";

pub const TerminalCursorScreenPosition = struct {
    row: usize,
    col: usize,
};

pub fn terminalCursorScreenPosition(editor: anytype) TerminalCursorScreenPosition {
    const panel_height = viewport_mod.terminalPanelHeight(editor);
    if (panel_height <= 1 or editor.height == 0 or editor.width == 0) return .{ .row = editor.height, .col = editor.width };
    const body_height = panel_height - 1;
    editor.terminal_panel.clampScroll(body_height);
    const total_lines = editor.terminal_panel.renderLineCount();
    const end = total_lines -| @min(editor.terminal_panel.scroll_offset, total_lines);
    const shown = @min(body_height, end);
    const first = end - shown;
    const cursor_index = editor.terminal_panel.cursorRenderIndex();
    if (cursor_index < first or cursor_index >= first + shown) return .{ .row = editor.height, .col = editor.width };

    const row = editor.height - panel_height + 2 + (cursor_index - first);
    const col = @min(editor.terminal_panel.cursor_col + 1, editor.width);
    return .{ .row = row, .col = col };
}

pub fn terminalCellStyle(cell: terminal_panel_mod.TerminalCell) render_mod.RenderStyle {
    if (cell.style.fg) |fg| {
        return switch (fg) {
            .black => .terminal_black,
            .red => if (cell.style.bold) .terminal_bright_red else .terminal_red,
            .green => if (cell.style.bold) .terminal_bright_green else .terminal_green,
            .yellow => if (cell.style.bold) .terminal_bright_yellow else .terminal_yellow,
            .blue => if (cell.style.bold) .terminal_bright_blue else .terminal_blue,
            .magenta => if (cell.style.bold) .terminal_bright_magenta else .terminal_magenta,
            .cyan => if (cell.style.bold) .terminal_bright_cyan else .terminal_cyan,
            .white => if (cell.style.bold) .terminal_bright_white else .terminal_white,
            .bright_black => .terminal_bright_black,
            .bright_red => .terminal_bright_red,
            .bright_green => .terminal_bright_green,
            .bright_yellow => .terminal_bright_yellow,
            .bright_blue => .terminal_bright_blue,
            .bright_magenta => .terminal_bright_magenta,
            .bright_cyan => .terminal_bright_cyan,
            .bright_white => .terminal_bright_white,
        };
    }
    return if (cell.style.bold) .terminal_bright_white else .terminal_bg;
}

pub fn renderVirtualTerminalPanel(editor: anytype) void {
    const panel_height = viewport_mod.terminalPanelHeight(editor);
    if (panel_height == 0 or editor.width == 0) return;

    const start_row = editor.height - panel_height;
    for (start_row..editor.height) |row| {
        editor.renderer.screen.fillRow(row, ' ', .terminal_bg);
    }

    editor.renderer.screen.fillRowGlyph(start_row, horizontal_line, .terminal_border);
    const title = if (editor.terminal_panel.focused) " Terminal [focused] " else " Terminal ";
    const title_style: render_mod.RenderStyle = if (editor.terminal_panel.focused) .terminal_focus else .terminal_title;
    if (editor.width > 2) {
        editor.renderer.screen.writeText(start_row, 1, title[0..@min(title.len, editor.width - 1)], title_style);
    }

    const body_height = panel_height -| 1;
    if (body_height == 0) return;

    editor.terminal_panel.resizePty(editor.width, body_height);
    editor.terminal_panel.clampScroll(body_height);
    const total_lines = editor.terminal_panel.renderLineCount();
    const end = total_lines -| @min(editor.terminal_panel.scroll_offset, total_lines);
    const shown = @min(body_height, end);
    const first = end - shown;
    for (0..shown) |offset| {
        const row = start_row + 1 + offset;
        const line = editor.terminal_panel.renderLineAt(first + offset) orelse continue;
        const max_cols = editor.width;
        for (line.cells.items[0..@min(line.cells.items.len, max_cols)], 0..) |cell, col| {
            editor.renderer.screen.set(row, col, cell.ch, terminalCellStyle(cell));
        }
        if (editor.terminal_panel.focused and first + offset == editor.terminal_panel.cursorRenderIndex()) {
            const cursor_col = @min(editor.terminal_panel.cursor_col, max_cols -| 1);
            const ch = if (cursor_col < line.cells.items.len) line.cells.items[cursor_col].ch else ' ';
            editor.renderer.screen.set(row, cursor_col, ch, .terminal_cursor);
        }
    }
}
