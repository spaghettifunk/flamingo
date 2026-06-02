const std = @import("std");
const agent = @import("../agent/session.zig");
const viewport_mod = @import("../navigation/viewport.zig");
const popup = @import("popup.zig");
const render_mod = @import("virtual_screen.zig");

const title = " Agent ";
const footer_text = "Ctrl+S run  Enter newline  Tab mode  Arrows/PgUp/PgDn scroll  Ctrl+C cancel  Esc close";

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

    const prompt_rows = promptTextAreaRows(geom);
    const controls_rows = 5 + prompt_rows;
    const body_start = geom.row + controls_rows + 1;
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
    const prompt_rows = promptTextAreaRows(geom);
    const prompt_start_row = geom.row + 3;

    var row = geom.row + 1;
    var col = geom.col + 2;
    var backend = editor.runtime.agentBackend();
    popup.writeVirtualTruncatedCells(screen, row, &col, end, "Mode: ", .explorer_dim, false);
    writeModeSegment(screen, row, &col, end, "Plan", manager.selected_mode == .plan);
    popup.writeVirtualTruncatedCells(screen, row, &col, end, " ", .command_popup, false);
    writeModeSegment(screen, row, &col, end, "Implementation", manager.selected_mode == .implementation);
    var provider_buf: [96]u8 = undefined;
    const provider_text = if (backend.availabilityMessage()) |message|
        std.fmt.bufPrint(&provider_buf, "  Provider: {s} ({s})", .{ backend.kind().label(), message }) catch ""
    else
        std.fmt.bufPrint(&provider_buf, "  Provider: {s}", .{backend.kind().label()}) catch "";
    popup.writeVirtualTruncatedCells(screen, row, &col, end, provider_text, if (backend.availabilityMessage() == null) .explorer_dim else .git_diff_deleted, true);

    row += 1;
    col = geom.col + 2;
    popup.writeVirtualTruncatedCells(screen, row, &col, end, "Prompt: ", .explorer_dim, false);
    const prompt_hint = if (manager.prompt_input.items.len == 0) "type a request" else "";
    popup.writeVirtualTruncatedCells(screen, row, &col, end, prompt_hint, .explorer_dim, true);

    renderPromptTextArea(screen, geom, prompt_start_row, prompt_rows, manager);

    row = prompt_start_row + prompt_rows;
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

    row += 1;
    col = geom.col + 2;
    if (session) |selected| {
        renderContextSummary(screen, row, geom, selected);
    } else {
        popup.writeVirtualTruncatedCells(screen, row, &col, end, "Context: none", .explorer_dim, false);
    }

    popup.drawPickerSeparator(screen, geom.row + 5 + prompt_rows, geom.col, geom.width, .command_popup_border);
}

fn promptTextAreaRows(geom: popup.FilesystemPickerGeometry) usize {
    return @min(@as(usize, 8), @max(@as(usize, 3), geom.height / 5));
}

fn lineVisualRows(line: []const u8, width: usize) usize {
    if (line.len == 0) return 1;
    return (line.len + width - 1) / width;
}

fn promptVisualRows(text: []const u8, width: usize) usize {
    if (text.len == 0) return 1;
    var rows: usize = 0;
    var line_start: usize = 0;
    for (text, 0..) |ch, index| {
        if (ch != '\n') continue;
        rows += lineVisualRows(text[line_start..index], width);
        line_start = index + 1;
    }
    rows += lineVisualRows(text[line_start..], width);
    return rows;
}

fn promptVisualSliceAt(text: []const u8, width: usize, target_row: usize) []const u8 {
    if (text.len == 0) return if (target_row == 0) "" else "";

    var visual_row: usize = 0;
    var line_start: usize = 0;
    for (text, 0..) |ch, index| {
        if (ch != '\n') continue;
        if (visualSliceInLine(text[line_start..index], width, target_row, &visual_row)) |slice| return slice;
        line_start = index + 1;
    }
    return visualSliceInLine(text[line_start..], width, target_row, &visual_row) orelse "";
}

fn visualSliceInLine(line: []const u8, width: usize, target_row: usize, visual_row: *usize) ?[]const u8 {
    if (line.len == 0) {
        if (visual_row.* == target_row) return line;
        visual_row.* += 1;
        return null;
    }

    var start: usize = 0;
    while (start < line.len) {
        const end = @min(start + width, line.len);
        if (visual_row.* == target_row) return line[start..end];
        visual_row.* += 1;
        start = end;
    }
    return null;
}

fn renderPromptTextArea(
    screen: *render_mod.VirtualScreen,
    geom: popup.FilesystemPickerGeometry,
    start_row: usize,
    rows: usize,
    manager: anytype,
) void {
    if (rows == 0) return;
    const end = geom.col + geom.width - 1;
    const style: render_mod.RenderStyle = if (manager.canEditPrompt()) .command_popup_prompt else .explorer_dim;
    const text_start_col = geom.col + 4;
    const text_width = @max(@as(usize, 1), end -| text_start_col + 1);
    manager.clampPromptScroll(promptVisualRows(manager.prompt_input.items, text_width), rows);
    for (0..rows) |offset| {
        const row = start_row + offset;
        popup.drawPickerRow(screen, row, geom.col, geom.width, .command_popup_border, .command_popup);
        var col = geom.col + 2;
        popup.writeVirtualTruncatedCells(screen, row, &col, end, "| ", .explorer_dim, false);
        if (manager.prompt_input.items.len == 0 and offset == 0) {
            popup.writeVirtualTruncatedCells(screen, row, &col, end, "type a request", .explorer_dim, true);
            continue;
        }
        const line = promptVisualSliceAt(manager.prompt_input.items, text_width, manager.prompt_scroll + offset);
        popup.writeVirtualTruncatedCells(screen, row, &col, end, line, style, true);
    }
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
    if (editor.state.agent_manager.pendingApprovalForSession(session.id)) |approval| {
        const block_rows = @min(event_rows, @as(usize, 4));
        renderApprovalBlock(screen, geom, event_start, block_rows, approval);
        event_start += block_rows;
        event_rows -|= block_rows;
        if (event_rows > 0) {
            popup.drawPickerSeparator(screen, event_start, geom.col, geom.width, .command_popup_border);
            event_start += 1;
            event_rows -|= 1;
        }
    }

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

    if (session.show_context_details and session.context_package != null and event_rows > 2) {
        const block_rows = @min(event_rows, contextDetailRows(session));
        renderContextDetails(screen, geom, event_start, block_rows, session.context_package.?);
        event_start += block_rows;
        event_rows -|= block_rows;
        if (event_rows > 0) {
            popup.drawPickerSeparator(screen, event_start, geom.col, geom.width, .command_popup_border);
            event_start += 1;
            event_rows -|= 1;
        }
    }

    if (session.audit_events.items.len > 0 and event_rows > 2) {
        const block_rows = @min(event_rows, auditBlockRows(session));
        renderAuditBlock(screen, geom, event_start, block_rows, session);
        event_start += block_rows;
        event_rows -|= block_rows;
        if (event_rows > 0) {
            popup.drawPickerSeparator(screen, event_start, geom.col, geom.width, .command_popup_border);
            event_start += 1;
            event_rows -|= 1;
        }
    }

    if (event_rows == 0) return;
    const event_content_width = eventContentWidth(geom);
    const total_event_rows = sessionVisualRows(session, event_content_width);
    manager.clampScrollRows(total_event_rows, event_rows);

    if (session.events.items.len == 0) {
        var col = geom.col + 2;
        popup.writeVirtualTruncatedCells(screen, event_start, &col, geom.col + geom.width - 1, "No events yet.", .explorer_dim, false);
        return;
    }

    renderEventRows(screen, geom, event_start, event_rows, session, manager.event_scroll);
}

fn renderContextSummary(screen: *render_mod.VirtualScreen, row: usize, geom: popup.FilesystemPickerGeometry, session: anytype) void {
    const end = geom.col + geom.width - 1;
    var col = geom.col + 2;
    const package = session.context_package orelse {
        popup.writeVirtualTruncatedCells(screen, row, &col, end, "Context: pending", .explorer_dim, true);
        return;
    };
    var buf: [192]u8 = undefined;
    const workspace = workspaceName(package.workspace_summary);
    const text = std.fmt.bufPrint(&buf, "Context: Workspace {s}  Git changes {d}  Files {d}  Tools {d}  Budget {d}/{d} KiB{s}", .{
        workspace,
        countSummaryLines(package.git_status_summary),
        package.relevant_files.items.len,
        package.tool_descriptions.items.len,
        package.budget.used_bytes / 1024,
        package.budget.max_total_bytes / 1024,
        if (package.budget.truncated) " truncated" else "",
    }) catch "Context";
    popup.writeVirtualTruncatedCells(screen, row, &col, end, text, .explorer_dim, true);
}

fn contextDetailRows(session: anytype) usize {
    const package = session.context_package orelse return 0;
    return 7 + package.relevant_files.items.len + package.tool_descriptions.items.len + package.notes.items.len;
}

fn renderContextDetails(screen: *render_mod.VirtualScreen, geom: popup.FilesystemPickerGeometry, start_row: usize, rows: usize, package: anytype) void {
    if (rows == 0) return;
    const end = geom.col + geom.width - 1;
    var row = start_row;
    var col = geom.col + 2;
    popup.writeVirtualTruncatedCells(screen, row, &col, end, "Context Package", .command_popup_prompt, true);
    if (rows == 1) return;

    row += 1;
    col = geom.col + 2;
    popup.writeVirtualTruncatedCells(screen, row, &col, end, package.system_prompt, .explorer_dim, true);
    if (row + 1 >= start_row + rows) return;

    row += 1;
    col = geom.col + 2;
    popup.writeVirtualTruncatedCells(screen, row, &col, end, package.workspace_summary, .explorer_dim, true);
    if (row + 1 >= start_row + rows) return;

    row += 1;
    col = geom.col + 2;
    popup.writeVirtualTruncatedCells(screen, row, &col, end, "Git Status: ", .explorer_dim, false);
    popup.writeVirtualTruncatedCells(screen, row, &col, end, firstLine(package.git_status_summary), .git_diff_modified, true);
    if (row + 1 >= start_row + rows) return;

    row += 1;
    col = geom.col + 2;
    popup.writeVirtualTruncatedCells(screen, row, &col, end, "Files", .explorer_dim, true);
    for (package.relevant_files.items) |file| {
        if (row + 1 >= start_row + rows) return;
        row += 1;
        col = geom.col + 2;
        var buf: [192]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "- {s} ({s}){s}", .{ file.path, file.reason, if (file.truncated) " truncated" else "" }) catch file.path;
        popup.writeVirtualTruncatedCells(screen, row, &col, end, text, .command_popup, true);
    }
    if (row + 1 >= start_row + rows) return;

    row += 1;
    col = geom.col + 2;
    popup.writeVirtualTruncatedCells(screen, row, &col, end, "Tools", .explorer_dim, true);
    for (package.tool_descriptions.items) |tool| {
        if (row + 1 >= start_row + rows) return;
        row += 1;
        col = geom.col + 2;
        popup.writeVirtualTruncatedCells(screen, row, &col, end, tool.name, .git_graph_lane_blue, true);
    }
    for (package.notes.items) |note| {
        if (row + 1 >= start_row + rows) return;
        row += 1;
        col = geom.col + 2;
        popup.writeVirtualTruncatedCells(screen, row, &col, end, note, .popup_error, true);
    }
}

fn renderApprovalBlock(screen: *render_mod.VirtualScreen, geom: popup.FilesystemPickerGeometry, start_row: usize, rows: usize, approval: anytype) void {
    if (rows == 0) return;
    const end = geom.col + geom.width - 1;
    var row = start_row;
    var col = geom.col + 2;
    popup.writeVirtualTruncatedCells(screen, row, &col, end, "Approval Required", .git_diff_modified, true);
    if (rows == 1) return;
    row += 1;
    col = geom.col + 2;
    popup.writeVirtualTruncatedCells(screen, row, &col, end, approval.description, .command_popup_prompt, true);
    if (rows == 2) return;
    row += 1;
    col = geom.col + 2;
    popup.writeVirtualTruncatedCells(screen, row, &col, end, "a approve   d deny", .explorer_dim, true);
    if (rows == 3) return;
    if (approval.command_display) |command| {
        row += 1;
        col = geom.col + 2;
        popup.writeVirtualTruncatedCells(screen, row, &col, end, command, .git_graph_lane_blue, true);
    }
}

fn auditBlockRows(session: anytype) usize {
    return 1 + @min(session.audit_events.items.len, @as(usize, 3));
}

fn renderAuditBlock(screen: *render_mod.VirtualScreen, geom: popup.FilesystemPickerGeometry, start_row: usize, rows: usize, session: anytype) void {
    if (rows == 0) return;
    const end = geom.col + geom.width - 1;
    var row = start_row;
    var col = geom.col + 2;
    popup.writeVirtualTruncatedCells(screen, row, &col, end, "Audit", .explorer_dim, true);

    const count = @min(session.audit_events.items.len, rows - 1);
    const first = session.audit_events.items.len - count;
    for (0..count) |offset| {
        const event = session.audit_events.items[first + offset];
        row += 1;
        col = geom.col + 2;
        popup.writeVirtualTruncatedCells(screen, row, &col, end, event.kind.label(), auditStyle(event.kind), false);
        popup.writeVirtualTruncatedCells(screen, row, &col, end, ": ", .explorer_dim, false);
        popup.writeVirtualTruncatedCells(screen, row, &col, end, event.message, auditStyle(event.kind), true);
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

fn eventContentWidth(geom: popup.FilesystemPickerGeometry) usize {
    const start_col = geom.col + 2;
    const end = geom.col + geom.width - 1;
    return @max(@as(usize, 1), end -| start_col + 1);
}

fn sessionVisualRows(session: anytype, content_width: usize) usize {
    var rows: usize = 0;
    for (session.events.items) |event| {
        rows += eventVisualRows(event, content_width);
    }
    return rows;
}

fn eventVisualRows(event: agent.AgentEvent, content_width: usize) usize {
    const prefix_width = eventPrefixWidth(event);
    const text_width = @max(@as(usize, 1), content_width -| prefix_width);
    return textVisualRows(event.text, text_width);
}

fn eventPrefixWidth(event: agent.AgentEvent) usize {
    return event.kind.label().len + 2;
}

fn textVisualRows(text: []const u8, width: usize) usize {
    if (text.len == 0) return 1;
    var rows: usize = 0;
    var line_start: usize = 0;
    for (text, 0..) |ch, index| {
        if (ch != '\n') continue;
        rows += lineVisualRows(text[line_start..index], width);
        line_start = index + 1;
    }
    rows += lineVisualRows(text[line_start..], width);
    return rows;
}

fn renderEventRows(
    screen: *render_mod.VirtualScreen,
    geom: popup.FilesystemPickerGeometry,
    start_row: usize,
    rows: usize,
    session: anytype,
    scroll_row: usize,
) void {
    var skipped: usize = 0;
    var drawn: usize = 0;
    const content_width = eventContentWidth(geom);

    for (session.events.items) |event| {
        const visual_rows = eventVisualRows(event, content_width);
        if (skipped + visual_rows <= scroll_row) {
            skipped += visual_rows;
            continue;
        }

        var event_row_offset = scroll_row -| skipped;
        while (event_row_offset < visual_rows and drawn < rows) : (event_row_offset += 1) {
            const row = start_row + drawn;
            popup.drawPickerRow(screen, row, geom.col, geom.width, .command_popup_border, .command_popup);
            renderEventVisualRow(screen, row, geom, event, event_row_offset);
            drawn += 1;
        }
        skipped += visual_rows;
        if (drawn >= rows) break;
    }
}

fn renderEventVisualRow(
    screen: *render_mod.VirtualScreen,
    row: usize,
    geom: popup.FilesystemPickerGeometry,
    event: agent.AgentEvent,
    visual_row: usize,
) void {
    var col = geom.col + 2;
    const end = geom.col + geom.width - 1;
    const prefix_width = eventPrefixWidth(event);
    const text_width = @max(@as(usize, 1), eventContentWidth(geom) -| prefix_width);
    if (visual_row == 0) {
        popup.writeVirtualTruncatedCells(screen, row, &col, end, event.kind.label(), eventStyle(event.kind), false);
        popup.writeVirtualTruncatedCells(screen, row, &col, end, ": ", .explorer_dim, false);
    } else {
        writeSpaces(screen, row, &col, end, prefix_width, .explorer_dim);
    }
    const line = promptVisualSliceAt(event.text, text_width, visual_row);
    popup.writeVirtualTruncatedCells(screen, row, &col, end, line, eventStyle(event.kind), true);
}

fn writeSpaces(
    screen: *render_mod.VirtualScreen,
    row: usize,
    col: *usize,
    end: usize,
    count: usize,
    style: render_mod.RenderStyle,
) void {
    var remaining = count;
    while (remaining > 0 and col.* <= end) : (remaining -= 1) {
        popup.writeVirtualTruncatedCells(screen, row, col, end, " ", style, false);
    }
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

fn auditStyle(kind: anytype) render_mod.RenderStyle {
    return switch (kind) {
        .tool_denied, .tool_failed, .policy_violation, .approval_denied => .git_diff_deleted,
        .tool_allowed, .tool_completed, .approval_approved, .proposal_applied, .validation_completed => .git_diff_added,
        .approval_requested, .validation_requested, .tool_requested, .proposal_created => .git_diff_modified,
        .session_cancelled => .explorer_dim,
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

fn workspaceName(summary: []const u8) []const u8 {
    const prefix = "Workspace root: ";
    const line = firstLine(summary);
    if (!std.mem.startsWith(u8, line, prefix)) return "workspace";
    const root = line[prefix.len..];
    const base = std.fs.path.basename(root);
    return if (base.len > 0) base else root;
}

fn firstLine(text: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, text, '\n')) |index| return text[0..index];
    return text;
}

fn countSummaryLines(text: []const u8) usize {
    if (text.len == 0 or
        std.mem.eql(u8, text, "No changed files.") or
        std.mem.eql(u8, text, "Not a Git repository."))
        return 0;
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.trim(u8, line, " \t\r").len > 0) count += 1;
    }
    return count;
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
