const std = @import("std");
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
    root_path: []const u8,
    nodes: std.ArrayList(FileNode),
    selected_index: usize = 0,
    scroll_offset: usize = 0,

    pub fn init(allocator: std.mem.Allocator, root_path: []const u8) !Explorer {
        logz.info().fmt("msg", "initializing explorer at: {s}", .{root_path}).log();
        var self = Explorer{
            .allocator = allocator,
            .root_path = try allocator.dupe(u8, root_path),
            .nodes = std.ArrayList(FileNode).empty,
        };
        try self.loadDirectory(root_path, 0, 0);
        return self;
    }

    pub fn deinit(self: *Explorer) void {
        for (self.nodes.items) |*node| {
            node.deinit(self.allocator);
        }
        self.nodes.deinit(self.allocator);
        self.nodes = std.ArrayList(FileNode).empty;

        if (self.root_path.len > 0) {
            self.allocator.free(self.root_path);
            self.root_path = &[_]u8{};
        }
    }

    fn loadDirectory(self: *Explorer, dir_path: []const u8, depth: usize, insert_idx: usize) !void {
        logz.debug().fmt("msg", "loading directory: {s} (depth {d})", .{dir_path, depth}).log();
        var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| {
            logz.warn().fmt("msg", "failed to open directory {s}: {s}", .{dir_path, @errorName(err)}).log();
            return;
        };
        defer dir.close();

        var temp_nodes = std.ArrayList(FileNode).empty;
        defer temp_nodes.deinit(self.allocator);

        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;
            if (std.mem.eql(u8, entry.name, ".git")) continue;
            if (std.mem.eql(u8, entry.name, ".zig-cache")) continue;
            if (std.mem.eql(u8, entry.name, "zig-out")) continue;

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
    }

    pub fn toggleExpand(self: *Explorer) !void {
        if (self.nodes.items.len == 0) return;
        if (self.selected_index >= self.nodes.items.len) return;

        const node = &self.nodes.items[self.selected_index];
        if (!node.is_dir) return;

        if (node.is_expanded) {
            logz.debug().fmt("msg", "collapsing node: {s}", .{node.name}).log();
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
            logz.debug().fmt("msg", "expanding node: {s}", .{node.name}).log();
            // Expand
            node.is_expanded = true;
            try self.loadDirectory(node.absolute_path, node.depth + 1, self.selected_index + 1);
        }
    }

    pub fn render(self: *Explorer, writer: anytype, width: usize, height: usize, is_focused: bool) !void {
        try self.renderAt(writer, width, height, 1, is_focused);
    }

    pub fn renderAt(self: *Explorer, writer: anytype, width: usize, height: usize, start_row: usize, is_focused: bool) !void {
        try terminal.moveCursor(writer, start_row, 1);
        try writer.writeAll("\x1b[7m"); // Invert
        const title = " EXPLORER ";
        try writer.writeAll(title);
        const title_pad = width -| title.len;
        for (0..title_pad) |_| try writer.writeAll(" ");
        try writer.writeAll("\x1b[0m"); // Reset

        const view_height = height -| 2;
        if (view_height == 0) return;

        self.adjustScroll(view_height);

        var row: usize = start_row + 1;
        var i = self.scroll_offset;
        while (i < self.nodes.items.len and row <= start_row + view_height) : (i += 1) {
            const node = self.nodes.items[i];
            try terminal.moveCursor(writer, row, 1);

            if (is_focused and i == self.selected_index) {
                try writer.writeAll("\x1b[7m");
            }

            for (0..node.depth) |_| {
                try writer.writeAll("  ");
            }

            if (node.is_dir) {
                if (node.is_expanded) {
                    try writer.writeAll("▼ ");
                } else {
                    try writer.writeAll("▶ ");
                }
            } else {
                try writer.writeAll("  ");
            }

            const indent_len = node.depth * 2 + 2;
            const max_name_len = width -| indent_len;
            if (node.name.len > max_name_len) {
                try writer.writeAll(node.name[0..max_name_len]);
            } else {
                try writer.writeAll(node.name);
            }

            const current_len = indent_len + @min(node.name.len, max_name_len);
            if (current_len < width) {
                const pad = width - current_len;
                for (0..pad) |_| try writer.writeAll(" ");
            }

            if (is_focused and i == self.selected_index) {
                try writer.writeAll("\x1b[0m");
            }

            row += 1;
        }

        while (row <= start_row + view_height) : (row += 1) {
            try terminal.moveCursor(writer, row, 1);
            for (0..width) |_| try writer.writeAll(" ");
        }
    }

    pub fn moveUp(self: *Explorer) void {
        if (self.selected_index > 0) {
            self.selected_index -= 1;
        }
    }

    pub fn moveDown(self: *Explorer) void {
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
};

