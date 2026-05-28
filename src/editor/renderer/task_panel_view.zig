const std = @import("std");
const viewport_mod = @import("../navigation/viewport.zig");
const task_mod = @import("../tasks/task.zig");
const popup = @import("popup.zig");
const render_mod = @import("virtual_screen.zig");

const title = " Tasks ";
const footer_text = "Up/Down scroll  PgUp/PgDn page  [/ ] task  r rerun  c cancel  q/Esc close";

pub fn renderVirtualTaskPanel(editor: anytype) void {
    if (!editor.state.task_manager.visible) return;
    const geom = taskPanelGeometry(editor) orelse return;
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

pub fn taskPanelGeometry(editor: anytype) ?popup.FilesystemPickerGeometry {
    if (!editor.state.task_manager.visible or editor.width < 20 or editor.height < 5) return null;
    const status_row = viewport_mod.statusRowIndex(editor);
    if (status_row < 4) return null;

    const available_width = editor.width -| 2;
    const desired_width = @min(@as(usize, 132), @max(@as(usize, 64), (editor.width * 90) / 100));
    const panel_width = @min(available_width, desired_width);
    const available_height = status_row;
    const desired_height = @max(@as(usize, 10), (available_height * 84) / 100);
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
    const message = if (editor.state.task_manager.tasks.items.len == 0) "No tasks yet." else "Terminal too small for Tasks";
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
    const manager = &editor.state.task_manager;
    const selected = manager.selectedTaskConst();

    var buf: [192]u8 = undefined;
    const header = if (selected) |task|
        std.fmt.bufPrint(&buf, "tasks: {d}    selected: #{d} {s}", .{
            manager.tasks.items.len,
            task.id,
            task.command_display,
        }) catch "tasks"
    else
        std.fmt.bufPrint(&buf, "tasks: {d}", .{manager.tasks.items.len}) catch "tasks";
    var col = geom.col + 2;
    popup.writeVirtualTruncatedCells(screen, row, &col, inner_end, header, .command_popup_prompt, false);
    popup.drawPickerSeparator(screen, geom.row + 2, geom.col, geom.width, .command_popup_border);
}

fn renderBody(editor: anytype, geom: popup.FilesystemPickerGeometry, start_row: usize, body_rows: usize) void {
    const screen = &editor.renderer.screen;
    const manager = &editor.state.task_manager;

    if (manager.tasks.items.len == 0) {
        var col = geom.col + 2;
        popup.writeVirtualTruncatedCells(screen, start_row, &col, geom.col + geom.width - 1, "No tasks yet. Run :run <command>.", .explorer_dim, false);
        return;
    }

    const list_rows = @min(@as(usize, 5), @max(@as(usize, 2), body_rows / 3));
    renderTaskList(screen, geom, start_row, list_rows, manager);

    if (list_rows + 1 >= body_rows) return;
    const sep_row = start_row + list_rows;
    popup.drawPickerSeparator(screen, sep_row, geom.col, geom.width, .command_popup_border);

    const output_title_row = sep_row + 1;
    renderOutputTitle(screen, geom, output_title_row, manager.selectedTaskConst());

    const output_start = output_title_row + 1;
    const output_rows = body_rows -| (list_rows + 2);
    if (output_rows == 0) return;
    renderOutput(screen, geom, output_start, output_rows, manager);
}

fn renderTaskList(
    screen: *render_mod.VirtualScreen,
    geom: popup.FilesystemPickerGeometry,
    start_row: usize,
    rows: usize,
    manager: anytype,
) void {
    const count = manager.tasks.items.len;
    const selected = @min(manager.selected_index, count - 1);
    var first: usize = 0;
    if (selected >= rows) first = selected - rows + 1;

    for (0..rows) |offset| {
        const index = first + offset;
        const row = start_row + offset;
        if (index >= count) break;
        const task = manager.tasks.items[index];
        const is_selected = index == selected;
        const fill_style: render_mod.RenderStyle = if (is_selected) .explorer_selected_focus else .command_popup;
        popup.drawPickerRow(screen, row, geom.col, geom.width, .command_popup_border, fill_style);
        var col = geom.col + 2;
        popup.writeVirtualTruncatedCells(screen, row, &col, geom.col + geom.width - 1, statusGlyph(task.status), statusStyle(task.status, is_selected), false);
        popup.writeVirtualTruncatedCells(screen, row, &col, geom.col + geom.width - 1, " ", fill_style, false);
        popup.writeVirtualTruncatedCells(screen, row, &col, geom.col + geom.width - 1, task.status.label(), statusStyle(task.status, is_selected), false);
        popup.writeVirtualTruncatedCells(screen, row, &col, geom.col + geom.width - 1, "  ", fill_style, false);
        popup.writeVirtualTruncatedCells(screen, row, &col, geom.col + geom.width - 1, task.command_display, if (is_selected) .explorer_selected_focus else .command_popup, true);
    }
}

fn renderOutputTitle(
    screen: *render_mod.VirtualScreen,
    geom: popup.FilesystemPickerGeometry,
    row: usize,
    task: ?*const task_mod.Task,
) void {
    const text = if (task) |selected| selected.command_display else "Output";
    popup.drawPickerRow(screen, row, geom.col, geom.width, .command_popup_border, .command_popup);
    var col = geom.col + 2;
    popup.writeVirtualTruncatedCells(screen, row, &col, geom.col + geom.width - 1, "Output: ", .explorer_dim, false);
    popup.writeVirtualTruncatedCells(screen, row, &col, geom.col + geom.width - 1, text, .command_popup_prompt, true);
}

fn renderOutput(
    screen: *render_mod.VirtualScreen,
    geom: popup.FilesystemPickerGeometry,
    start_row: usize,
    rows: usize,
    manager: anytype,
) void {
    manager.clampScroll(rows);
    const task = manager.selectedTaskConst() orelse return;
    if (task.output.items.len == 0) {
        var col = geom.col + 2;
        popup.writeVirtualTruncatedCells(screen, start_row, &col, geom.col + geom.width - 1, "No output yet.", .explorer_dim, false);
        return;
    }

    for (0..rows) |offset| {
        const index = manager.output_scroll + offset;
        const row = start_row + offset;
        if (index >= task.output.items.len) break;
        const line = task.output.items[index];
        popup.drawPickerRow(screen, row, geom.col, geom.width, .command_popup_border, .command_popup);
        var col = geom.col + 2;
        popup.writeVirtualTruncatedCells(screen, row, &col, geom.col + geom.width - 1, "[", .explorer_dim, false);
        popup.writeVirtualTruncatedCells(screen, row, &col, geom.col + geom.width - 1, line.kind.label(), outputStyle(line.kind), false);
        popup.writeVirtualTruncatedCells(screen, row, &col, geom.col + geom.width - 1, "] ", .explorer_dim, false);
        popup.writeVirtualTruncatedCells(screen, row, &col, geom.col + geom.width - 1, line.text, outputStyle(line.kind), true);
    }
}

fn statusGlyph(status: task_mod.TaskStatus) []const u8 {
    return switch (status) {
        .queued => ".",
        .running => "*",
        .success => "+",
        .failed => "x",
        .cancelled => "-",
    };
}

fn statusStyle(status: task_mod.TaskStatus, selected: bool) render_mod.RenderStyle {
    return switch (status) {
        .success => if (selected) .git_diff_added_selected else .git_diff_added,
        .failed => if (selected) .git_diff_deleted_selected else .git_diff_deleted,
        .cancelled => if (selected) .explorer_selected_focus else .explorer_dim,
        .queued, .running => if (selected) .git_diff_modified_selected else .git_diff_modified,
    };
}

fn outputStyle(kind: task_mod.TaskOutputKind) render_mod.RenderStyle {
    return switch (kind) {
        .stdout => .command_popup,
        .stderr => .git_diff_deleted,
        .system => .explorer_dim,
    };
}

test "task panel geometry uses wide modal" {
    const FakeManager = struct { visible: bool = true };
    const FakeState = struct { task_manager: FakeManager = .{} };
    const FakeEditor = struct {
        width: usize = 120,
        height: usize = 40,
        terminal_panel: struct { visible: bool = false } = .{},
        state: FakeState = .{},
    };
    const editor = FakeEditor{};
    const geom = taskPanelGeometry(editor).?;
    try std.testing.expect(geom.width >= 90);
}
