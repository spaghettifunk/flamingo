const std = @import("std");
const render_mod = @import("virtual_screen.zig");
const file_icons = @import("../file_icons.zig");
const tab_mod = @import("../model/tab.zig");

const Tab = tab_mod.Tab;

pub const StatusFieldCache = struct {
    terminal_col: usize = 0,
    width: usize = 0,
    valid: bool = false,
};

pub const StatusLayoutCache = struct {
    width: usize = 0,
    height: usize = 0,
    cursor: StatusFieldCache = .{},
    percent: StatusFieldCache = .{},
    last_cursor_row: usize = 0,
    last_cursor_col: usize = 0,
    last_percent: usize = 0,
    valid: bool = false,

    pub fn invalidate(self: *StatusLayoutCache) void {
        self.* = .{};
    }
};

pub const RightStatusLayout = struct {
    text: []const u8,
    cursor_offset: usize = 0,
    cursor_width: usize = 0,
    cursor_valid: bool = false,
    percent_offset: usize = 0,
    percent_width: usize = 0,
    percent_valid: bool = false,
    cursor_row: usize = 0,
    cursor_col: usize = 0,
    percent: usize = 0,
};

pub fn buildStatusText(editor: anytype, tab: ?*Tab, buf: *[160]u8) ![]const u8 {
    if (editor.state.mode == .Search) {
        if (editor.state.search_system) |s| {
            if (s.matches.items.len > 0) {
                return try std.fmt.bufPrint(buf, "/{s} ({d}/{d})", .{ editor.state.search_buffer.items, (s.active_match_idx orelse 0) + 1, s.matches.items.len });
            }
            return try std.fmt.bufPrint(buf, "/{s} (no matches)", .{editor.state.search_buffer.items});
        }
        return try std.fmt.bufPrint(buf, "/{s}", .{editor.state.search_buffer.items});
    }
    if (editor.state.error_message) |err_msg| {
        return try std.fmt.bufPrint(buf, "{s}", .{err_msg});
    }
    if (editor.state.status_message) |msg| {
        return try std.fmt.bufPrint(buf, "{s}", .{msg});
    }

    const mode_str = switch (editor.state.mode) {
        .Command => "COMMAND",
        .GlobalSearch => "GLOBAL SEARCH",
        .GitGraph => "GIT",
        .GitDiff => "GIT DIFF",
        .TaskPanel => "TASKS",
        .Agent => "AGENT",
        .Proposals => "PROPOSALS",
        .Help => "HELP",
        .FilesystemPicker => "FILES",
        .Prompt => "PROMPT",
        .Insert => "INSERT",
        .Search => "SEARCH",
        .Terminal => "TERMINAL",
        else => "NORMAL",
    };
    if (tab) |t| {
        const diag_count = if (t.buf.filename) |fname| editor.state.lsp_ui.diagnosticCountForFile(fname) else 0;
        if (diag_count > 0) {
            return try std.fmt.bufPrint(buf, " {s}  {s} {d}  {d}:{d} ", .{ mode_str, editor.icons.error_icon, diag_count, t.mainCursor().row + 1, t.mainCursor().col + 1 });
        }
        return try std.fmt.bufPrint(buf, " {s}  {d}:{d} ", .{ mode_str, t.mainCursor().row + 1, t.mainCursor().col + 1 });
    }
    return try std.fmt.bufPrint(buf, " {s}  No file open ", .{mode_str});
}

pub fn statusModeLabel(editor: anytype) []const u8 {
    return switch (editor.state.mode) {
        .Insert => "INSERT",
        .Command => "COMMAND",
        .Search => "SEARCH",
        .GlobalSearch => "GLOBAL",
        .GitGraph => "GIT",
        .GitDiff => "DIFF",
        .TaskPanel => "TASKS",
        .Agent => "AGENT",
        .Proposals => "PROPS",
        .Help => "HELP",
        .FilesystemPicker => "FILES",
        .Prompt => "PROMPT",
        .Terminal => "TERM",
        else => "NORMAL",
    };
}

pub fn statusModeStyle(editor: anytype) render_mod.RenderStyle {
    return switch (editor.state.mode) {
        .Insert => .status_mode_insert,
        .Command, .FilesystemPicker, .Prompt, .Help, .Terminal, .GitGraph, .GitDiff, .TaskPanel, .Agent, .Proposals => .status_mode_command,
        .Search, .GlobalSearch => .status_mode_search,
        else => .status_mode_normal,
    };
}

pub fn statusModeSepStyle(editor: anytype) render_mod.RenderStyle {
    return switch (editor.state.mode) {
        .Insert => .status_sep_insert,
        .Command, .FilesystemPicker, .Prompt, .Help, .Terminal, .GitGraph, .GitDiff, .TaskPanel, .Agent => .status_sep_command,
        .Search, .GlobalSearch => .status_sep_search,
        else => .status_sep_normal,
    };
}

pub fn fileIconForName(editor: anytype, name: []const u8) []const u8 {
    return file_icons.iconForFileName(editor.icons, name);
}

pub fn statusFilePath(editor: anytype, tab: ?*Tab) []const u8 {
    var filename = if (tab) |t| t.buf.filename orelse "unsaved" else "No file";
    if (editor.state.git_snapshot) |snapshot| {
        if (snapshot.root_path) |root| {
            if (std.mem.startsWith(u8, filename, root)) {
                var rel = filename[root.len..];
                if (rel.len > 0 and (rel[0] == '/' or rel[0] == std.fs.path.sep)) rel = rel[1..];
                if (rel.len > 0) return rel;
            }
        }
    }
    while (std.mem.startsWith(u8, filename, "./")) filename = filename[2..];
    return filename;
}

pub fn statusContext(editor: anytype) ?[]const u8 {
    if (editor.state.mode == .Prompt) return @tagName(editor.state.prompt_popup.kind);
    if (editor.state.mode == .Command) return "command";
    if (editor.state.mode == .GitGraph) return "git_graph";
    if (editor.state.mode == .GitDiff) return "git_diff";
    if (editor.state.mode == .TaskPanel) return "tasks";
    if (editor.state.mode == .Agent) return "agent";
    if (editor.state.mode == .Proposals) return "proposals";
    if (editor.state.mode == .Help) return "help";
    if (editor.state.mode == .Search) return "search";
    if (editor.state.mode == .GlobalSearch) return "global_search";
    if (editor.terminal_panel.visible) return if (editor.terminal_panel.focused) "terminal focused" else "terminal";
    return null;
}

pub fn currentMinute(editor: anytype) i64 {
    const ns = std.Io.Timestamp.now(editor.io, .real).nanoseconds;
    return @intCast(@divTrunc(ns, std.time.ns_per_min));
}

pub fn clockText(editor: anytype, buf: *[16]u8) []const u8 {
    const ns = std.Io.Timestamp.now(editor.io, .real).nanoseconds;
    const secs: u64 = @intCast(@max(@divTrunc(ns, std.time.ns_per_s), 0));
    const day = (std.time.epoch.EpochSeconds{ .secs = secs }).getDaySeconds();
    return std.fmt.bufPrint(buf, "{s} {d:0>2}:{d:0>2}", .{ editor.icons.clock, day.getHoursIntoDay(), day.getMinutesIntoHour() }) catch "@ --:--";
}

pub fn cacheRightStatusLayout(editor: anytype, right: RightStatusLayout, text_start_terminal_col: usize, text_available: usize) void {
    editor.status_cache = .{
        .width = editor.width,
        .height = editor.height,
        .last_cursor_row = right.cursor_row,
        .last_cursor_col = right.cursor_col,
        .last_percent = right.percent,
        .valid = true,
    };
    if (right.cursor_valid and right.cursor_offset + right.cursor_width <= text_available) {
        editor.status_cache.cursor = .{
            .terminal_col = text_start_terminal_col + right.cursor_offset,
            .width = right.cursor_width,
            .valid = true,
        };
    }
    if (right.percent_valid and right.percent_offset + right.percent_width <= text_available) {
        editor.status_cache.percent = .{
            .terminal_col = text_start_terminal_col + right.percent_offset,
            .width = right.percent_width,
            .valid = true,
        };
    }
}

pub fn buildRightStatus(editor: anytype, tab: ?*Tab, buf: *[192]u8) ![]const u8 {
    return (try buildRightStatusLayout(editor, tab, buf)).text;
}

pub fn buildRightStatusLayout(editor: anytype, tab: ?*Tab, buf: *[192]u8) !RightStatusLayout {
    const cursor_field_width = 12;
    const percent_field_width = 4;

    var layout = RightStatusLayout{ .text = "" };
    var idx: usize = 0;
    var cells: usize = 0;

    var clock_buf: [16]u8 = undefined;
    const clock = clockText(editor, &clock_buf);
    if (tab) |t| {
        const mc = t.mainCursor();
        const total_lines = t.buf.lines.items.len;
        const pct = statusScrollPercent(mc.row, total_lines);
        const diag_count = if (t.buf.filename) |fname| editor.state.lsp_ui.diagnosticCountForFile(fname) else 0;
        if (diag_count > 0) {
            try appendStatusFmt(buf, &idx, &cells, " {s} {d}  ", .{ editor.icons.error_icon, diag_count });
        }
        try appendStatusFmt(buf, &idx, &cells, "{s} {d}  ", .{ editor.icons.line_count, total_lines });

        layout.percent_offset = cells;
        layout.percent_width = percent_field_width;
        layout.percent_valid = true;
        layout.percent = pct;
        try appendStatusFieldFmt(buf, &idx, &cells, percent_field_width, "{d}%", .{pct});
        try appendStatusText(buf, &idx, &cells, "  ");

        layout.cursor_offset = cells;
        layout.cursor_width = cursor_field_width;
        layout.cursor_valid = true;
        layout.cursor_row = mc.row;
        layout.cursor_col = mc.col;
        try appendStatusFieldFmt(buf, &idx, &cells, cursor_field_width, "{d}:{d}", .{ mc.row + 1, mc.col + 1 });
        try appendStatusFmt(buf, &idx, &cells, "  {s} ", .{clock});

        layout.text = buf[0..idx];
        return layout;
    }
    try appendStatusFmt(buf, &idx, &cells, " {s} ", .{clock});
    layout.text = buf[0..idx];
    return layout;
}

pub fn appendStatusText(buf: *[192]u8, idx: *usize, cells: *usize, text: []const u8) !void {
    if (idx.* + text.len > buf.len) return error.NoSpaceLeft;
    @memcpy(buf[idx.* .. idx.* + text.len], text);
    idx.* += text.len;
    cells.* += render_mod.displayCellCount(text);
}

pub fn appendStatusFmt(buf: *[192]u8, idx: *usize, cells: *usize, comptime fmt: []const u8, args: anytype) !void {
    const part = try std.fmt.bufPrint(buf[idx.*..], fmt, args);
    idx.* += part.len;
    cells.* += render_mod.displayCellCount(part);
}

pub fn appendStatusFieldFmt(buf: *[192]u8, idx: *usize, cells: *usize, width: usize, comptime fmt: []const u8, args: anytype) !void {
    const part = try std.fmt.bufPrint(buf[idx.*..], fmt, args);
    idx.* += part.len;
    const part_cells = render_mod.displayCellCount(part);
    cells.* += part_cells;
    if (part_cells < width) {
        const pad = width - part_cells;
        if (idx.* + pad > buf.len) return error.NoSpaceLeft;
        @memset(buf[idx.* .. idx.* + pad], ' ');
        idx.* += pad;
        cells.* += pad;
    }
}

pub fn statusScrollPercent(row: usize, total_lines: usize) usize {
    if (total_lines <= 1) return 100;
    return @min(@as(usize, 100), ((row + 1) * 100) / total_lines);
}

pub fn renderVirtualStatus(editor: anytype, ctx: anytype, row: usize) void {
    if (editor.height == 0 or (editor.state.mode == .Dashboard and editor.state.error_message == null and editor.state.status_message == null)) return;
    editor.renderer.screen.fillRow(row, ' ', .status_bg);

    var col: usize = 0;
    writeVirtualStatusLeft(editor, row, &col, ctx.tab);

    var right_buf: [192]u8 = undefined;
    const right = buildRightStatusLayout(editor, ctx.tab, &right_buf) catch RightStatusLayout{ .text = "" };
    const right_cells = render_mod.displayCellCount(right.text) + 1;
    if (right_cells < editor.width) {
        const start = editor.width - right_cells;
        editor.renderer.screen.writeText(row, start, editor.icons.status_separator_left, .status_sep_right);
        editor.renderer.screen.writeText(row, start + 1, right.text, .status_right);
        cacheRightStatusLayout(editor, right, start + 2, right_cells - 1);
    } else {
        editor.status_cache.invalidate();
    }
}

pub fn searchCursorTerminalCol(editor: anytype) usize {
    const prefix_cells = render_mod.displayCellCount(" SEARCH ") +
        render_mod.displayCellCount(editor.icons.status_separator_right) +
        render_mod.displayCellCount(" ");
    return prefix_cells + render_mod.displayCellCount("/") + render_mod.displayCellCount(editor.state.search_buffer.items) + 1;
}

pub fn writeVirtualStatusText(editor: anytype, row: usize, col: *usize, text: []const u8, style: render_mod.RenderStyle) void {
    if (col.* >= editor.width) return;
    editor.renderer.screen.writeText(row, col.*, text, style);
    col.* += @min(render_mod.displayCellCount(text), editor.width - col.*);
}

pub fn writeVirtualStatusLeft(editor: anytype, row: usize, col: *usize, tab: ?*Tab) void {
    if (editor.state.error_message) |err| {
        writeVirtualStatusText(editor, row, col, " ERROR ", .status_error);
        writeVirtualStatusText(editor, row, col, editor.icons.status_separator_right, .status_sep_error);
        writeVirtualStatusText(editor, row, col, " ", .status_file);
        writeVirtualStatusText(editor, row, col, err, .status_file);
        return;
    }
    if (editor.state.status_message) |msg| {
        writeVirtualStatusText(editor, row, col, " STATUS ", .status_mode_normal);
        writeVirtualStatusText(editor, row, col, editor.icons.status_separator_right, .status_sep_normal);
        writeVirtualStatusText(editor, row, col, " ", .status_file);
        writeVirtualStatusText(editor, row, col, msg, .status_file);
        return;
    }
    if (editor.state.mode == .OpenFilePrompt) {
        writeVirtualStatusText(editor, row, col, " FILES ", .status_mode_command);
        writeVirtualStatusText(editor, row, col, editor.icons.status_separator_right, .status_sep_command);
        writeVirtualStatusText(editor, row, col, " Open file: ", .status_file);
        writeVirtualStatusText(editor, row, col, editor.state.command_buffer.items, .status_file);
        return;
    }
    if (editor.state.mode == .Search) {
        writeVirtualStatusText(editor, row, col, " SEARCH ", .status_mode_search);
        writeVirtualStatusText(editor, row, col, editor.icons.status_separator_right, .status_sep_search);
        writeVirtualStatusText(editor, row, col, " ", .status_file);
        var search_buf: [160]u8 = undefined;
        const search_text = buildStatusText(editor, tab, &search_buf) catch "/";
        writeVirtualStatusText(editor, row, col, search_text, .status_file);
        writeVirtualStatusText(editor, row, col, editor.icons.status_separator_right, .status_sep_file);
        return;
    }

    var mode_buf: [32]u8 = undefined;
    const mode = std.fmt.bufPrint(&mode_buf, " {s} ", .{statusModeLabel(editor)}) catch " NORMAL ";
    writeVirtualStatusText(editor, row, col, mode, statusModeStyle(editor));
    writeVirtualStatusText(editor, row, col, editor.icons.status_separator_right, statusModeSepStyle(editor));

    if (editor.state.git_snapshot) |snapshot| {
        if (snapshot.branch) |branch| {
            var branch_buf: [96]u8 = undefined;
            const branch_text = std.fmt.bufPrint(&branch_buf, " {s} {s} ", .{ editor.icons.git_branch, branch }) catch "";
            writeVirtualStatusText(editor, row, col, branch_text, .status_branch);
            writeVirtualStatusText(editor, row, col, editor.icons.status_separator_right, .status_sep_branch);
        }
    }

    var file_buf: [192]u8 = undefined;
    const file_path = statusFilePath(editor, tab);
    const file_text = std.fmt.bufPrint(&file_buf, " {s} {s} ", .{ fileIconForName(editor, file_path), file_path }) catch "";
    writeVirtualStatusText(editor, row, col, file_text, .status_file);

    if (statusContext(editor)) |context| {
        writeVirtualStatusText(editor, row, col, editor.icons.status_separator_right, .status_sep_file);
        var context_buf: [96]u8 = undefined;
        const context_text = std.fmt.bufPrint(&context_buf, " {s} {s} ", .{ editor.icons.context, context }) catch "";
        writeVirtualStatusText(editor, row, col, context_text, .status_context);
    }
    writeVirtualStatusText(editor, row, col, editor.icons.status_separator_right, .status_sep_context);
}
