const perf = @import("../../perf/perf.zig");
const syntax = @import("../syntax.zig");
const editor_syntax = @import("../syntax_editor.zig");
const comments = @import("../comments.zig");
const viewport_mod = @import("../navigation/viewport.zig");
const tab_mod = @import("../model/tab.zig");
const tabbar = @import("tabbar.zig");
const line_render = @import("line_render.zig");
const search_popups = @import("search_popups.zig");
const picker_help_popups = @import("picker_help_popups.zig");
const prompt_save_popups = @import("prompt_save_popups.zig");
const completion_menu = @import("completion_menu.zig");
const statusline = @import("statusline.zig");
const terminal_panel_view = @import("terminal_panel_view.zig");
const todo_panel_view = @import("todo_panel_view.zig");
const comments_panel_view = @import("comments_panel_view.zig");
const git_graph_panel_view = @import("git_graph_panel_view.zig");
const git_diff_panel_view = @import("git_diff_panel_view.zig");
const task_panel_view = @import("task_panel_view.zig");
const agent_panel_view = @import("agent_panel_view.zig");

pub const RenderContext = struct {
    tab: ?*tab_mod.Tab,
    buf_start_col: usize,
    buf_width: usize,
    gutter_width: usize,
    visible_rows: usize,
};

pub fn buildRenderContext(editor: anytype, status_buf: *[160]u8) RenderContext {
    const tab = editor.currentTab();
    const viewport = viewport_mod.bufferViewportGeometry(editor);
    const gutter_width: usize = if (tab) |t|
        editor.calculateGutterWidth(t.buf.lines.items.len)
    else
        0;
    const visible_rows = viewport_mod.editorVisibleRows(editor);

    _ = status_buf;

    return .{
        .tab = tab,
        .buf_start_col = viewport.start_col,
        .buf_width = viewport.width,
        .gutter_width = gutter_width,
        .visible_rows = visible_rows,
    };
}

pub fn renderVirtual(editor: anytype, writer: anytype, metrics: *perf.FrameMetrics) !void {
    if (try editor.renderer.screen.resize(editor.width, editor.height)) {
        editor.renderer.screen_renderer.invalidate(.full);
    }
    editor.renderer.screen.clear();

    var status_buf: [160]u8 = undefined;
    const ctx = buildRenderContext(editor, &status_buf);

    if (editor.state.mode == .Dashboard or editor.state.mode == .OpenFilePrompt or editor.state.mode == .FilesystemPicker or
        (editor.state.mode == .Help and editor.state.tabs.items.len == 0))
    {
        editor.state.dash.renderToScreen(&editor.renderer.screen);
    } else {
        renderVirtualExplorer(editor);
        todo_panel_view.renderVirtualTodoPanel(editor);
        comments_panel_view.renderVirtualCommentsPanel(editor);

        const tabs_start = if (editor.active_keypress_trace != null) perf.nowNs() else 0;
        renderVirtualTabs(editor, ctx);
        if (editor.active_keypress_trace) |trace| trace.tabs_ns += perf.elapsedNs(tabs_start);

        if (ctx.tab) |t| {
            t.scroll_row = t.buf.clampToVisibleLine(t.scroll_row);
            if (t.buf.filename) |filename| {
                comments.validateAnchorsForFile(&editor.state.comments_panel.store, editor.state.workspace.root_path, filename, &t.buf);
            }
            const highlight_start = perf.nowNs();
            const syntax_end = viewport_mod.visibleViewportEndLine(t, t.scroll_row, ctx.visible_rows + 20);
            editor_syntax.prepareSyntaxForViewport(editor, t, t.scroll_row, syntax_end, 20) catch {
                if (editor.active_keypress_trace) |trace| trace.syntax_cache = syntax.ViewportCacheStatus.unknown.name();
            };
            const highlight_elapsed = perf.elapsedNs(highlight_start);
            metrics.add(.highlight_viewport, highlight_elapsed);
            if (editor.active_keypress_trace) |trace| trace.highlight_ns += highlight_elapsed;

            const visible_lines_start = if (editor.active_keypress_trace != null) perf.nowNs() else 0;
            var buffer_line_idx = t.scroll_row;
            for (0..ctx.visible_rows) |screen_row| {
                const row = screen_row + 2;
                if (buffer_line_idx >= t.buf.lines.items.len) break;
                line_render.renderVirtualLine(editor, t, buffer_line_idx, row, ctx);
                const next = t.buf.nextVisibleLine(buffer_line_idx);
                if (next == buffer_line_idx) break;
                buffer_line_idx = next;
            }
            if (editor.active_keypress_trace) |trace| trace.visible_lines_ns += perf.elapsedNs(visible_lines_start);
        }
    }

    const popup_start = if (editor.active_keypress_trace != null) perf.nowNs() else 0;
    search_popups.renderVirtualCommandPopup(editor);
    search_popups.renderVirtualGlobalSearchPopup(editor);
    picker_help_popups.renderVirtualFilesystemPickerPopup(editor);
    prompt_save_popups.renderVirtualPromptPopup(editor);
    prompt_save_popups.renderVirtualSaveConfirmationPopup(editor);
    picker_help_popups.renderVirtualHelpPopup(editor);
    git_graph_panel_view.renderVirtualGitGraphPanel(editor);
    git_diff_panel_view.renderVirtualGitDiffPanel(editor);
    task_panel_view.renderVirtualTaskPanel(editor);
    agent_panel_view.renderVirtualAgentPanel(editor);
    completion_menu.renderVirtualCompletionMenu(editor);
    if (editor.active_keypress_trace) |trace| trace.popup_ns += perf.elapsedNs(popup_start);
    const status_start = if (editor.active_keypress_trace != null) perf.nowNs() else 0;
    statusline.renderVirtualStatus(editor, ctx, viewport_mod.statusRowIndex(editor));
    if (editor.active_keypress_trace) |trace| trace.status_ns += perf.elapsedNs(status_start);
    terminal_panel_view.renderVirtualTerminalPanel(editor);
    setVirtualCursor(editor, ctx);
    const emit_start = if (editor.active_keypress_trace != null) perf.nowNs() else 0;
    const emit_bytes = try editor.renderer.screen_renderer.emit(writer, &editor.renderer.screen);
    if (editor.active_keypress_trace) |trace| {
        trace.virtual_emit_ns += perf.elapsedNs(emit_start);
        trace.virtual_emit_bytes += emit_bytes;
    }
}

pub fn renderVirtualExplorer(editor: anytype) void {
    if (!editor.state.explorer_visible or editor.state.tree == null or editor.width == 0 or editor.height < 2) return;
    const exp_width = (editor.width * @as(usize, editor.config.explorer.width_percentage)) / 100;
    if (exp_width == 0) return;
    editor.state.tree.?.renderAt(&editor.renderer.screen, exp_width, editor.height - 1, 1, 0, editor.state.explorer_focused, if (editor.state.git_snapshot) |*s| s else null, editor.icons);
    const divider_col = exp_width;
    if (divider_col < editor.width) {
        for (1..editor.height) |row| {
            editor.renderer.screen.writeText(row, divider_col, "│", .dim);
        }
    }
}

pub fn setVirtualCursor(editor: anytype, ctx: RenderContext) void {
    if (editor.state.mode == .Command) {
        if (search_popups.commandPopupGeometry(editor)) |geom| {
            const input_space = geom.width -| 5;
            const cursor_col = @min(editor.state.command_popup.input.items.len, input_space);
            editor.renderer.screen.setCursor(geom.row + 2, geom.col + 5 + cursor_col);
        }
        return;
    }
    if (editor.state.mode == .GlobalSearch) {
        if (search_popups.globalSearchPopupGeometry(editor)) |geom| {
            const input_space = geom.width -| 5;
            const cursor_col = @min(editor.state.global_search.input.items.len, input_space);
            editor.renderer.screen.setCursor(geom.row + 2, geom.col + 5 + cursor_col);
        }
        return;
    }
    if (editor.state.mode == .Search) {
        editor.renderer.screen.setCursor(viewport_mod.statusTerminalRow(editor), 2 + editor.state.search_buffer.items.len);
        return;
    }
    if (editor.state.mode == .OpenFilePrompt) {
        editor.renderer.screen.setCursor(viewport_mod.statusTerminalRow(editor), @min(editor.width, 12 + editor.state.command_buffer.items.len));
        return;
    }
    if (editor.state.mode == .FilesystemPicker or editor.state.mode == .Prompt or editor.state.mode == .Help or editor.state.mode == .GitGraph or editor.state.mode == .GitDiff or editor.state.mode == .TaskPanel or editor.state.mode == .Agent or
        editor.state.mode == .Dashboard or editor.state.mode == .SaveConfirmation)
    {
        editor.renderer.screen.hideCursor();
        return;
    }
    if (editor.state.explorer_focused and editor.state.explorer_visible and editor.state.tree != null) {
        editor.renderer.screen.hideCursor();
        return;
    }
    if (editor.state.todo_panel.visible and editor.state.todo_panel.focused) {
        editor.renderer.screen.hideCursor();
        return;
    }
    if (editor.state.comments_panel.visible and editor.state.comments_panel.focused) {
        editor.renderer.screen.hideCursor();
        return;
    }
    if (editor.state.mode == .Terminal) {
        const pos = terminal_panel_view.terminalCursorScreenPosition(editor);
        editor.renderer.screen.setCursor(pos.row, pos.col);
        return;
    }

    const t = ctx.tab orelse {
        editor.renderer.screen.hideCursor();
        return;
    };
    const content_width = ctx.buf_width -| ctx.gutter_width;
    const mc = t.mainCursor();
    const vis_col = viewport_mod.visibleCursorCol(mc.col, t.scroll_col, content_width);
    const vis_row = if (viewport_mod.visibleLineOffset(t, t.scroll_row, mc.row, ctx.visible_rows)) |offset| offset + 3 else 3;
    editor.renderer.screen.setCursor(vis_row, ctx.buf_start_col + ctx.gutter_width + vis_col);
}

fn renderVirtualTabs(editor: anytype, ctx: RenderContext) void {
    if (editor.height == 0 or ctx.buf_width == 0) return;
    const start_col = ctx.buf_start_col -| 1;
    tabbar.renderVirtualTabs(&editor.renderer.screen, editor.state.tabs.items, editor.state.active_tab_index, &editor.state.tab_bar_scroll_col, ctx.buf_width, start_col);
}
