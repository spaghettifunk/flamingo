const std = @import("std");
const agent = @import("../agent/session.zig");
const viewport_mod = @import("../navigation/viewport.zig");
const popup = @import("popup.zig");
const render_mod = @import("virtual_screen.zig");

const title = " Agent ";
const footer_text = "Enter run  Tab mode  Arrows scroll  PgUp/PgDn page  Ctrl+C cancel  Esc close";

pub fn renderVirtualAgentPanel(editor: anytype) void {
    if (!editor.state.agent_manager.visible) return;
    const geom = agentPanelGeometry(editor) orelse return;
    const screen = &editor.renderer.screen;
    popup.drawPickerTop(screen, geom, title, .command_popup_border);

    if (geom.width < 52 or geom.height < 9) {
        renderMinimal(editor, geom);
        return;
    }

    fillRows(screen, geom, .command_popup);
    renderControls(editor, geom);

    const body_start = geom.row + 5;
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

pub fn agentPanelGeometry(editor: anytype) ?popup.FilesystemPickerGeometry {
    if (!editor.state.agent_manager.visible or editor.width < 20 or editor.height < 5) return null;
    const status_row = viewport_mod.statusRowIndex(editor);
    if (status_row < 4) return null;

    const available_width = editor.width -| 2;
    const desired_width = @min(@as(usize, 132), @max(@as(usize, 64), (editor.width * 90) / 100));
    const panel_width = @min(available_width, desired_width);
    const available_height = status_row;
    const desired_height = @max(@as(usize, 10), (available_height * 86) / 100);
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
    var col = geom.col + 2;
    popup.writeVirtualTruncatedCells(screen, geom.row + 1, &col, geom.col + geom.width - 1, "Terminal too small for Agent", .popup_error, false);
    popup.drawPickerBottom(screen, bottom_row, geom.col, geom.width, .command_popup_border);
}

fn fillRows(screen: *render_mod.VirtualScreen, geom: popup.FilesystemPickerGeometry, style: render_mod.RenderStyle) void {
    const bottom_row = geom.row + geom.height - 1;
    var row = geom.row + 1;
    while (row < bottom_row) : (row += 1) {
        popup.drawPickerRow(screen, row, geom.col, geom.width, .command_popup_border, style);
    }
}

fn renderControls(editor: anytype, geom: popup.FilesystemPickerGeometry) void {
    const screen = &editor.renderer.screen;
    const manager = &editor.state.agent_manager;
    const end = geom.col + geom.width - 1;

    var row = geom.row + 1;
    var col = geom.col + 2;
    popup.writeVirtualTruncatedCells(screen, row, &col, end, "Mode: ", .explorer_dim, false);
    writeModeSegment(screen, row, &col, end, "Plan", manager.selected_mode == .plan);
    popup.writeVirtualTruncatedCells(screen, row, &col, end, " ", .command_popup, false);
    writeModeSegment(screen, row, &col, end, "Implementation", manager.selected_mode == .implementation);
    var provider_buf: [96]u8 = undefined;
    const provider_text = if (editor.runtime.agent_backend.availabilityMessage()) |message|
        std.fmt.bufPrint(&provider_buf, "  Provider: {s} ({s})", .{ editor.runtime.agent_backend.kind().label(), message }) catch ""
    else
        std.fmt.bufPrint(&provider_buf, "  Provider: {s}", .{editor.runtime.agent_backend.kind().label()}) catch "";
    popup.writeVirtualTruncatedCells(screen, row, &col, end, provider_text, if (editor.runtime.agent_backend.availabilityMessage() == null) .explorer_dim else .git_diff_deleted, true);

    row += 1;
    col = geom.col + 2;
    popup.writeVirtualTruncatedCells(screen, row, &col, end, "Prompt: ", .explorer_dim, false);
    const prompt_style: render_mod.RenderStyle = if (manager.canEditPrompt()) .command_popup_prompt else .explorer_dim;
    const prompt_text = if (manager.prompt_input.items.len > 0) manager.prompt_input.items else "type a request";
    popup.writeVirtualTruncatedCells(screen, row, &col, end, prompt_text, prompt_style, true);

    row += 1;
    col = geom.col + 2;
    const session = manager.selectedSessionConst();
    if (session) |selected| {
        var buf: [192]u8 = undefined;
        const header = std.fmt.bufPrint(&buf, "Session: {s}  {s}  #{d}", .{
            selected.status.label(),
            selected.mode.label(),
            selected.id,
        }) catch "Session";
        popup.writeVirtualTruncatedCells(screen, row, &col, end, header, statusStyle(selected.status), false);
        if (selected.truncated) {
            popup.writeVirtualTruncatedCells(screen, row, &col, end, "  truncated", .popup_error, false);
        }
    } else {
        popup.writeVirtualTruncatedCells(screen, row, &col, end, "Session: idle", .explorer_dim, false);
    }

    popup.drawPickerSeparator(screen, geom.row + 4, geom.col, geom.width, .command_popup_border);
}

fn writeModeSegment(
    screen: *render_mod.VirtualScreen,
    row: usize,
    col: *usize,
    end: usize,
    text: []const u8,
    selected: bool,
) void {
    popup.writeVirtualTruncatedCells(screen, row, col, end, "[", .explorer_dim, false);
    popup.writeVirtualTruncatedCells(screen, row, col, end, text, if (selected) .git_diff_modified else .explorer_dim, false);
    popup.writeVirtualTruncatedCells(screen, row, col, end, "]", .explorer_dim, false);
}

fn renderBody(editor: anytype, geom: popup.FilesystemPickerGeometry, start_row: usize, body_rows: usize) void {
    const screen = &editor.renderer.screen;
    const manager = &editor.state.agent_manager;

    const session = manager.selectedSessionConst() orelse {
        var col = geom.col + 2;
        popup.writeVirtualTruncatedCells(screen, start_row, &col, geom.col + geom.width - 1, "No agent sessions yet.", .explorer_dim, false);
        return;
    };

    var event_start = start_row;
    var event_rows = body_rows;
    if (editor.state.execution_manager.latestBySessionConst(session.id)) |execution| {
        const block_rows = @min(event_rows, executionBlockRows(execution));
        renderExecutionBlock(screen, geom, event_start, block_rows, execution);
        event_start += block_rows;
        event_rows -|= block_rows;
        if (event_rows > 0) {
            popup.drawPickerSeparator(screen, event_start, geom.col, geom.width, .command_popup_border);
            event_start += 1;
            event_rows -|= 1;
        }
    }

    if (event_rows == 0) return;
    manager.clampScroll(event_rows);

    if (session.events.items.len == 0) {
        var col = geom.col + 2;
        popup.writeVirtualTruncatedCells(screen, event_start, &col, geom.col + geom.width - 1, "No events yet.", .explorer_dim, false);
        return;
    }

    for (0..event_rows) |offset| {
        const index = manager.event_scroll + offset;
        const row = event_start + offset;
        if (index >= session.events.items.len) break;
        const event = session.events.items[index];
        popup.drawPickerRow(screen, row, geom.col, geom.width, .command_popup_border, .command_popup);
        renderEventRow(screen, row, geom, event);
    }
}

fn executionBlockRows(execution: anytype) usize {
    var rows: usize = 2;
    rows += @min(execution.validation_tasks.items.len, @as(usize, 2));
    if (execution.summary != null or execution.error_message != null) rows += 1;
    return rows;
}

fn renderExecutionBlock(screen: *render_mod.VirtualScreen, geom: popup.FilesystemPickerGeometry, start_row: usize, rows: usize, execution: anytype) void {
    if (rows == 0) return;
    const end = geom.col + geom.width - 1;
    var row = start_row;
    var col = geom.col + 2;
    var buf: [256]u8 = undefined;
    const header = std.fmt.bufPrint(&buf, "Execution #{d}  Proposal #{d}  Status: {s}", .{
        execution.id,
        execution.proposal_id,
        execution.status.label(),
    }) catch "Execution";
    popup.writeVirtualTruncatedCells(screen, row, &col, end, header, .command_popup_prompt, true);
    if (rows == 1) return;

    row += 1;
    col = geom.col + 2;
    popup.writeVirtualTruncatedCells(screen, row, &col, end, "Validation:", .explorer_dim, false);

    var rendered_tasks: usize = 0;
    while (rendered_tasks < execution.validation_tasks.items.len and rendered_tasks < 2 and row + 1 < start_row + rows) : (rendered_tasks += 1) {
        row += 1;
        const task = execution.validation_tasks.items[rendered_tasks];
        col = geom.col + 2;
        const marker = validationMarker(task.status);
        popup.writeVirtualTruncatedCells(screen, row, &col, end, marker, validationStyle(task.status), false);
        popup.writeVirtualTruncatedCells(screen, row, &col, end, " ", .command_popup, false);
        popup.writeVirtualTruncatedCells(screen, row, &col, end, task.command, validationStyle(task.status), true);
    }

    if (row + 1 < start_row + rows) {
        row += 1;
        col = geom.col + 2;
        const summary = execution.summary orelse execution.error_message orelse return;
        popup.writeVirtualTruncatedCells(screen, row, &col, end, summary, if (execution.status == .failed) .git_diff_deleted else .git_diff_added, true);
    }
}

fn renderEventRow(screen: *render_mod.VirtualScreen, row: usize, geom: popup.FilesystemPickerGeometry, event: agent.AgentEvent) void {
    var col = geom.col + 2;
    const end = geom.col + geom.width - 1;
    popup.writeVirtualTruncatedCells(screen, row, &col, end, event.kind.label(), eventStyle(event.kind), false);
    popup.writeVirtualTruncatedCells(screen, row, &col, end, ": ", .explorer_dim, false);
    popup.writeVirtualTruncatedCells(screen, row, &col, end, event.text, eventStyle(event.kind), true);
}

fn statusStyle(status: agent.AgentSessionStatus) render_mod.RenderStyle {
    return switch (status) {
        .idle => .explorer_dim,
        .running => .git_diff_modified,
        .completed => .git_diff_added,
        .failed => .git_diff_deleted,
        .cancelled => .explorer_dim,
    };
}

fn eventStyle(kind: agent.AgentEventKind) render_mod.RenderStyle {
    return switch (kind) {
        .user_prompt => .command_popup_prompt,
        .assistant_message => .command_popup,
        .status => .explorer_dim,
        .tool_call => .git_graph_lane_blue,
        .tool_result => .git_diff_added,
        .final_plan => .git_diff_modified,
        .task_started, .task_finished => .git_diff_modified,
        .diff_available => .git_diff_modified,
        .proposal_created => .git_graph_lane_blue,
        .proposal_approved, .proposal_applying => .git_diff_modified,
        .proposal_applied => .git_diff_added,
        .proposal_rejected => .explorer_dim,
        .proposal_failed => .git_diff_deleted,
        .execution_started, .execution_applying, .execution_validating => .git_diff_modified,
        .execution_validation_task_started => .git_diff_modified,
        .execution_validation_task_finished => .git_diff_added,
        .execution_completed => .git_diff_added,
        .execution_failed => .git_diff_deleted,
        .execution_cancelled => .explorer_dim,
        .agent_error => .git_diff_deleted,
    };
}

fn validationMarker(status: anytype) []const u8 {
    return switch (status) {
        .queued => "o",
        .running => "*",
        .success => "+",
        .failed => "!",
        .cancelled => "x",
    };
}

fn validationStyle(status: anytype) render_mod.RenderStyle {
    return switch (status) {
        .queued => .explorer_dim,
        .running => .git_diff_modified,
        .success => .git_diff_added,
        .failed => .git_diff_deleted,
        .cancelled => .explorer_dim,
    };
}

test "agent panel geometry uses wide modal" {
    const FakeManager = struct { visible: bool = true };
    const FakeState = struct { agent_manager: FakeManager = .{} };
    const FakeEditor = struct {
        width: usize = 120,
        height: usize = 40,
        terminal_panel: struct { visible: bool = false } = .{},
        state: FakeState = .{},
    };
    const editor = FakeEditor{};
    const geom = agentPanelGeometry(editor).?;
    try std.testing.expect(geom.width >= 90);
}
