const std = @import("std");
const git_graph = @import("../git_graph.zig");
const viewport_mod = @import("../navigation/viewport.zig");
const popup = @import("popup.zig");
const render_mod = @import("virtual_screen.zig");

pub const IconMode = enum {
    nerd_font,
    ascii,
};

const title = " Git Graph ";
const footer_text = "Up/Down move  PgUp/PgDn scroll  Enter details  r refresh  q/Esc close";

pub fn renderVirtualGitGraphPanel(editor: anytype) void {
    renderVirtualGitGraphPanelWithIconMode(editor, .nerd_font);
}

pub fn renderVirtualGitGraphPanelWithIconMode(editor: anytype, _: IconMode) void {
    if (!editor.state.git_graph_panel.visible) return;
    const geom = gitGraphPanelGeometry(editor) orelse return;
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
    const detail_rows: usize = if (editor.state.git_graph_panel.show_details and editor.state.git_graph_panel.selectedCommit() != null) 7 else 0;
    const available_body_rows = footer_sep_row -| body_start;
    const body_rows = available_body_rows -| detail_rows;

    if (body_rows > 0) {
        renderBody(editor, geom, body_start, body_rows);
    }
    if (detail_rows > 0 and available_body_rows > detail_rows) {
        renderDetails(editor, geom, body_start + body_rows, detail_rows);
    }

    popup.drawPickerSeparator(screen, footer_sep_row, geom.col, geom.width, .command_popup_border);
    popup.drawPickerRow(screen, footer_row, geom.col, geom.width, .command_popup_border, .popup_footer);
    var footer_col = geom.col + 2;
    popup.writeVirtualTruncatedCells(screen, footer_row, &footer_col, geom.col + geom.width - 1, footer_text, .popup_footer, false);
    popup.drawPickerBottom(screen, bottom_row, geom.col, geom.width, .command_popup_border);
}

pub fn gitGraphPanelGeometry(editor: anytype) ?popup.FilesystemPickerGeometry {
    if (!editor.state.git_graph_panel.visible or editor.width < 20 or editor.height < 5) return null;
    const status_row = viewport_mod.statusRowIndex(editor);
    if (status_row < 4) return null;

    const available_width = editor.width -| 2;
    if (available_width < 18) return null;
    const desired_width = @min(@as(usize, 120), @max(@as(usize, 48), (editor.width * 90) / 100));
    const panel_width = @min(available_width, desired_width);

    const available_height = status_row;
    const desired_height = @max(@as(usize, 8), (available_height * 85) / 100);
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
    const message = editor.state.git_graph_panel.error_message orelse "Terminal too small for Git Graph";
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

    const repo = if (editor.state.git_graph_panel.repo_root) |root| std.fs.path.basename(root) else "-";
    const branch = gitGraphBranch(editor) orelse "-";
    var buf: [192]u8 = undefined;
    const repo_text = std.fmt.bufPrint(&buf, "repo: {s}    branch: ", .{repo}) catch "repo: -    branch: ";
    var col = geom.col + 2;
    popup.writeVirtualTruncatedCells(screen, row, &col, inner_end, repo_text, .command_popup_prompt, false);
    popup.writeVirtualTruncatedCells(screen, row, &col, inner_end, branch, if (std.mem.eql(u8, branch, "-")) .explorer_dim else .git_graph_lane_blue, false);
    const commits_text = std.fmt.bufPrint(&buf, "    commits: {d}", .{
        editor.state.git_graph_panel.commitCount(),
    }) catch "";
    popup.writeVirtualTruncatedCells(screen, row, &col, inner_end, commits_text, .command_popup_prompt, false);
    popup.drawPickerSeparator(screen, geom.row + 2, geom.col, geom.width, .command_popup_border);
}

fn gitGraphBranch(editor: anytype) ?[]const u8 {
    if (editor.state.git_graph_panel.current_branch) |branch| return branch;
    const panel_root = editor.state.git_graph_panel.repo_root orelse return null;
    const snapshot = editor.state.git_snapshot orelse return null;
    const snapshot_root = snapshot.root_path orelse return null;
    if (!std.mem.eql(u8, panel_root, snapshot_root)) return null;
    return snapshot.branch;
}

fn graphAreaWidth(width: usize) usize {
    if (width >= 96) return 48;
    if (width >= 76) return 40;
    return 26;
}

fn renderBody(editor: anytype, geom: popup.FilesystemPickerGeometry, start_row: usize, body_rows: usize) void {
    const screen = &editor.renderer.screen;
    const panel = &editor.state.git_graph_panel;
    panel.adjustScroll(body_rows);

    if (panel.error_message) |message| {
        writeMessageRow(screen, start_row, geom, message, .popup_error);
        return;
    }
    if (panel.rows.items.len == 0) {
        writeMessageRow(screen, start_row, geom, "No commits found.", .explorer_dim);
        return;
    }

    const graph_width = graphAreaWidth(geom.width);
    for (0..body_rows) |offset| {
        const row_index = panel.scroll_offset + offset;
        const row = start_row + offset;
        if (row_index >= panel.rows.items.len) {
            popup.drawPickerRow(screen, row, geom.col, geom.width, .command_popup_border, .command_popup);
            continue;
        }
        const selected = row_index == panel.selected_index;
        const row_style: render_mod.RenderStyle = if (selected) .explorer_selected_focus else .command_popup;
        popup.drawPickerRow(screen, row, geom.col, geom.width, .command_popup_border, row_style);
        switch (panel.rows.items[row_index]) {
            .commit => |commit| renderCommitRow(screen, row, geom, graph_width, commit, selected),
            .continuation => |continuation| renderGraphPrefix(screen, row, geom.col + 2, graph_width, continuation.graph_prefix, selected),
        }
    }
}

fn writeMessageRow(screen: *render_mod.VirtualScreen, row: usize, geom: popup.FilesystemPickerGeometry, message: []const u8, style: render_mod.RenderStyle) void {
    popup.drawPickerRow(screen, row, geom.col, geom.width, .command_popup_border, .command_popup);
    var col = geom.col + 2;
    popup.writeVirtualTruncatedCells(screen, row, &col, geom.col + geom.width - 1, message, style, false);
}

fn renderCommitRow(
    screen: *render_mod.VirtualScreen,
    row: usize,
    geom: popup.FilesystemPickerGeometry,
    graph_width: usize,
    commit: git_graph.GitCommitRow,
    selected: bool,
) void {
    const inner_end = geom.col + geom.width - 1;
    const graph_col = geom.col + 2;
    renderGraphPrefix(screen, row, graph_col, graph_width, commit.graph_prefix, selected);
    renderInlineGraphLabel(screen, row, graph_col, graph_width, commit, selected);

    var col = graph_col + graph_width + 1;
    popup.writeVirtualTruncatedCells(screen, row, &col, inner_end, commit.subject, rowStyle(selected), false);
}

fn renderInlineGraphLabel(
    screen: *render_mod.VirtualScreen,
    row: usize,
    graph_col: usize,
    graph_width: usize,
    commit: git_graph.GitCommitRow,
    selected: bool,
) void {
    const star_index = std.mem.lastIndexOfScalar(u8, commit.graph_prefix, '*') orelse return;
    const label_start = @min(graph_width, star_index * 2 + 2);
    if (label_start >= graph_width) return;

    var col = graph_col + label_start;
    const label_end = graph_col + graph_width;
    popup.writeVirtualTruncatedCells(screen, row, &col, label_end, commit.short_hash, laneStyle(star_index, selected), false);
    if (commit.refs.len == 0) return;
    popup.writeVirtualTruncatedCells(screen, row, &col, label_end, " ", rowStyle(selected), false);
    const label = commit.primaryLabel();
    popup.writeVirtualTruncatedCells(screen, row, &col, label_end, label.name, refLabelStyle(label.kind, selected), false);
}

fn rowStyle(selected: bool) render_mod.RenderStyle {
    return if (selected) .explorer_selected_focus else .command_popup;
}

fn refLabelStyle(kind: git_graph.GitRefKind, selected: bool) render_mod.RenderStyle {
    if (selected) {
        return switch (kind) {
            .tag => .git_graph_lane_yellow_selected,
            .head, .local_branch => .git_graph_lane_blue_selected,
            .remote_branch => .git_graph_lane_cyan_selected,
            .other => .explorer_selected_focus,
        };
    }
    return switch (kind) {
        .tag => .git_graph_lane_yellow,
        .head, .local_branch => .git_graph_lane_blue,
        .remote_branch => .git_graph_lane_cyan,
        .other => .command_popup_prompt,
    };
}

fn renderGraphPrefix(
    screen: *render_mod.VirtualScreen,
    row: usize,
    start_col: usize,
    width: usize,
    graph_prefix: []const u8,
    selected: bool,
) void {
    for (graph_prefix, 0..) |ch, i| {
        const dest = i * 2;
        if (dest >= width) break;
        const glyph = graphGlyph(ch) orelse continue;
        const style = laneStyle(dest / 2, selected);
        screen.setGlyph(row, start_col + dest, glyph, style);
        if ((ch == '-' or ch == '_') and dest + 1 < width) {
            screen.setGlyph(row, start_col + dest + 1, "─", style);
        }
    }
}

fn graphGlyph(ch: u8) ?[]const u8 {
    return switch (ch) {
        '*' => "●",
        '|' => "│",
        '/' => "╱",
        '\\' => "╲",
        '-' => "─",
        '_' => "─",
        '.' => "○",
        else => null,
    };
}

fn laneStyle(lane: usize, selected: bool) render_mod.RenderStyle {
    return if (selected)
        switch (lane % 6) {
            0 => .git_graph_lane_yellow_selected,
            1 => .git_graph_lane_green_selected,
            2 => .git_graph_lane_cyan_selected,
            3 => .git_graph_lane_blue_selected,
            4 => .git_graph_lane_magenta_selected,
            else => .git_graph_lane_purple_selected,
        }
    else switch (lane % 6) {
        0 => .git_graph_lane_yellow,
        1 => .git_graph_lane_green,
        2 => .git_graph_lane_cyan,
        3 => .git_graph_lane_blue,
        4 => .git_graph_lane_magenta,
        else => .git_graph_lane_purple,
    };
}

fn renderDetails(editor: anytype, geom: popup.FilesystemPickerGeometry, start_row: usize, detail_rows: usize) void {
    const screen = &editor.renderer.screen;
    const commit = editor.state.git_graph_panel.selectedCommit() orelse return;
    if (detail_rows < 7) return;

    const left = geom.col + 2;
    const right = geom.col + geom.width -| 3;
    if (right <= left + 4) return;

    for (0..detail_rows) |offset| {
        const row = start_row + offset;
        popup.drawPickerRow(screen, row, geom.col, geom.width, .command_popup_border, .popup_footer);
        screen.setGlyph(row, left, "│", .git_graph_lane_magenta);
        screen.setGlyph(row, right, "│", .git_graph_lane_magenta);
    }

    screen.setGlyph(start_row, left, "╭", .git_graph_lane_magenta);
    screen.setGlyph(start_row, right, "╮", .git_graph_lane_magenta);
    screen.setGlyph(start_row + detail_rows - 1, left, "╰", .git_graph_lane_magenta);
    screen.setGlyph(start_row + detail_rows - 1, right, "╯", .git_graph_lane_magenta);
    var col = left + 1;
    while (col < right) : (col += 1) {
        screen.setGlyph(start_row, col, "─", .git_graph_lane_magenta);
        screen.setGlyph(start_row + detail_rows - 1, col, "─", .git_graph_lane_magenta);
    }

    var row = start_row + 1;
    writeDetailLine(screen, left + 2, right - 1, row, "commit", commit.full_hash);
    row += 1;
    writeDetailLine(screen, left + 2, right - 1, row, "refs", if (commit.refs_raw.len > 0) commit.refs_raw else "-");
    row += 1;
    writeDetailLine(screen, left + 2, right - 1, row, "author", commit.author);
    row += 1;
    writeDetailLine(screen, left + 2, right - 1, row, "date", commit.date);
    row += 1;
    writeDetailLine(screen, left + 2, right - 1, row, "subject", commit.subject);
}

fn writeDetailLine(screen: *render_mod.VirtualScreen, start_col: usize, end_col: usize, row: usize, label: []const u8, value: []const u8) void {
    if (start_col >= end_col) return;
    var col = start_col;
    var label_buf: [24]u8 = undefined;
    const label_text = std.fmt.bufPrint(&label_buf, "{s}: ", .{label}) catch "";
    popup.writeVirtualTruncatedCells(screen, row, &col, end_col, label_text, .command_popup_prompt, false);
    popup.writeVirtualTruncatedCells(screen, row, &col, end_col, value, .popup_footer, false);
}

test "git graph renderer graph area leaves room for inline hashes" {
    try std.testing.expect(graphAreaWidth(96) >= 40);
    try std.testing.expect(graphAreaWidth(76) >= 32);
}
