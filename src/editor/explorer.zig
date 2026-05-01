const std = @import("std");
const builtin = @import("builtin");
const logz = @import("logz");
const terminal = @import("../terminal.zig");

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

    fn shouldSkipEntry(name: []const u8) bool {
        return std.mem.eql(u8, name, ".") or
            std.mem.eql(u8, name, "..") or
            std.mem.eql(u8, name, ".git") or
            std.mem.eql(u8, name, ".zig-cache") or
            std.mem.eql(u8, name, "zig-out");
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
            if (shouldSkipEntry(entry.name)) continue;

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
            if (shouldSkipEntry(entry.name)) continue;

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

    pub fn render(self: *Explorer, writer: anytype, width: usize, height: usize, is_focused: bool) !void {
        try self.renderAt(writer, width, height, 1, is_focused);
    }

    pub fn renderAt(self: *Explorer, writer: anytype, width: usize, height: usize, start_row: usize, is_focused: bool) !void {
        if (width == 0 or height == 0) return;

        var clear_row = start_row;
        const clear_end = start_row + height - 1;
        while (clear_row < clear_end) : (clear_row += 1) {
            try terminal.moveCursor(writer, clear_row, 1);
            try writer.writeAll("\x1b[0m");
            for (0..width) |_| try writer.writeAll(" ");
        }

        try terminal.moveCursor(writer, start_row, 1);
        if (is_focused) {
            try writer.writeAll("\x1b[48;5;204m\x1b[38;5;16m\x1b[1m");
        } else {
            try writer.writeAll("\x1b[48;5;236m\x1b[38;5;250m\x1b[1m");
        }
        const title = " EXPLORER ";
        try writer.writeAll(title);
        const title_pad = width -| title.len;
        for (0..title_pad) |_| try writer.writeAll(" ");
        try writer.writeAll("\x1b[0m"); // Reset

        var content_start_row = start_row + 1;
        var view_height = height -| 2;
        if (self.search_active) {
            try terminal.moveCursor(writer, content_start_row, 1);
            try writer.writeAll("\x1b[48;5;238m\x1b[38;5;228m");
            var written: usize = 1 + self.search_query.items.len;
            try writer.print("/{s}", .{self.search_query.items});
            if (self.search_query.items.len > 0) {
                var buf: [64]u8 = undefined;
                const match_info = try std.fmt.bufPrint(&buf, " ({d} matches)", .{self.search_results.items.len});
                try writer.writeAll(match_info);
                written += match_info.len;
            }
            if (width > written) {
                for (0..width - written) |_| try writer.writeAll(" ");
            }
            try writer.writeAll("\x1b[0m");
            content_start_row += 1;
            view_height -|= 1;
        }

        if (view_height == 0) return;

        if (self.search_active) {
            self.adjustSearchScroll(view_height);
            try self.renderSearchResults(writer, width, content_start_row, view_height, is_focused);
            return;
        }

        self.adjustScroll(view_height);
        var row: usize = content_start_row;
        var i = self.scroll_offset;
        while (i < self.nodes.items.len and row < content_start_row + view_height) : (i += 1) {
            const node = self.nodes.items[i];
            try terminal.moveCursor(writer, row, 1);

            if (is_focused and i == self.selected_index) {
                try writer.writeAll("\x1b[48;5;238m");
            }

            for (0..node.depth) |_| {
                try writer.writeAll("  ");
            }

            const icon = iconForNode(node.is_dir, node.is_expanded, node.name);
            const color = colorForNode(node.is_dir, node.name);
            try writer.writeAll(color);
            try writer.writeAll(icon);
            try writer.writeAll(" ");

            const indent_len = node.depth * 2 + icon.len + 1;
            const max_name_len = width -| indent_len;
            if (node.name.len > max_name_len) {
                try writer.writeAll(node.name[0..max_name_len]);
            } else {
                try writer.writeAll(node.name);
            }

            const current_len = indent_len + @min(node.name.len, max_name_len);
            if (current_len < width) {
                try writer.writeAll("\x1b[0m");
                if (is_focused and i == self.selected_index) {
                    try writer.writeAll("\x1b[48;5;238m");
                }
                const pad = width - current_len;
                for (0..pad) |_| try writer.writeAll(" ");
            }

            try writer.writeAll("\x1b[0m");

            row += 1;
        }

        while (row < content_start_row + view_height) : (row += 1) {
            try terminal.moveCursor(writer, row, 1);
            for (0..width) |_| try writer.writeAll(" ");
        }
    }

    fn renderSearchResults(self: *Explorer, writer: anytype, width: usize, start_row: usize, view_height: usize, is_focused: bool) !void {
        var row: usize = start_row;
        var i = self.search_scroll_offset;
        while (i < self.search_results.items.len and row < start_row + view_height) : (i += 1) {
            const result = self.search_results.items[i];
            try terminal.moveCursor(writer, row, 1);

            if (is_focused and i == self.search_selected_index) {
                try writer.writeAll("\x1b[48;5;238m");
            }

            for (0..result.depth) |_| try writer.writeAll("  ");

            const icon = iconForNode(result.is_dir, false, result.name);
            const color = colorForNode(result.is_dir, result.name);
            try writer.writeAll(color);
            try writer.writeAll(icon);
            try writer.writeAll(" ");

            const context = relativeParentPath(self.root_path, result.absolute_path);
            const indent_len = result.depth * 2 + icon.len + 1;
            const context_prefix = "  ";
            const context_len = context_prefix.len + context.len;
            const max_line_len = width -| indent_len;
            const reserve_context = if (max_line_len > context_len + 4) context_len else 0;
            const max_name_len = max_line_len -| reserve_context;

            const written_name_len = @min(result.name.len, max_name_len);
            if (result.name.len > max_name_len) {
                try writer.writeAll(result.name[0..max_name_len]);
            } else {
                try writer.writeAll(result.name);
            }

            var current_len = indent_len + written_name_len;
            if (reserve_context > 0) {
                try writer.writeAll("\x1b[0m");
                if (is_focused and i == self.search_selected_index) {
                    try writer.writeAll("\x1b[48;5;238m");
                }
                try writer.writeAll("\x1b[38;5;245m");
                try writer.writeAll(context_prefix);
                try writer.writeAll(context);
                current_len += context_len;
            }

            if (current_len < width) {
                try writer.writeAll("\x1b[0m");
                if (is_focused and i == self.search_selected_index) {
                    try writer.writeAll("\x1b[48;5;238m");
                }
                for (0..width - current_len) |_| try writer.writeAll(" ");
            }
            try writer.writeAll("\x1b[0m");
            row += 1;
        }

        while (row < start_row + view_height) : (row += 1) {
            try terminal.moveCursor(writer, row, 1);
            for (0..width) |_| try writer.writeAll(" ");
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

fn iconForNode(is_dir: bool, is_expanded: bool, name: []const u8) []const u8 {
    if (is_dir) return if (is_expanded) "▾ " else "▸ ";
    const ext = std.fs.path.extension(name);
    if (std.mem.eql(u8, ext, ".zig")) return "◇";
    if (std.mem.eql(u8, ext, ".toml")) return "⚙";
    if (std.mem.eql(u8, ext, ".json")) return "{}";
    if (std.mem.eql(u8, ext, ".xml")) return "<>";
    if (std.mem.eql(u8, ext, ".md")) return "M";
    return "·";
}

fn colorForNode(is_dir: bool, name: []const u8) []const u8 {
    if (is_dir) return "\x1b[38;5;220m\x1b[1m";
    const ext = std.fs.path.extension(name);
    if (std.mem.eql(u8, ext, ".zig")) return "\x1b[38;5;214m";
    if (std.mem.eql(u8, ext, ".toml")) return "\x1b[38;5;117m";
    if (std.mem.eql(u8, ext, ".json")) return "\x1b[38;5;121m";
    if (std.mem.eql(u8, ext, ".xml")) return "\x1b[38;5;204m";
    if (std.mem.eql(u8, ext, ".md")) return "\x1b[38;5;183m";
    if (std.mem.eql(u8, ext, ".ziggy")) return "\x1b[38;5;208m";
    return "\x1b[38;5;250m";
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

test "explorer file color is stable by extension" {
    try std.testing.expectEqualStrings(colorForNode(false, "a.zig"), colorForNode(false, "b.zig"));
    try std.testing.expect(!std.mem.eql(u8, colorForNode(false, "a.zig"), colorForNode(false, "a.toml")));
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
