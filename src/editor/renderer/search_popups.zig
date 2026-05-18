const std = @import("std");
const global_search = @import("../global_search.zig");
const viewport_mod = @import("../navigation/viewport.zig");
const popup = @import("popup.zig");
const render_mod = @import("virtual_screen.zig");

const command_popup_title = " Cmdline ";
const global_search_popup_title = " Search ";

pub const GlobalSearchRenderRow = union(enum) {
    header: []const u8,
    path: usize,
    content: usize,
};

pub fn commandPopupGeometry(editor: anytype) ?popup.CommandPopupGeometry {
    const viewport = viewport_mod.bufferViewportGeometry(editor);
    return popup.popupGeometry(
        editor.height,
        viewport.start_col,
        viewport.width,
        editor.state.command_popup.visible,
        editor.state.command_popup.suggestions.items.len,
        editor.state.command_popup.input.items.len > 0,
        6,
    );
}

pub fn globalSearchPopupGeometry(editor: anytype) ?popup.CommandPopupGeometry {
    const render_row_count = globalSearchRenderRowCount(editor.state.global_search.results.items);
    const max_visible_items: usize = if (render_row_count > 6) 12 else 6;
    const viewport = viewport_mod.bufferViewportGeometry(editor);
    return popup.popupGeometry(
        editor.height,
        viewport.start_col,
        viewport.width,
        editor.state.global_search.visible,
        render_row_count,
        editor.state.global_search.input.items.len > 0,
        max_visible_items,
    );
}

pub fn isSameContentDisplayPath(a: global_search.GlobalSearchResult, b: global_search.GlobalSearchResult) bool {
    return switch (a) {
        .content => |a_content| switch (b) {
            .content => |b_content| std.mem.eql(u8, a_content.display_path, b_content.display_path),
            .path => false,
        },
        .path => false,
    };
}

pub fn globalSearchRenderRowCount(results: []const global_search.GlobalSearchResult) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i < results.len) {
        switch (results[i]) {
            .path => {
                count += 1;
                i += 1;
            },
            .content => {
                const group_start = i;
                count += 1; // file header
                while (i < results.len and isSameContentDisplayPath(results[i], results[group_start])) : (i += 1) {
                    count += 1;
                }
            },
        }
    }
    return count;
}

pub fn globalSearchRenderRowAt(results: []const global_search.GlobalSearchResult, render_row: usize) ?GlobalSearchRenderRow {
    var row: usize = 0;
    var i: usize = 0;
    while (i < results.len) {
        switch (results[i]) {
            .path => {
                if (row == render_row) return .{ .path = i };
                row += 1;
                i += 1;
            },
            .content => |content| {
                const group_path = content.display_path;
                if (row == render_row) return .{ .header = group_path };
                row += 1;
                while (i < results.len) : (i += 1) {
                    switch (results[i]) {
                        .content => |group_content| {
                            if (!std.mem.eql(u8, group_content.display_path, group_path)) break;
                            if (row == render_row) return .{ .content = i };
                            row += 1;
                        },
                        .path => break,
                    }
                }
            },
        }
    }
    return null;
}

pub fn selectedGlobalSearchRenderRow(results: []const global_search.GlobalSearchResult, selected_index: ?usize) ?usize {
    const selected = selected_index orelse return null;
    var row: usize = 0;
    var i: usize = 0;
    while (i < results.len) {
        switch (results[i]) {
            .path => {
                if (i == selected) return row;
                row += 1;
                i += 1;
            },
            .content => |content| {
                const group_path = content.display_path;
                row += 1; // header
                while (i < results.len) : (i += 1) {
                    switch (results[i]) {
                        .content => |group_content| {
                            if (!std.mem.eql(u8, group_content.display_path, group_path)) break;
                            if (i == selected) return row;
                            row += 1;
                        },
                        .path => break,
                    }
                }
            },
        }
    }
    return null;
}

pub fn adjustGlobalSearchRenderScroll(editor: anytype, view_height: usize) void {
    if (view_height == 0) return;
    const total_rows = globalSearchRenderRowCount(editor.state.global_search.results.items);
    if (total_rows == 0) {
        editor.state.global_search.scroll_offset = 0;
        return;
    }
    if (editor.state.global_search.scroll_offset >= total_rows) {
        editor.state.global_search.scroll_offset = total_rows - 1;
    }
    const selected_row = selectedGlobalSearchRenderRow(editor.state.global_search.results.items, editor.state.global_search.selected_index) orelse return;
    if (selected_row < editor.state.global_search.scroll_offset) {
        editor.state.global_search.scroll_offset = selected_row;
    } else if (selected_row >= editor.state.global_search.scroll_offset + view_height) {
        editor.state.global_search.scroll_offset = selected_row - view_height + 1;
    }
}

pub fn renderVirtualCommandPopup(editor: anytype) void {
    const geom = commandPopupGeometry(editor) orelse return;
    const popup_state = &editor.state.command_popup;
    const inner_width = geom.width - 2;

    popup.drawVirtualPopupTop(&editor.renderer.screen, geom, command_popup_title, .command_popup_border);

    const input_row = geom.row + 1;
    popup.drawVirtualPopupRow(&editor.renderer.screen, input_row, geom.col, geom.width, .command_popup_border, .command_popup);
    editor.renderer.screen.writeText(input_row, geom.col + 2, ">", .command_popup_prompt);
    const input_space = inner_width -| 3;
    const shown_input = popup_state.input.items[0..@min(popup_state.input.items.len, input_space)];
    editor.renderer.screen.writeText(input_row, geom.col + 4, shown_input, .command_popup);

    const separator_row = geom.row + 2;
    popup.drawVirtualPopupSeparator(&editor.renderer.screen, separator_row, geom.col, geom.width, .command_popup_border);

    for (0..geom.suggestion_count) |i| {
        const row = geom.row + 3 + i;
        const style: render_mod.RenderStyle = if (popup_state.selected_index != null and popup_state.selected_index.? == i)
            .command_popup_selected
        else
            .command_popup;
        popup.drawVirtualPopupRow(&editor.renderer.screen, row, geom.col, geom.width, .command_popup_border, style);
        var suggestion_buf: [128]u8 = undefined;
        const suggestion = popup_state.suggestions.items[i].displayText(&suggestion_buf);
        const shown = suggestion[0..@min(suggestion.len, inner_width -| 2)];
        editor.renderer.screen.writeText(row, geom.col + 2, shown, style);
    }

    const bottom_row = geom.row + 3 + geom.suggestion_count;
    popup.drawVirtualPopupBottom(&editor.renderer.screen, bottom_row, geom.col, geom.width, .command_popup_border);
}

pub fn globalSearchFileStyle(selected: bool) render_mod.RenderStyle {
    return if (selected) .global_search_file_selected else .global_search_file;
}

pub fn globalSearchResultStyle(selected: bool) render_mod.RenderStyle {
    return if (selected) .global_search_result_selected else .global_search_result;
}

pub fn renderVirtualGlobalSearchRowText(editor: anytype, row: usize, start_col: usize, end_col: usize, render_row: GlobalSearchRenderRow, results: []const global_search.GlobalSearchResult, selected: bool) void {
    var col = start_col;
    switch (render_row) {
        .header => |display_path| {
            popup.writeVirtualTruncated(&editor.renderer.screen, row, &col, end_col, display_path, globalSearchFileStyle(false));
        },
        .path => |result_index| {
            const path = results[result_index].path;
            popup.writeVirtualTruncated(&editor.renderer.screen, row, &col, end_col, path.display_path, globalSearchFileStyle(selected));
        },
        .content => |result_index| {
            const content = results[result_index].content;
            const style = globalSearchResultStyle(selected);
            popup.writeVirtualTruncated(&editor.renderer.screen, row, &col, end_col, "  ", style);
            var location_buf: [48]u8 = undefined;
            const location = std.fmt.bufPrint(&location_buf, "{d}:{d}  ", .{ content.row + 1, content.col + 1 }) catch "";
            popup.writeVirtualTruncated(&editor.renderer.screen, row, &col, end_col, location, style);
            popup.writeVirtualTruncated(&editor.renderer.screen, row, &col, end_col, content.snippet, style);
        },
    }
}

pub fn renderVirtualGlobalSearchPopup(editor: anytype) void {
    const geom = globalSearchPopupGeometry(editor) orelse return;
    const popup_state = &editor.state.global_search;
    const inner_width = geom.width - 2;

    popup.drawVirtualPopupTop(&editor.renderer.screen, geom, global_search_popup_title, .global_search_popup_border);

    const input_row = geom.row + 1;
    popup.drawVirtualPopupRow(&editor.renderer.screen, input_row, geom.col, geom.width, .global_search_popup_border, .command_popup);
    editor.renderer.screen.writeText(input_row, geom.col + 2, ">", .command_popup_prompt);
    const input_space = inner_width -| 3;
    const shown_input = popup_state.input.items[0..@min(popup_state.input.items.len, input_space)];
    editor.renderer.screen.writeText(input_row, geom.col + 4, shown_input, .command_popup);

    const separator_row = geom.row + 2;
    popup.drawVirtualPopupSeparator(&editor.renderer.screen, separator_row, geom.col, geom.width, .global_search_popup_border);

    adjustGlobalSearchRenderScroll(editor, geom.suggestion_count);
    for (0..geom.suggestion_count) |offset| {
        const render_row_index = editor.state.global_search.scroll_offset + offset;
        const render_row = globalSearchRenderRowAt(popup_state.results.items, render_row_index) orelse break;
        const row = geom.row + 3 + offset;
        const selected = switch (render_row) {
            .path => |result_index| popup_state.selected_index != null and popup_state.selected_index.? == result_index,
            .content => |result_index| popup_state.selected_index != null and popup_state.selected_index.? == result_index,
            .header => false,
        };
        const style: render_mod.RenderStyle = if (selected)
            .command_popup_selected
        else
            .command_popup;
        popup.drawVirtualPopupRow(&editor.renderer.screen, row, geom.col, geom.width, .global_search_popup_border, style);
        renderVirtualGlobalSearchRowText(editor, row, geom.col + 2, geom.col + geom.width - 1, render_row, popup_state.results.items, selected);
    }

    const bottom_row = geom.row + 3 + geom.suggestion_count;
    popup.drawVirtualPopupBottom(&editor.renderer.screen, bottom_row, geom.col, geom.width, .global_search_popup_border);
}
