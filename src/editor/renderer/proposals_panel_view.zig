const std = @import("std");
const proposal = @import("../agent/proposal.zig");
const viewport_mod = @import("../navigation/viewport.zig");
const popup = @import("popup.zig");
const render_mod = @import("virtual_screen.zig");

const title = " Proposals ";
const footer_text = "Up/Down scroll  PgUp/PgDn page  [/ ] proposal  a apply  r reject  Enter open  q/Esc close";

pub fn renderVirtualProposalsPanel(editor: anytype) void {
    if (!editor.state.proposal_manager.visible) return;
    const geom = proposalsPanelGeometry(editor) orelse return;
    const screen = &editor.renderer.screen;
    popup.drawPickerTop(screen, geom, title, .command_popup_border);

    if (geom.width < 52 or geom.height < 9) {
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

pub fn proposalsPanelGeometry(editor: anytype) ?popup.FilesystemPickerGeometry {
    if (!editor.state.proposal_manager.visible or editor.width < 20 or editor.height < 5) return null;
    const status_row = viewport_mod.statusRowIndex(editor);
    if (status_row < 4) return null;

    const available_width = editor.width -| 2;
    const desired_width = @min(@as(usize, 132), @max(@as(usize, 64), (editor.width * 92) / 100));
    const panel_width = @min(available_width, desired_width);
    const available_height = status_row;
    const desired_height = @max(@as(usize, 10), (available_height * 88) / 100);
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
    const message = if (editor.state.proposal_manager.proposals.items.len == 0) "No proposals yet." else "Terminal too small for Proposals";
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
    const manager = &editor.state.proposal_manager;
    const row = geom.row + 1;
    const end = geom.col + geom.width - 1;

    var buf: [192]u8 = undefined;
    const header = if (manager.selectedProposalConst()) |selected|
        std.fmt.bufPrint(&buf, "proposals: {d}    selected: #{d} {s}", .{
            manager.proposals.items.len,
            selected.id,
            selected.status.label(),
        }) catch "proposals"
    else
        std.fmt.bufPrint(&buf, "proposals: {d}", .{manager.proposals.items.len}) catch "proposals";

    var col = geom.col + 2;
    popup.writeVirtualTruncatedCells(screen, row, &col, end, header, .command_popup_prompt, false);
    popup.drawPickerSeparator(screen, geom.row + 2, geom.col, geom.width, .command_popup_border);
}

fn renderBody(editor: anytype, geom: popup.FilesystemPickerGeometry, start_row: usize, body_rows: usize) void {
    const screen = &editor.renderer.screen;
    const manager = &editor.state.proposal_manager;
    if (manager.proposals.items.len == 0) {
        var col = geom.col + 2;
        popup.writeVirtualTruncatedCells(screen, start_row, &col, geom.col + geom.width - 1, "No proposals yet. Run an Agent implementation session.", .explorer_dim, false);
        return;
    }

    const list_rows = @min(@as(usize, 5), @max(@as(usize, 2), body_rows / 3));
    renderProposalList(screen, geom, start_row, list_rows, manager);
    if (list_rows + 1 >= body_rows) return;

    const sep_row = start_row + list_rows;
    popup.drawPickerSeparator(screen, sep_row, geom.col, geom.width, .command_popup_border);
    const detail_row = sep_row + 1;
    renderDetail(screen, geom, detail_row, manager.selectedProposalConst());

    const diff_start = detail_row + 3;
    const diff_rows = body_rows -| (list_rows + 4);
    if (diff_rows > 0) renderDiff(screen, geom, diff_start, diff_rows, manager);
}

fn renderProposalList(screen: *render_mod.VirtualScreen, geom: popup.FilesystemPickerGeometry, start_row: usize, rows: usize, manager: anytype) void {
    const count = manager.proposals.items.len;
    const selected = @min(manager.selected_index, count - 1);
    var first: usize = 0;
    if (selected >= rows) first = selected - rows + 1;

    for (0..rows) |offset| {
        const index = first + offset;
        const row = start_row + offset;
        if (index >= count) break;
        const item = manager.proposals.items[index];
        const is_selected = index == selected;
        const fill_style: render_mod.RenderStyle = if (is_selected) .explorer_selected_focus else .command_popup;
        popup.drawPickerRow(screen, row, geom.col, geom.width, .command_popup_border, fill_style);
        var col = geom.col + 2;
        popup.writeVirtualTruncatedCells(screen, row, &col, geom.col + geom.width - 1, item.status.glyph(), statusStyle(item.status, is_selected), false);
        popup.writeVirtualTruncatedCells(screen, row, &col, geom.col + geom.width - 1, " ", fill_style, false);
        var buf: [64]u8 = undefined;
        const id_text = std.fmt.bufPrint(&buf, "#{d} ", .{item.id}) catch "# ";
        popup.writeVirtualTruncatedCells(screen, row, &col, geom.col + geom.width - 1, id_text, .explorer_dim, false);
        popup.writeVirtualTruncatedCells(screen, row, &col, geom.col + geom.width - 1, item.description, if (is_selected) .explorer_selected_focus else .command_popup, true);
    }
}

fn renderDetail(screen: *render_mod.VirtualScreen, geom: popup.FilesystemPickerGeometry, row: usize, selected: ?*const proposal.PatchProposal) void {
    const item = selected orelse return;
    const end = geom.col + geom.width - 1;
    var col = geom.col + 2;
    var buf: [256]u8 = undefined;
    const meta = std.fmt.bufPrint(&buf, "File: {s}    Session: #{d}    Status: {s}", .{
        item.file_path,
        item.session_id,
        item.status.label(),
    }) catch "Proposal";
    popup.writeVirtualTruncatedCells(screen, row, &col, end, meta, .command_popup_prompt, true);

    col = geom.col + 2;
    popup.writeVirtualTruncatedCells(screen, row + 1, &col, end, "Description: ", .explorer_dim, false);
    popup.writeVirtualTruncatedCells(screen, row + 1, &col, end, item.description, .command_popup, true);

    if (item.error_message) |message| {
        col = geom.col + 2;
        popup.writeVirtualTruncatedCells(screen, row + 2, &col, end, message, .popup_error, true);
    }
}

fn renderDiff(screen: *render_mod.VirtualScreen, geom: popup.FilesystemPickerGeometry, start_row: usize, rows: usize, manager: anytype) void {
    const item = manager.selectedProposalConst() orelse return;
    const total_rows = diffLineCount(item.unified_diff);
    manager.clampScroll(total_rows, rows);

    var line_index: usize = 0;
    var rendered: usize = 0;
    var lines = std.mem.splitScalar(u8, item.unified_diff, '\n');
    while (lines.next()) |line| : (line_index += 1) {
        if (line_index < manager.diff_scroll) continue;
        if (rendered >= rows) break;
        const row = start_row + rendered;
        popup.drawPickerRow(screen, row, geom.col, geom.width, .command_popup_border, .command_popup);
        writeDiffLine(screen, row, geom, line);
        rendered += 1;
    }
}

fn writeDiffLine(screen: *render_mod.VirtualScreen, row: usize, geom: popup.FilesystemPickerGeometry, line: []const u8) void {
    const style: render_mod.RenderStyle = if (std.mem.startsWith(u8, line, "+") and !std.mem.startsWith(u8, line, "+++"))
        .git_diff_added
    else if (std.mem.startsWith(u8, line, "-") and !std.mem.startsWith(u8, line, "---"))
        .git_diff_deleted
    else if (std.mem.startsWith(u8, line, "@@"))
        .command_popup_prompt
    else
        .explorer_dim;
    var col = geom.col + 2;
    popup.writeVirtualTruncatedCells(screen, row, &col, geom.col + geom.width - 1, line, style, false);
}

fn diffLineCount(diff: []const u8) usize {
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, diff, '\n');
    while (it.next()) |_| count += 1;
    return count;
}

fn statusStyle(status: proposal.PatchProposalStatus, selected: bool) render_mod.RenderStyle {
    return switch (status) {
        .pending, .approved, .applying => if (selected) .git_diff_modified_selected else .git_diff_modified,
        .applied => if (selected) .git_diff_added_selected else .git_diff_added,
        .rejected => if (selected) .explorer_selected_focus else .explorer_dim,
        .failed => if (selected) .git_diff_deleted_selected else .git_diff_deleted,
    };
}

test "proposals panel geometry uses wide modal" {
    const FakeManager = struct { visible: bool = true };
    const FakeState = struct { proposal_manager: FakeManager = .{} };
    const FakeEditor = struct {
        width: usize = 120,
        height: usize = 40,
        terminal_panel: struct { visible: bool = false } = .{},
        state: FakeState = .{},
    };
    const editor = FakeEditor{};
    const geom = proposalsPanelGeometry(editor).?;
    try std.testing.expect(geom.width >= 90);
}
