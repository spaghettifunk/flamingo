const std = @import("std");
const builtin = @import("builtin");
const logz = @import("logz");
const render_mod = @import("renderer/virtual_screen.zig");
const git_status = @import("git_status.zig");
const file_icons = @import("file_icons.zig");
const icons_mod = @import("icons.zig");

pub const FileNode = struct {
    name: []const u8,
    absolute_path: []const u8,
    is_dir: bool,
    is_expanded: bool = false,
    depth: usize,

    pub fn deinit(self: *FileNode, allocator: std.mem.Allocator) void {
        if (self.name.len > 0) {
            allocator.free(self.name);
            self.name = &[_]u8{};
        }
        if (self.absolute_path.len > 0) {
            allocator.free(self.absolute_path);
            self.absolute_path = &[_]u8{};
        }
    }
};

pub const SearchResult = struct {
    name: []const u8,
    absolute_path: []const u8,
    is_dir: bool,
    depth: usize,

    pub fn deinit(self: *SearchResult, allocator: std.mem.Allocator) void {
        if (self.name.len > 0) {
            allocator.free(self.name);
            self.name = &[_]u8{};
        }
        if (self.absolute_path.len > 0) {
            allocator.free(self.absolute_path);
            self.absolute_path = &[_]u8{};
        }
    }
};

const SortContext = struct {
    pub fn lessThan(ctx: void, a: FileNode, b: FileNode) bool {
        _ = ctx;
        if (a.is_dir and !b.is_dir) return true;
        if (!a.is_dir and b.is_dir) return false;

        var i: usize = 0;
        while (i < a.name.len and i < b.name.len) : (i += 1) {
            const ca = std.ascii.toLower(a.name[i]);
            const cb = std.ascii.toLower(b.name[i]);
            if (ca < cb) return true;
            if (ca > cb) return false;
        }
        return a.name.len < b.name.len;
    }
};

pub const Explorer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    root_path: []const u8,
    nodes: std.ArrayList(FileNode),
    selected_index: usize = 0,
    scroll_offset: usize = 0,
    search_active: bool = false,
    search_query: std.ArrayListUnmanaged(u8) = .empty,
    search_results: std.ArrayList(SearchResult),
    search_selected_index: usize = 0,
    search_scroll_offset: usize = 0,
    hidden_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, root_path: []const u8) !Explorer {
        if (!builtin.is_test) logz.info().fmt("msg", "initializing explorer at: {s}", .{root_path}).log();
        var self = Explorer{
            .allocator = allocator,
            .io = io,
            .root_path = try allocator.dupe(u8, root_path),
            .nodes = std.ArrayList(FileNode).empty,
            .search_results = std.ArrayList(SearchResult).empty,
        };
        errdefer self.deinit();
        try self.loadDirectory(root_path, 0, 0);
        return self;
    }

    pub fn deinit(self: *Explorer) void {
        for (self.nodes.items) |*node| {
            node.deinit(self.allocator);
        }
        self.nodes.deinit(self.allocator);
        self.nodes = std.ArrayList(FileNode).empty;

        self.clearSearchResults();
        self.search_results.deinit(self.allocator);
        self.search_results = std.ArrayList(SearchResult).empty;
        self.search_query.deinit(self.allocator);
        self.search_query = .empty;

        if (self.root_path.len > 0) {
            self.allocator.free(self.root_path);
            self.root_path = &[_]u8{};
        }
    }

    fn shouldHideEntry(name: []const u8) bool {
        return std.mem.eql(u8, name, ".") or
            std.mem.eql(u8, name, "..") or
            std.mem.eql(u8, name, ".git") or
            std.mem.eql(u8, name, ".zig-cache") or
            std.mem.eql(u8, name, ".DS_Store");
    }

    fn loadDirectory(self: *Explorer, dir_path: []const u8, depth: usize, insert_idx: usize) !void {
        if (!builtin.is_test) logz.debug().fmt("msg", "loading directory: {s} (depth {d})", .{ dir_path, depth }).log();
        var dir = std.Io.Dir.cwd().openDir(self.io, dir_path, .{ .iterate = true }) catch |err| {
            if (!builtin.is_test) logz.warn().fmt("msg", "failed to open directory {s}: {s}", .{ dir_path, @errorName(err) }).log();
            return;
        };
        defer dir.close(self.io);

        var temp_nodes = std.ArrayList(FileNode).empty;
        var inserted = false;
        defer {
            if (!inserted) {
                for (temp_nodes.items) |*node| {
                    node.deinit(self.allocator);
                }
            }
            temp_nodes.deinit(self.allocator);
        }

        var it = dir.iterate();
        while (try it.next(self.io)) |entry| {
            if (shouldHideEntry(entry.name)) {
                self.hidden_count += 1;
                continue;
            }

            const is_dir = entry.kind == .directory;
            const abs_path = try std.fs.path.join(self.allocator, &[_][]const u8{ dir_path, entry.name });
            errdefer self.allocator.free(abs_path);

            const name_dupe = try self.allocator.dupe(u8, entry.name);
            errdefer self.allocator.free(name_dupe);

            try temp_nodes.append(self.allocator, .{
                .name = name_dupe,
                .absolute_path = abs_path,
                .is_dir = is_dir,
                .is_expanded = false,
                .depth = depth,
            });
        }

        std.mem.sort(FileNode, temp_nodes.items, {}, SortContext.lessThan);
        try self.nodes.insertSlice(self.allocator, insert_idx, temp_nodes.items);
        inserted = true;
    }

    pub fn toggleExpand(self: *Explorer) !void {
        if (self.nodes.items.len == 0) return;
        if (self.selected_index >= self.nodes.items.len) return;

        const node = &self.nodes.items[self.selected_index];
        if (!node.is_dir) return;

        if (node.is_expanded) {
            if (!builtin.is_test) logz.debug().fmt("msg", "collapsing node: {s}", .{node.name}).log();
            // Collapse
            node.is_expanded = false;
            const base_depth = node.depth;
            var i = self.selected_index + 1;
            var remove_count: usize = 0;
            while (i < self.nodes.items.len) : (i += 1) {
                if (self.nodes.items[i].depth <= base_depth) break;
                remove_count += 1;
            }

            var r = self.selected_index + 1;
            for (0..remove_count) |_| {
                self.nodes.items[r].deinit(self.allocator);
                r += 1;
            }

            self.nodes.replaceRangeAssumeCapacity(self.selected_index + 1, remove_count, &[_]FileNode{});
        } else {
            if (!builtin.is_test) logz.debug().fmt("msg", "expanding node: {s}", .{node.name}).log();
            // Expand
            node.is_expanded = true;
            try self.loadDirectory(node.absolute_path, node.depth + 1, self.selected_index + 1);
        }
    }

    pub fn startSearch(self: *Explorer) !void {
        self.search_active = true;
        self.search_selected_index = 0;
        self.search_scroll_offset = 0;
        self.search_query.clearRetainingCapacity();
        try self.updateSearchResults();
    }

    pub fn cancelSearch(self: *Explorer) void {
        self.search_active = false;
        self.search_query.clearRetainingCapacity();
        self.clearSearchResults();
        self.search_selected_index = 0;
        self.search_scroll_offset = 0;
    }

    pub fn finishSearch(self: *Explorer) !void {
        if (self.selectedSearchResult()) |result| {
            try self.revealPath(result.absolute_path);
        }
        self.search_active = false;
        self.search_query.clearRetainingCapacity();
        self.clearSearchResults();
        self.search_selected_index = 0;
        self.search_scroll_offset = 0;
    }

    pub fn appendSearchChar(self: *Explorer, ch: u8) !void {
        try self.search_query.append(self.allocator, ch);
        try self.updateSearchResults();
    }

    pub fn backspaceSearch(self: *Explorer) !void {
        if (self.search_query.items.len == 0) return;
        self.search_query.shrinkRetainingCapacity(self.search_query.items.len - 1);
        try self.updateSearchResults();
    }

    fn clearSearchResults(self: *Explorer) void {
        for (self.search_results.items) |*result| {
            result.deinit(self.allocator);
        }
        self.search_results.clearRetainingCapacity();
    }

    fn updateSearchResults(self: *Explorer) !void {
        self.clearSearchResults();
        self.search_selected_index = 0;
        self.search_scroll_offset = 0;
        if (self.search_query.items.len == 0) return;
        try self.searchDirectory(self.root_path, 0);
        if (self.search_selected_index >= self.search_results.items.len) {
            self.search_selected_index = 0;
        }
    }

    fn searchDirectory(self: *Explorer, dir_path: []const u8, depth: usize) !void {
        var dir = std.Io.Dir.cwd().openDir(self.io, dir_path, .{ .iterate = true }) catch |err| {
            if (!builtin.is_test) logz.warn().fmt("msg", "failed to search directory {s}: {s}", .{ dir_path, @errorName(err) }).log();
            return;
        };
        defer dir.close(self.io);

        var temp_results = std.ArrayList(SearchResult).empty;
        var inserted = false;
        defer {
            if (!inserted) {
                for (temp_results.items) |*result| {
                    result.deinit(self.allocator);
                }
            }
            temp_results.deinit(self.allocator);
        }

        var it = dir.iterate();
        while (try it.next(self.io)) |entry| {
            if (shouldHideEntry(entry.name)) continue;

            const is_dir = entry.kind == .directory;
            const abs_path = try std.fs.path.join(self.allocator, &[_][]const u8{ dir_path, entry.name });
            errdefer self.allocator.free(abs_path);

            if (matchesQuery(entry.name, self.search_query.items) or matchesQuery(abs_path, self.search_query.items)) {
                const name_dupe = try self.allocator.dupe(u8, entry.name);
                errdefer self.allocator.free(name_dupe);
                const path_dupe = try self.allocator.dupe(u8, abs_path);
                errdefer self.allocator.free(path_dupe);
                try temp_results.append(self.allocator, .{
                    .name = name_dupe,
                    .absolute_path = path_dupe,
                    .is_dir = is_dir,
                    .depth = depth,
                });
            }

            if (is_dir) {
                try self.searchDirectory(abs_path, depth + 1);
            }
            self.allocator.free(abs_path);
        }

        std.mem.sort(SearchResult, temp_results.items, {}, SearchSortContext.lessThan);
        try self.search_results.appendSlice(self.allocator, temp_results.items);
        inserted = true;
    }

    pub fn selectedSearchResult(self: *Explorer) ?SearchResult {
        if (!self.search_active) return null;
        if (self.search_results.items.len == 0) return null;
        if (self.search_selected_index >= self.search_results.items.len) return null;
        return self.search_results.items[self.search_selected_index];
    }

    pub fn selectedNode(self: *Explorer) ?*FileNode {
        if (self.search_active) return null;
        if (self.nodes.items.len == 0) return null;
        if (self.selected_index >= self.nodes.items.len) return null;
        return &self.nodes.items[self.selected_index];
    }

    pub fn selectedBaseDirectory(self: *Explorer) []const u8 {
        const node = self.selectedNode() orelse return self.root_path;
        if (node.is_dir) return node.absolute_path;
        return std.fs.path.dirname(node.absolute_path) orelse self.root_path;
    }

    pub fn refresh(self: *Explorer, reveal_path: ?[]const u8) !void {
        const selected_path = if (reveal_path) |path|
            try self.allocator.dupe(u8, path)
        else if (self.selectedNode()) |node|
            try self.allocator.dupe(u8, node.absolute_path)
        else
            null;
        defer if (selected_path) |path| self.allocator.free(path);

        for (self.nodes.items) |*node| node.deinit(self.allocator);
        self.nodes.clearRetainingCapacity();
        self.selected_index = 0;
        self.scroll_offset = 0;
        self.hidden_count = 0;
        self.cancelSearch();
        try self.loadDirectory(self.root_path, 0, 0);

        if (selected_path) |path| {
            self.revealPath(path) catch {};
        }
    }

    pub fn revealPath(self: *Explorer, path: []const u8) !void {
        if (std.fs.path.dirname(path)) |parent| {
            try self.revealDirectory(parent);
        }

        if (self.findNodeIndex(path)) |idx| {
            self.selected_index = idx;
            self.adjustScroll(1);
        }
    }

    fn revealDirectory(self: *Explorer, dir_path: []const u8) !void {
        if (std.mem.eql(u8, dir_path, self.root_path)) return;

        if (std.fs.path.dirname(dir_path)) |parent| {
            try self.revealDirectory(parent);
        }

        const idx = self.findNodeIndex(dir_path) orelse return;
        if (!self.nodes.items[idx].is_dir) return;
        if (!self.nodes.items[idx].is_expanded) {
            self.selected_index = idx;
            try self.toggleExpand();
        }
    }

    fn findNodeIndex(self: *Explorer, path: []const u8) ?usize {
        for (self.nodes.items, 0..) |node, idx| {
            if (std.mem.eql(u8, node.absolute_path, path)) return idx;
        }
        return null;
    }

    pub fn render(self: *Explorer, screen: *render_mod.VirtualScreen, width: usize, height: usize, is_focused: bool, snapshot: ?*const git_status.Snapshot, icons: icons_mod.IconSet) void {
        self.renderAt(screen, width, height, 0, 0, is_focused, snapshot, icons);
    }

    pub fn renderAt(self: *Explorer, screen: *render_mod.VirtualScreen, width: usize, height: usize, start_row: usize, start_col: usize, is_focused: bool, snapshot: ?*const git_status.Snapshot, icons: icons_mod.IconSet) void {
        if (width == 0 or height == 0) return;

        for (start_row..start_row + height) |row| {
            fillCells(screen, row, start_col, width, ' ', .explorer_bg);
        }

        fillCells(screen, start_row, start_col, width, ' ', .explorer_header);
        const root_label = compactRootLabel(self.root_path);
        var title_col = start_col;
        title_col += writeClippedToScreen(screen, start_row, title_col, start_col + width, icons.folder, .explorer_header);
        title_col += writeClippedToScreen(screen, start_row, title_col, start_col + width, " ", .explorer_header);
        _ = writeClippedToScreen(screen, start_row, title_col, start_col + width, root_label, .explorer_header);

        var content_start_row = start_row + 1;
        var view_height = height -| 2;
        if (self.search_active) {
            fillCells(screen, content_start_row, start_col, width, ' ', .explorer_selected);
            var search_col = start_col;
            var search_buf: [256]u8 = undefined;
            const search_text = std.fmt.bufPrint(&search_buf, "/{s}", .{self.search_query.items}) catch "/";
            search_col += writeClippedToScreen(screen, content_start_row, search_col, start_col + width, search_text, .explorer_selected);
            if (self.search_query.items.len > 0) {
                var buf: [64]u8 = undefined;
                const match_info = std.fmt.bufPrint(&buf, " ({d} matches)", .{self.search_results.items.len}) catch "";
                _ = writeClippedToScreen(screen, content_start_row, search_col, start_col + width, match_info, .explorer_selected);
            }
            content_start_row += 1;
            view_height -|= 1;
        }

        if (view_height == 0) return;

        if (self.search_active) {
            self.adjustSearchScroll(view_height);
            self.renderSearchResults(screen, width, content_start_row, start_col, view_height, is_focused, snapshot, icons);
            return;
        }

        self.adjustScroll(view_height);
        var row: usize = content_start_row;
        var i = self.scroll_offset;
        while (i < self.nodes.items.len and row < content_start_row + view_height) : (i += 1) {
            const node = self.nodes.items[i];

            const selected = is_focused and i == self.selected_index;
            fillCells(screen, row, start_col, width, ' ', rowBgStyle(selected));

            var col = start_col + @min(node.depth * 2, width);

            const icon = iconForNode(icons, node.is_dir, node.is_expanded, node.name);
            const node_status = snapshotStatus(snapshot, node.absolute_path);
            const style = styleForNode(node.is_dir, node.name, selected, node_status);
            col += writeClippedToScreen(screen, row, col, start_col + width, icon, style);
            col += writeClippedToScreen(screen, row, col, start_col + width, " ", rowBgStyle(selected));

            const indent_len = node.depth * 2 + render_mod.displayCellCount(icon) + 1;
            const max_name_len = width -| indent_len;
            col += writeClippedToScreen(screen, row, col, start_col + width, clippedByCells(node.name, max_name_len), style);

            const current_len = indent_len + @min(render_mod.displayCellCount(node.name), max_name_len);
            if (current_len + 2 < width) {
                const marker = gitMarker(icons, node_status);
                if (marker.len > 0) {
                    const pad = width - current_len - 2;
                    _ = writeClippedToScreen(screen, row, start_col + current_len + pad, start_col + width, marker, markerStyle(node_status, selected));
                }
            }

            row += 1;
        }

        if (self.hidden_count > 0 and row < content_start_row + view_height) {
            var buf: [48]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, "({d} hidden items)", .{self.hidden_count}) catch "";
            fillCells(screen, row, start_col, width, ' ', .explorer_bg);
            _ = writeClippedToScreen(screen, row, start_col, start_col + width, text, .explorer_dim);
            row += 1;
        }
    }

    fn renderSearchResults(self: *Explorer, screen: *render_mod.VirtualScreen, width: usize, start_row: usize, start_col: usize, view_height: usize, is_focused: bool, snapshot: ?*const git_status.Snapshot, icons: icons_mod.IconSet) void {
        var row: usize = start_row;
        var i = self.search_scroll_offset;
        while (i < self.search_results.items.len and row < start_row + view_height) : (i += 1) {
            const result = self.search_results.items[i];

            const selected = is_focused and i == self.search_selected_index;
            fillCells(screen, row, start_col, width, ' ', rowBgStyle(selected));

            var col = start_col + @min(result.depth * 2, width);

            const icon = iconForNode(icons, result.is_dir, false, result.name);
            const style = styleForNode(result.is_dir, result.name, selected, snapshotStatus(snapshot, result.absolute_path));
            col += writeClippedToScreen(screen, row, col, start_col + width, icon, style);
            col += writeClippedToScreen(screen, row, col, start_col + width, " ", rowBgStyle(selected));

            const context = relativeParentPath(self.root_path, result.absolute_path);
            const indent_len = result.depth * 2 + render_mod.displayCellCount(icon) + 1;
            const context_prefix = "  ";
            const context_len = context_prefix.len + context.len;
            const max_line_len = width -| indent_len;
            const reserve_context = if (max_line_len > context_len + 4) context_len else 0;
            const max_name_len = max_line_len -| reserve_context;

            col += writeClippedToScreen(screen, row, col, start_col + width, clippedByCells(result.name, max_name_len), style);

            if (reserve_context > 0) {
                col += writeClippedToScreen(screen, row, col, start_col + width, context_prefix, .explorer_dim);
                _ = writeClippedToScreen(screen, row, col, start_col + width, context, .explorer_dim);
            }
            row += 1;
        }
    }

    pub fn moveUp(self: *Explorer) void {
        if (self.search_active) {
            if (self.search_selected_index > 0) self.search_selected_index -= 1;
            return;
        }
        if (self.selected_index > 0) {
            self.selected_index -= 1;
        }
    }

    pub fn moveDown(self: *Explorer) void {
        if (self.search_active) {
            if (self.search_results.items.len > 0 and self.search_selected_index < self.search_results.items.len - 1) {
                self.search_selected_index += 1;
            }
            return;
        }
        if (self.nodes.items.len > 0 and self.selected_index < self.nodes.items.len - 1) {
            self.selected_index += 1;
        }
    }

    pub fn adjustScroll(self: *Explorer, view_height: usize) void {
        if (self.nodes.items.len == 0) return;
        if (self.selected_index < self.scroll_offset) {
            self.scroll_offset = self.selected_index;
        } else if (self.selected_index >= self.scroll_offset + view_height) {
            self.scroll_offset = self.selected_index - view_height + 1;
        }
    }

    pub fn adjustSearchScroll(self: *Explorer, view_height: usize) void {
        if (self.search_results.items.len == 0) return;
        if (self.search_selected_index < self.search_scroll_offset) {
            self.search_scroll_offset = self.search_selected_index;
        } else if (self.search_selected_index >= self.search_scroll_offset + view_height) {
            self.search_scroll_offset = self.search_selected_index - view_height + 1;
        }
    }
};

const SearchSortContext = struct {
    pub fn lessThan(ctx: void, a: SearchResult, b: SearchResult) bool {
        _ = ctx;
        if (a.is_dir and !b.is_dir) return true;
        if (!a.is_dir and b.is_dir) return false;

        var i: usize = 0;
        while (i < a.name.len and i < b.name.len) : (i += 1) {
            const ca = std.ascii.toLower(a.name[i]);
            const cb = std.ascii.toLower(b.name[i]);
            if (ca < cb) return true;
            if (ca > cb) return false;
        }
        return a.name.len < b.name.len;
    }
};

fn matchesQuery(haystack: []const u8, query: []const u8) bool {
    if (query.len == 0) return true;
    if (haystack.len < query.len) return false;

    var i: usize = 0;
    while (i <= haystack.len - query.len) : (i += 1) {
        var matched = true;
        for (query, 0..) |q, j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(q)) {
                matched = false;
                break;
            }
        }
        if (matched) return true;
    }
    return false;
}

fn iconForNode(icon_set: icons_mod.IconSet, is_dir: bool, is_expanded: bool, name: []const u8) []const u8 {
    if (is_dir) return file_icons.iconForDirectory(icon_set, is_expanded);
    return file_icons.iconForFileName(icon_set, name);
}

fn styleForNode(is_dir: bool, name: []const u8, selected: bool, state: ?git_status.FileState) render_mod.RenderStyle {
    if (selected) return .explorer_selected_focus;
    if (state == .ignored) return .explorer_dim;
    if (is_dir) return .explorer_folder;
    return file_icons.styleForFileName(name);
}

fn rowBgStyle(selected: bool) render_mod.RenderStyle {
    return if (selected) .explorer_selected_focus else .explorer_bg;
}

fn markerStyle(state: ?git_status.FileState, selected: bool) render_mod.RenderStyle {
    return switch (state orelse return rowBgStyle(selected)) {
        .modified => if (selected) .git_diff_modified_selected else .git_diff_modified,
        .untracked => if (selected) .git_diff_added_selected else .git_diff_added,
        .ignored => if (selected) .git_ignored_selected else .git_ignored,
    };
}

fn gitMarker(icon_set: icons_mod.IconSet, state: ?git_status.FileState) []const u8 {
    return switch (state orelse return "") {
        .modified => icon_set.git_modified,
        .untracked => icon_set.git_added,
        .ignored => icon_set.git_ignored,
    };
}

fn snapshotStatus(snapshot: ?*const git_status.Snapshot, path: []const u8) ?git_status.FileState {
    return if (snapshot) |s| s.stateForPath(path) else null;
}

fn compactRootLabel(root_path: []const u8) []const u8 {
    if (std.mem.startsWith(u8, root_path, "/Users/")) {
        var rest = root_path["/Users/".len..];
        if (std.mem.indexOfScalar(u8, rest, '/')) |idx| {
            rest = rest[idx..];
            if (std.mem.startsWith(u8, rest, "/")) return rest;
        }
    }
    return root_path;
}

fn clippedByCells(text: []const u8, max_cells: usize) []const u8 {
    var cells: usize = 0;
    var i: usize = 0;
    while (i < text.len and cells < max_cells) : (cells += 1) {
        const len = @min(render_mod.utf8CellLen(text[i]), text.len - i);
        i += len;
    }
    return text[0..i];
}

fn fillCells(screen: *render_mod.VirtualScreen, row: usize, start_col: usize, width: usize, ch: u8, style: render_mod.RenderStyle) void {
    for (0..width) |offset| {
        screen.set(row, start_col + offset, ch, style);
    }
}

fn writeClippedToScreen(screen: *render_mod.VirtualScreen, row: usize, col: usize, end_col: usize, text: []const u8, style: render_mod.RenderStyle) usize {
    if (col >= end_col) return 0;
    const clipped = clippedByCells(text, end_col - col);
    screen.writeText(row, col, clipped, style);
    return render_mod.displayCellCount(clipped);
}

fn relativeParentPath(root_path: []const u8, absolute_path: []const u8) []const u8 {
    const parent = std.fs.path.dirname(absolute_path) orelse return ".";
    if (std.mem.eql(u8, parent, root_path)) return ".";
    if (std.mem.startsWith(u8, parent, root_path) and parent.len > root_path.len) {
        var relative = parent[root_path.len..];
        if (relative.len > 0 and (relative[0] == '/' or relative[0] == std.fs.path.sep)) {
            relative = relative[1..];
        }
        if (relative.len > 0) return relative;
    }
    return parent;
}

test "explorer query matching is case insensitive" {
    try std.testing.expect(matchesQuery("src/Editor/Buffer.zig", "buffer"));
    try std.testing.expect(matchesQuery("src/Editor/Buffer.zig", "EDITOR"));
    try std.testing.expect(!matchesQuery("src/main.zig", "README"));
}

test "explorer file style is stable by extension" {
    try std.testing.expectEqual(styleForNode(false, "a.zig", false, null), styleForNode(false, "b.zig", false, null));
    try std.testing.expect(styleForNode(false, "a.zig", false, null) != styleForNode(false, "a.toml", false, null));
}

test "explorer render uses nerd icons hidden count and git markers" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);

    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.createDirPath(io, ".zig-cache");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/main.zig", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "README.md", .data = "" });

    var exp = try Explorer.init(allocator, io, root);
    defer exp.deinit();
    try exp.toggleExpand();

    var snapshot = git_status.Snapshot.init(allocator);
    defer snapshot.deinit();
    snapshot.root_path = try allocator.dupe(u8, root);
    try snapshot.put("src/main.zig", .modified);

    var screen = render_mod.VirtualScreen.init(allocator);
    defer screen.deinit();
    _ = try screen.resize(40, 12);
    exp.renderAt(&screen, 40, 12, 0, 0, true, &snapshot, icons_mod.nerdFontIcons);

    var renderer = render_mod.VirtualScreenRenderer.init(allocator);
    defer renderer.deinit();
    var out = std.ArrayListUnmanaged(u8).empty;
    defer out.deinit(allocator);
    var aw = std.Io.Writer.Allocating.fromArrayList(allocator, &out);
    defer aw.deinit();
    _ = try renderer.emit(&aw.writer, &screen);
    const rendered = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, rendered, icons_mod.nerdFontIcons.folder_open) != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, icons_mod.nerdFontIcons.file_zig) != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, icons_mod.nerdFontIcons.git_modified) != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "hidden items") != null);
}

test "explorer search result parent path is relative to root" {
    try std.testing.expectEqualStrings("nested/child", relativeParentPath("project", "project/nested/child/main.zig"));
    try std.testing.expectEqualStrings(".", relativeParentPath("project", "project/main.zig"));
}

test "explorer recursive search includes unloaded nested files" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "nested/child");
    try tmp.dir.writeFile(io, .{ .sub_path = "nested/child/deep.zig", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "top.toml", .data = "" });

    const root_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root_path);

    var exp = try Explorer.init(allocator, io, root_path);
    defer exp.deinit();

    try exp.startSearch();
    try exp.appendSearchChar('d');
    try exp.appendSearchChar('e');
    try exp.appendSearchChar('e');
    try exp.appendSearchChar('p');

    try std.testing.expectEqual(@as(usize, 1), exp.search_results.items.len);
    try std.testing.expectEqualStrings("deep.zig", exp.search_results.items[0].name);
}

test "explorer recursive search matches nested paths" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "nested/child");
    try tmp.dir.writeFile(io, .{ .sub_path = "nested/child/deep.zig", .data = "" });

    const root_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root_path);

    var exp = try Explorer.init(allocator, io, root_path);
    defer exp.deinit();

    try exp.startSearch();
    for ("child/deep") |ch| try exp.appendSearchChar(ch);

    try std.testing.expectEqual(@as(usize, 1), exp.search_results.items.len);
    try std.testing.expectEqualStrings("deep.zig", exp.search_results.items[0].name);
}

test "explorer clearing search restores normal state" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "README.md", .data = "" });

    const root_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root_path);

    var exp = try Explorer.init(allocator, io, root_path);
    defer exp.deinit();

    try exp.startSearch();
    for ("missing") |ch| try exp.appendSearchChar(ch);
    try std.testing.expectEqual(@as(usize, 0), exp.search_results.items.len);

    exp.cancelSearch();
    try std.testing.expect(!exp.search_active);
    try std.testing.expectEqual(@as(usize, 0), exp.search_results.items.len);
    try std.testing.expectEqualStrings("", exp.search_query.items);
    try std.testing.expectEqual(@as(usize, 1), exp.nodes.items.len);
}
