const render_mod = @import("virtual_screen.zig");

const horizontal_line = "─";

pub const CommandPopupGeometry = struct {
    row: usize,
    col: usize,
    width: usize,
    suggestion_count: usize,
};

pub const FilesystemPickerGeometry = struct {
    row: usize,
    col: usize,
    width: usize,
    height: usize,
};

pub fn popupGeometry(
    height: usize,
    viewport_start_col: usize,
    viewport_width: usize,
    visible: bool,
    item_count: usize,
    show_items: bool,
    max_visible_items: usize,
) ?CommandPopupGeometry {
    if (!visible or height < 6) return null;
    if (viewport_width < 16) return null;

    const max_width = viewport_width -| 2;
    const desired_width = @max(@as(usize, 40), (viewport_width * 9) / 10);
    const popup_width = @min(max_width, desired_width);
    if (popup_width < 16) return null;

    const row: usize = 2;
    const available_suggestions = height - row - 5;
    const suggestion_count = if (show_items)
        @min(item_count, @min(max_visible_items, available_suggestions))
    else
        0;
    const viewport_col = viewport_start_col -| 1;
    const col = viewport_col + (viewport_width - popup_width) / 2;
    return .{
        .row = row,
        .col = col,
        .width = popup_width,
        .suggestion_count = suggestion_count,
    };
}

pub fn drawVirtualPopupTop(screen: *render_mod.VirtualScreen, geom: CommandPopupGeometry, title: []const u8, style: render_mod.RenderStyle) void {
    screen.setGlyph(geom.row, geom.col, "╭", style);
    for (1..geom.width - 1) |i| screen.setGlyph(geom.row, geom.col + i, horizontal_line, style);
    screen.setGlyph(geom.row, geom.col + geom.width - 1, "╮", style);
    if (render_mod.displayCellCount(title) + 4 < geom.width) {
        screen.writeText(geom.row, geom.col + 2, title, style);
    }
}

pub fn drawVirtualPopupRow(screen: *render_mod.VirtualScreen, row: usize, col: usize, width: usize, border_style: render_mod.RenderStyle, fill_style: render_mod.RenderStyle) void {
    screen.setGlyph(row, col, "│", border_style);
    screen.setGlyph(row, col + width - 1, "│", border_style);
    for (1..width - 1) |i| screen.set(row, col + i, ' ', fill_style);
}

pub fn drawVirtualPopupSeparator(screen: *render_mod.VirtualScreen, row: usize, col: usize, width: usize, style: render_mod.RenderStyle) void {
    screen.setGlyph(row, col, "├", style);
    for (1..width - 1) |i| screen.setGlyph(row, col + i, horizontal_line, style);
    screen.setGlyph(row, col + width - 1, "┤", style);
}

pub fn drawVirtualPopupBottom(screen: *render_mod.VirtualScreen, row: usize, col: usize, width: usize, style: render_mod.RenderStyle) void {
    screen.setGlyph(row, col, "╰", style);
    for (1..width - 1) |i| screen.setGlyph(row, col + i, horizontal_line, style);
    screen.setGlyph(row, col + width - 1, "╯", style);
}

pub fn drawPickerTop(screen: *render_mod.VirtualScreen, geom: FilesystemPickerGeometry, title: []const u8, style: render_mod.RenderStyle) void {
    screen.setGlyph(geom.row, geom.col, "╭", style);
    for (1..geom.width - 1) |i| screen.setGlyph(geom.row, geom.col + i, horizontal_line, style);
    screen.setGlyph(geom.row, geom.col + geom.width - 1, "╮", style);
    if (render_mod.displayCellCount(title) + 4 < geom.width) {
        screen.writeText(geom.row, geom.col + 2, title, style);
    }
}

pub fn drawPickerSeparator(screen: *render_mod.VirtualScreen, row: usize, col: usize, width: usize, style: render_mod.RenderStyle) void {
    screen.setGlyph(row, col, "├", style);
    for (1..width - 1) |i| screen.setGlyph(row, col + i, horizontal_line, style);
    screen.setGlyph(row, col + width - 1, "┤", style);
}

pub fn drawPickerRow(screen: *render_mod.VirtualScreen, row: usize, col: usize, width: usize, border_style: render_mod.RenderStyle, fill_style: render_mod.RenderStyle) void {
    screen.setGlyph(row, col, "│", border_style);
    screen.setGlyph(row, col + width - 1, "│", border_style);
    for (1..width - 1) |i| screen.set(row, col + i, ' ', fill_style);
}

pub fn drawPickerBottom(screen: *render_mod.VirtualScreen, row: usize, col: usize, width: usize, style: render_mod.RenderStyle) void {
    screen.setGlyph(row, col, "╰", style);
    for (1..width - 1) |i| screen.setGlyph(row, col + i, horizontal_line, style);
    screen.setGlyph(row, col + width - 1, "╯", style);
}

pub fn byteOffsetAfterCells(text: []const u8, cell_count: usize) usize {
    var i: usize = 0;
    var cells: usize = 0;
    while (i < text.len and cells < cell_count) : (cells += 1) {
        i += @min(render_mod.utf8CellLen(text[i]), text.len - i);
    }
    return i;
}

pub fn writeVirtualCellsLimited(screen: *render_mod.VirtualScreen, row: usize, col: *usize, end_col: usize, text: []const u8, max_cells: usize, style: render_mod.RenderStyle) usize {
    if (col.* >= end_col or max_cells == 0) return 0;
    const end = byteOffsetAfterCells(text, max_cells);
    const shown = text[0..end];
    screen.writeText(row, col.*, shown, style);
    const written = render_mod.displayCellCount(shown);
    col.* += written;
    return written;
}

pub fn writeVirtualTruncated(screen: *render_mod.VirtualScreen, row: usize, col: *usize, end_col: usize, text: []const u8, style: render_mod.RenderStyle) void {
    if (col.* >= end_col) return;
    const remaining = end_col - col.*;
    const shown = text[0..@min(text.len, remaining)];
    screen.writeText(row, col.*, shown, style);
    col.* += shown.len;
}

pub fn writeVirtualTruncatedCells(screen: *render_mod.VirtualScreen, row: usize, col: *usize, end_col: usize, text: []const u8, style: render_mod.RenderStyle, truncate_left: bool) void {
    if (col.* >= end_col) return;
    const remaining = end_col - col.*;
    const text_cells = render_mod.displayCellCount(text);
    if (text_cells <= remaining) {
        screen.writeText(row, col.*, text, style);
        col.* += text_cells;
        return;
    }

    if (remaining <= 3) {
        _ = writeVirtualCellsLimited(screen, row, col, end_col, "...", remaining, style);
        return;
    }

    if (truncate_left) {
        _ = writeVirtualCellsLimited(screen, row, col, end_col, "...", 3, style);
        const tail_cells = remaining - 3;
        const skip_cells = text_cells - tail_cells;
        const start = byteOffsetAfterCells(text, skip_cells);
        _ = writeVirtualCellsLimited(screen, row, col, end_col, text[start..], tail_cells, style);
    } else {
        const head_cells = remaining - 3;
        _ = writeVirtualCellsLimited(screen, row, col, end_col, text, head_cells, style);
        _ = writeVirtualCellsLimited(screen, row, col, end_col, "...", 3, style);
    }
}
