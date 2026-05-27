const std = @import("std");
const workspace_diff = @import("../git/workspace_diff.zig");
const viewport_mod = @import("../navigation/viewport.zig");
const popup = @import("popup.zig");
const render_mod = @import("virtual_screen.zig");

const title = " Git Diff ";
const footer_text = "Up/Down move  PgUp/PgDn scroll  Enter open  r refresh  q/Esc close";

pub fn renderVirtualGitDiffPanel(editor: anytype) void {
    if (!editor.state.git_diff_panel.visible) return;
    const geom = gitDiffPanelGeometry(editor) orelse return;
    const screen = &editor.renderer.screen;
    popup.drawPickerTop(screen, geom, title, .command_popup_border);

    if (geom.width < 48 or geom.height < 8) {
        renderMinimal(editor, geom);
        return;
    }

    fillRows(screen, geom, .command_popup);
    renderHeader(editor, geom);

    const body_start = geom.row + 3;
    const bottom_row = geom.row + geom.height - 1;
    const footer_row = bottom_row - 1;
    const footer_sep_row = footer_row - 1;
    const body_rows = footer_sep_row -| body_start;

    if (body_rows > 0) renderBody(editor, geom, body_start, body_rows);

    popup.drawPickerSeparator(screen, footer_sep_row, geom.col, geom.width, .command_popup_border);
    popup.drawPickerRow(screen, footer_row, geom.col, geom.width, .command_popup_border, .popup_footer);
    var footer_col = geom.col + 2;
    popup.writeVirtualTruncatedCells(screen, footer_row, &footer_col, geom.col + geom.width - 1, footer_text, .popup_footer, false);
    popup.drawPickerBottom(screen, bottom_row, geom.col, geom.width, .command_popup_border);
}

pub fn gitDiffPanelGeometry(editor: anytype) ?popup.FilesystemPickerGeometry {
    if (!editor.state.git_diff_panel.visible or editor.width < 20 or editor.height < 5) return null;
    const status_row = viewport_mod.statusRowIndex(editor);
    if (status_row < 4) return null;

    const available_width = editor.width -| 2;
    if (available_width < 18) return null;
    const desired_width = @min(@as(usize, 132), @max(@as(usize, 56), (editor.width * 92) / 100));
    const panel_width = @min(available_width, desired_width);

    const available_height = status_row;
    const desired_height = @max(@as(usize, 8), (available_height * 88) / 100);
    const panel_height = @min(available_height, desired_height);
    if (panel_height < 5) return null;

    return .{
        .row = (available_height - panel_height) / 2,
        .col = (editor.width - panel_width) / 2,
        .width = panel_width,
        .height = panel_height,
    };
}

fn renderMinimal(editor: anytype, geom: popup.FilesystemPickerGeometry) void {
    const screen = &editor.renderer.screen;
    const bottom_row = geom.row + geom.height - 1;
    var row = geom.row + 1;
    while (row < bottom_row) : (row += 1) {
        popup.drawPickerRow(screen, row, geom.col, geom.width, .command_popup_border, .command_popup);
    }
    const message = editor.state.git_diff_panel.error_message orelse "Terminal too small for Git Diff";
    var col = geom.col + 2;
    popup.writeVirtualTruncatedCells(screen, geom.row + 1, &col, geom.col + geom.width - 1, message, .popup_error, false);
    popup.drawPickerBottom(screen, bottom_row, geom.col, geom.width, .command_popup_border);
}

fn fillRows(screen: *render_mod.VirtualScreen, geom: popup.FilesystemPickerGeometry, style: render_mod.RenderStyle) void {
    const bottom_row = geom.row + geom.height - 1;
    var row = geom.row + 1;
    while (row < bottom_row) : (row += 1) {
        popup.drawPickerRow(screen, row, geom.col, geom.width, .command_popup_border, style);
    }
}

fn renderHeader(editor: anytype, geom: popup.FilesystemPickerGeometry) void {
    const screen = &editor.renderer.screen;
    const row = geom.row + 1;
    const inner_end = geom.col + geom.width - 1;
    popup.drawPickerRow(screen, row, geom.col, geom.width, .command_popup_border, .command_popup);

    const repo = if (editor.state.git_diff_panel.repo_root) |root| std.fs.path.basename(root) else "-";
    var buf: [192]u8 = undefined;
    const header = std.fmt.bufPrint(&buf, "repo: {s}    files: {d}", .{
        repo,
        editor.state.git_diff_panel.fileCount(),
    }) catch "repo: -    files: 0";
    var col = geom.col + 2;
    popup.writeVirtualTruncatedCells(screen, row, &col, inner_end, header, .command_popup_prompt, false);
    if (editor.state.git_diff_panel.truncated) {
        popup.writeVirtualTruncatedCells(screen, row, &col, inner_end, "    truncated", .popup_error, false);
    }
    popup.drawPickerSeparator(screen, geom.row + 2, geom.col, geom.width, .command_popup_border);
}

fn renderBody(editor: anytype, geom: popup.FilesystemPickerGeometry, start_row: usize, body_rows: usize) void {
    const screen = &editor.renderer.screen;
    const panel = &editor.state.git_diff_panel;
    panel.adjustScroll(body_rows);

    for (0..body_rows) |offset| {
        const row_index = panel.scroll_offset + offset;
        const row = start_row + offset;
        if (row_index >= panel.rows.items.len) {
            popup.drawPickerRow(screen, row, geom.col, geom.width, .command_popup_border, .command_popup);
            continue;
        }
        const selected = row_index == panel.selected_index;
        renderRow(screen, row, geom, panel.rows.items[row_index], selected);
    }
}

fn renderRow(screen: *render_mod.VirtualScreen, row: usize, geom: popup.FilesystemPickerGeometry, item: workspace_diff.RenderRow, selected: bool) void {
    const fill_style: render_mod.RenderStyle = if (selected) .explorer_selected_focus else .command_popup;
    popup.drawPickerRow(screen, row, geom.col, geom.width, .command_popup_border, fill_style);

    switch (item.kind) {
        .separator => {
            var col = geom.col + 2;
            popup.writeVirtualTruncatedCells(screen, row, &col, geom.col + geom.width - 1, "────────────────────────────────────", .dim, false);
        },
        .message => writeText(screen, row, geom, item.text, if (selected) .explorer_selected_focus else .explorer_dim, 0),
        .truncation => writeText(screen, row, geom, item.text, .popup_error, 0),
        .summary => renderSummaryRow(screen, row, geom, item, selected),
        .file_header => writeText(screen, row, geom, item.text, if (selected) .git_graph_lane_blue_selected else .git_graph_lane_blue, 0),
        .hunk_header => writeText(screen, row, geom, item.text, if (selected) .explorer_selected_focus else .command_popup_prompt, 2),
        .metadata => writeText(screen, row, geom, item.text, if (selected) .explorer_selected_focus else .explorer_dim, 2),
        .diff_line => writeText(screen, row, geom, item.text, diffLineStyle(item.line_kind orelse .context, selected), 2),
    }
}

fn renderSummaryRow(screen: *render_mod.VirtualScreen, row: usize, geom: popup.FilesystemPickerGeometry, item: workspace_diff.RenderRow, selected: bool) void {
    var col = geom.col + 2;
    const end = geom.col + geom.width - 1;
    const kind = item.change_kind orelse .modified;
    popup.writeVirtualTruncatedCells(screen, row, &col, end, kind.label(), changeKindStyle(kind, selected), false);
    popup.writeVirtualTruncatedCells(screen, row, &col, end, " ", if (selected) .explorer_selected_focus else .command_popup, false);
    const path = if (item.text.len > 2) item.text[2..] else item.text;
    popup.writeVirtualTruncatedCells(screen, row, &col, end, path, if (selected) .explorer_selected_focus else .command_popup, true);
}

fn writeText(
    screen: *render_mod.VirtualScreen,
    row: usize,
    geom: popup.FilesystemPickerGeometry,
    text: []const u8,
    style: render_mod.RenderStyle,
    indent: usize,
) void {
    var col = geom.col + 2 + indent;
    popup.writeVirtualTruncatedCells(screen, row, &col, geom.col + geom.width - 1, text, style, false);
}

fn diffLineStyle(kind: workspace_diff.DiffLineKind, selected: bool) render_mod.RenderStyle {
    return switch (kind) {
        .added => if (selected) .git_diff_added_selected else .git_diff_added,
        .removed => if (selected) .git_diff_deleted_selected else .git_diff_deleted,
        .header => if (selected) .explorer_selected_focus else .command_popup_prompt,
        .metadata => if (selected) .explorer_selected_focus else .explorer_dim,
        .context => if (selected) .explorer_selected_focus else .command_popup,
    };
}

fn changeKindStyle(kind: workspace_diff.GitChangeKind, selected: bool) render_mod.RenderStyle {
    return switch (kind) {
        .added, .untracked => if (selected) .git_diff_added_selected else .git_diff_added,
        .deleted => if (selected) .git_diff_deleted_selected else .git_diff_deleted,
        .modified, .renamed => if (selected) .git_diff_modified_selected else .git_diff_modified,
    };
}

test "git diff panel geometry prefers review width" {
    const FakePanel = struct { visible: bool = true };
    const FakeState = struct { git_diff_panel: FakePanel = .{} };
    const FakeEditor = struct {
        width: usize = 120,
        height: usize = 40,
        terminal_panel: struct { visible: bool = false } = .{},
        state: FakeState = .{},
    };
    const editor = FakeEditor{};
    const geom = gitDiffPanelGeometry(editor).?;
    try std.testing.expect(geom.width >= 100);
}
