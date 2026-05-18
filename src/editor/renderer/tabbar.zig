const std = @import("std");
const render_mod = @import("virtual_screen.zig");
const tab_mod = @import("../model/tab.zig");

const Tab = tab_mod.Tab;
const tab_prefix_width = 2;
const tab_separator = " | ";
const horizontal_line = "─";

pub const TabBarLayout = struct {
    total_width: usize,
    scroll_col: usize,
    content_start_col: usize,
    content_width: usize,
    has_hidden_left: bool,
    has_hidden_right: bool,
};

pub const TabLabel = struct {
    parent: ?[]const u8,
    basename: []const u8,
    len: usize,
};

pub fn getTabLabel(tabs: []const Tab, tab: *const Tab) TabLabel {
    const filename = tab.buf.filename orelse "unsaved";
    const basename = std.fs.path.basename(filename);
    var has_duplicate = false;
    for (tabs) |*other_tab| {
        if (other_tab == tab) continue;
        const other_filename = other_tab.buf.filename orelse "unsaved";
        if (std.mem.eql(u8, std.fs.path.basename(other_filename), basename)) {
            has_duplicate = true;
            break;
        }
    }
    var parent: ?[]const u8 = null;
    var len = basename.len;
    if (has_duplicate and tab.buf.filename != null) {
        if (std.fs.path.dirname(filename)) |dir| {
            parent = std.fs.path.basename(dir);
            len += parent.?.len + 1; // +1 for the separator '/'
        }
    }
    return .{ .parent = parent, .basename = basename, .len = len };
}

pub fn tabLabelWidth(tabs: []const Tab, tab: *const Tab) usize {
    const label = getTabLabel(tabs, tab);
    var width = tab_prefix_width + label.len + tab_separator.len;
    if (tab.buf.is_dirty) width += 2;
    return width;
}

pub fn totalTabBarWidth(tabs: []const Tab) usize {
    var total: usize = 0;
    for (tabs) |*tab| total += tabLabelWidth(tabs, tab);
    return total;
}

pub fn tabStartCol(tabs: []const Tab, index: usize) usize {
    var start: usize = 0;
    for (tabs[0..index]) |*tab| start += tabLabelWidth(tabs, tab);
    return start;
}

pub fn clampTabBarScroll(scroll_col: *usize, total_width: usize, available_width: usize) void {
    if (available_width == 0 or total_width <= available_width) {
        scroll_col.* = 0;
        return;
    }
    scroll_col.* = @min(scroll_col.*, total_width - available_width);
}

pub fn ensureActiveTabVisible(tabs: []const Tab, active_index: usize, available_width: usize, scroll_col: *usize) void {
    if (tabs.len == 0 or available_width == 0 or active_index >= tabs.len) {
        scroll_col.* = 0;
        return;
    }

    const total_width = totalTabBarWidth(tabs);
    clampTabBarScroll(scroll_col, total_width, available_width);

    const active_start = tabStartCol(tabs, active_index);
    const active_end = active_start + tabLabelWidth(tabs, &tabs[active_index]);
    if (active_start < scroll_col.*) {
        scroll_col.* = active_start;
    } else if (active_end > scroll_col.* + available_width) {
        scroll_col.* = active_end - available_width;
    }

    clampTabBarScroll(scroll_col, total_width, available_width);
}

pub fn prepareTabBarLayout(tabs: []const Tab, active_tab_index: usize, width: usize, scroll_col: *usize) TabBarLayout {
    const total_width = totalTabBarWidth(tabs);
    if (tabs.len == 0 or width == 0) {
        scroll_col.* = 0;
        return .{
            .total_width = total_width,
            .scroll_col = 0,
            .content_start_col = 0,
            .content_width = 0,
            .has_hidden_left = false,
            .has_hidden_right = false,
        };
    }

    var has_hidden_left = scroll_col.* > 0;
    var has_hidden_right = false;
    var content_width = width;

    for (0..4) |_| {
        const reserved = @as(usize, @intFromBool(has_hidden_left)) + @as(usize, @intFromBool(has_hidden_right));
        content_width = width -| reserved;
        ensureActiveTabVisible(tabs, active_tab_index, content_width, scroll_col);

        const next_hidden_left = scroll_col.* > 0;
        const next_hidden_right = total_width > scroll_col.* + content_width;
        if (next_hidden_left == has_hidden_left and next_hidden_right == has_hidden_right) break;
        has_hidden_left = next_hidden_left;
        has_hidden_right = next_hidden_right;
    }

    const reserved = @as(usize, @intFromBool(has_hidden_left)) + @as(usize, @intFromBool(has_hidden_right));
    content_width = width -| reserved;
    ensureActiveTabVisible(tabs, active_tab_index, content_width, scroll_col);
    has_hidden_left = scroll_col.* > 0;
    has_hidden_right = total_width > scroll_col.* + content_width;

    return .{
        .total_width = total_width,
        .scroll_col = scroll_col.*,
        .content_start_col = @intFromBool(has_hidden_left),
        .content_width = content_width,
        .has_hidden_left = has_hidden_left,
        .has_hidden_right = has_hidden_right,
    };
}

pub fn writeVirtualClippedText(screen: *render_mod.VirtualScreen, row: usize, dest_base_col: usize, text_start_col: usize, viewport_start: usize, viewport_end: usize, text: []const u8, style: render_mod.RenderStyle) void {
    const text_end_col = text_start_col + text.len;
    const draw_start = @max(text_start_col, viewport_start);
    const draw_end = @min(text_end_col, viewport_end);
    if (draw_start >= draw_end) return;

    const skip = draw_start - text_start_col;
    const len = draw_end - draw_start;
    screen.writeText(row, dest_base_col + draw_start - viewport_start, text[skip .. skip + len], style);
}

pub fn writeVirtualClippedTabLabel(screen: *render_mod.VirtualScreen, tabs: []const Tab, row: usize, dest_base_col: usize, label_start_col: usize, viewport_start: usize, viewport_end: usize, tab: *const Tab, active: bool) void {
    const basename_style: render_mod.RenderStyle = if (active) .gutter_current else .dim;
    const prefix_style: render_mod.RenderStyle = .dim;

    const prefix = if (active) "> " else "  ";
    const label = getTabLabel(tabs, tab);
    var col = label_start_col;

    writeVirtualClippedText(screen, row, dest_base_col, col, viewport_start, viewport_end, prefix, basename_style);
    col += prefix.len;

    if (label.parent) |parent| {
        writeVirtualClippedText(screen, row, dest_base_col, col, viewport_start, viewport_end, parent, prefix_style);
        col += parent.len;
        writeVirtualClippedText(screen, row, dest_base_col, col, viewport_start, viewport_end, "/", prefix_style);
        col += 1;
    }

    writeVirtualClippedText(screen, row, dest_base_col, col, viewport_start, viewport_end, label.basename, basename_style);
    col += label.basename.len;

    if (tab.buf.is_dirty) {
        writeVirtualClippedText(screen, row, dest_base_col, col, viewport_start, viewport_end, " ●", .terminal_green);
        col += 2;
    }

    writeVirtualClippedText(screen, row, dest_base_col, col, viewport_start, viewport_end, tab_separator, .dim);
}

pub fn renderVirtualTabs(screen: *render_mod.VirtualScreen, tabs: []const Tab, active_tab_index: usize, scroll_col: *usize, row_width: usize, start_col: usize) void {
    if (row_width == 0) return;
    if (tabs.len == 0) {
        for (0..row_width) |offset| screen.setGlyph(1, start_col + offset, horizontal_line, .dim);
        return;
    }

    const layout = prepareTabBarLayout(tabs, active_tab_index, row_width, scroll_col);
    if (layout.has_hidden_left) {
        screen.set(0, start_col, '<', .dim);
    }
    if (layout.content_width > 0) {
        const viewport_start = layout.scroll_col;
        const viewport_end = viewport_start + layout.content_width;
        var label_start: usize = 0;
        for (tabs, 0..) |*tab, i| {
            const label_width = tabLabelWidth(tabs, tab);
            if (label_start >= viewport_end) break;
            if (label_start + label_width > viewport_start) {
                writeVirtualClippedTabLabel(screen, tabs, 0, start_col + layout.content_start_col, label_start, viewport_start, viewport_end, tab, i == active_tab_index);
            }
            label_start += label_width;
        }
    }
    if (layout.has_hidden_right) {
        screen.set(0, start_col + row_width - 1, '>', .dim);
    }

    for (0..row_width) |offset| screen.setGlyph(1, start_col + offset, horizontal_line, .dim);
}
