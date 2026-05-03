const std = @import("std");

pub const Error = error{RootOpenFailed};

pub const max_results: usize = 200;
pub const max_file_size_for_content_scan: usize = 1 * 1024 * 1024;
pub const max_content_matches_per_file: usize = 10;
pub const max_snippet_len: usize = 120;
pub const visible_result_rows: usize = 6;

pub const PathResult = struct {
    open_path: []u8,
    display_path: []u8,
};

pub const ContentResult = struct {
    open_path: []u8,
    display_path: []u8,
    row: usize,
    col: usize,
    snippet: []u8,
};

pub const GlobalSearchResult = union(enum) {
    path: PathResult,
    content: ContentResult,

    pub fn deinit(self: *GlobalSearchResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .path => |*result| {
                allocator.free(result.open_path);
                allocator.free(result.display_path);
                result.open_path = &.{};
                result.display_path = &.{};
            },
            .content => |*result| {
                allocator.free(result.open_path);
                allocator.free(result.display_path);
                allocator.free(result.snippet);
                result.open_path = &.{};
                result.display_path = &.{};
                result.snippet = &.{};
            },
        }
    }

    pub fn openPath(self: GlobalSearchResult) []const u8 {
        return switch (self) {
            .path => |result| result.open_path,
            .content => |result| result.open_path,
        };
    }

    pub fn displayPath(self: GlobalSearchResult) []const u8 {
        return switch (self) {
            .path => |result| result.display_path,
            .content => |result| result.display_path,
        };
    }
};

pub const GlobalSearch = struct {
    input: std.ArrayListUnmanaged(u8) = .empty,
    results: std.ArrayListUnmanaged(GlobalSearchResult) = .empty,
    selected_index: ?usize = null,
    scroll_offset: usize = 0,
    root_path: []u8 = &.{},
    visible: bool = false,

    pub fn open(self: *GlobalSearch, allocator: std.mem.Allocator, root_path: []const u8) !void {
        self.close(allocator);
        self.visible = true;
        self.root_path = try allocator.dupe(u8, root_path);
    }

    pub fn close(self: *GlobalSearch, allocator: std.mem.Allocator) void {
        self.visible = false;
        self.input.clearRetainingCapacity();
        self.clearResults(allocator);
        self.selected_index = null;
        self.scroll_offset = 0;
        if (self.root_path.len > 0) {
            allocator.free(self.root_path);
            self.root_path = &.{};
        }
    }

    pub fn deinit(self: *GlobalSearch, allocator: std.mem.Allocator) void {
        self.close(allocator);
        self.input.deinit(allocator);
        self.input = .empty;
        self.results.deinit(allocator);
        self.results = .empty;
    }

    pub fn clearResults(self: *GlobalSearch, allocator: std.mem.Allocator) void {
        for (self.results.items) |*result| {
            result.deinit(allocator);
        }
        self.results.clearRetainingCapacity();
        self.selected_index = null;
        self.scroll_offset = 0;
    }

    pub fn appendChar(self: *GlobalSearch, allocator: std.mem.Allocator, io: std.Io, ch: u8) !void {
        try self.input.append(allocator, ch);
        try self.refresh(allocator, io);
    }

    pub fn backspace(self: *GlobalSearch, allocator: std.mem.Allocator, io: std.Io) !void {
        if (self.input.items.len == 0) return;
        self.input.shrinkRetainingCapacity(self.input.items.len - 1);
        try self.refresh(allocator, io);
    }

    pub fn refresh(self: *GlobalSearch, allocator: std.mem.Allocator, io: std.Io) !void {
        self.clearResults(allocator);
        if (self.input.items.len == 0) return;
        try searchRoot(self, allocator, io);
        self.selected_index = if (self.results.items.len > 0) 0 else null;
    }

    pub fn selectNext(self: *GlobalSearch) void {
        if (self.results.items.len == 0) return;
        const current = self.selected_index orelse 0;
        self.selected_index = (current + 1) % self.results.items.len;
        self.adjustScroll(visible_result_rows);
    }

    pub fn selectPrevious(self: *GlobalSearch) void {
        if (self.results.items.len == 0) return;
        const current = self.selected_index orelse 0;
        self.selected_index = if (current == 0) self.results.items.len - 1 else current - 1;
        self.adjustScroll(visible_result_rows);
    }

    pub fn selectedResult(self: *GlobalSearch) ?GlobalSearchResult {
        const idx = self.selected_index orelse return null;
        if (idx >= self.results.items.len) return null;
        return self.results.items[idx];
    }

    pub fn adjustScroll(self: *GlobalSearch, view_height: usize) void {
        if (view_height == 0 or self.results.items.len == 0) return;
        const selected = self.selected_index orelse return;
        if (selected < self.scroll_offset) {
            self.scroll_offset = selected;
        } else if (selected >= self.scroll_offset + view_height) {
            self.scroll_offset = selected - view_height + 1;
        }
    }
};

fn searchRoot(search: *GlobalSearch, allocator: std.mem.Allocator, io: std.Io) !void {
    var dir = std.Io.Dir.cwd().openDir(io, search.root_path, .{ .iterate = true }) catch return Error.RootOpenFailed;
    defer dir.close(io);

    try searchDirectory(search, allocator, io, search.root_path);
}

fn searchDirectory(search: *GlobalSearch, allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8) !void {
    if (search.results.items.len >= max_results) return;

    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var it = dir.iterate();
    while (true) {
        const entry = it.next(io) catch return;
        if (entry == null) break;
        if (search.results.items.len >= max_results) return;
        if (shouldIgnoreName(entry.?.name)) continue;

        const open_path = try std.fs.path.join(allocator, &.{ dir_path, entry.?.name });
        defer allocator.free(open_path);

        switch (entry.?.kind) {
            .directory => try searchDirectory(search, allocator, io, open_path),
            .file => try searchFile(search, allocator, io, open_path, entry.?.name),
            else => {},
        }
    }
}

fn searchFile(search: *GlobalSearch, allocator: std.mem.Allocator, io: std.Io, open_path: []const u8, entry_name: []const u8) !void {
    const display_path = relativeDisplayPath(search.root_path, open_path);
    if (matchesLiteralAsciiInsensitive(entry_name, search.input.items) or
        matchesLiteralAsciiInsensitive(display_path, search.input.items))
    {
        try appendPathResult(search, allocator, open_path, display_path);
        if (search.results.items.len >= max_results) return;
    }

    if (search.input.items.len < 2) return;
    try appendContentResults(search, allocator, io, open_path, display_path);
}

fn appendPathResult(search: *GlobalSearch, allocator: std.mem.Allocator, open_path: []const u8, display_path: []const u8) !void {
    if (search.results.items.len >= max_results) return;
    const owned_open_path = try allocator.dupe(u8, open_path);
    errdefer allocator.free(owned_open_path);
    const owned_display_path = try allocator.dupe(u8, display_path);
    errdefer allocator.free(owned_display_path);
    try search.results.append(allocator, .{ .path = .{
        .open_path = owned_open_path,
        .display_path = owned_display_path,
    } });
}

fn appendContentResults(search: *GlobalSearch, allocator: std.mem.Allocator, io: std.Io, open_path: []const u8, display_path: []const u8) !void {
    const stat = std.Io.Dir.cwd().statFile(io, open_path, .{}) catch return;
    if (stat.size > max_file_size_for_content_scan) return;

    const contents = std.Io.Dir.cwd().readFileAlloc(io, open_path, allocator, std.Io.Limit.limited(max_file_size_for_content_scan)) catch return;
    defer allocator.free(contents);

    if (isLikelyBinary(contents)) return;

    var matches_in_file: usize = 0;
    var row: usize = 0;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line_raw| : (row += 1) {
        var line = line_raw;
        if (line.len > 0 and line[line.len - 1] == '\r') {
            line = line[0 .. line.len - 1];
        }

        var search_start: usize = 0;
        while (search_start <= line.len) {
            const found = indexOfLiteralAsciiInsensitive(line[search_start..], search.input.items) orelse break;
            const col = search_start + found;
            try appendContentResult(search, allocator, open_path, display_path, row, col, line);
            matches_in_file += 1;
            if (matches_in_file >= max_content_matches_per_file or search.results.items.len >= max_results) return;
            search_start = col + 1;
        }
    }
}

fn appendContentResult(
    search: *GlobalSearch,
    allocator: std.mem.Allocator,
    open_path: []const u8,
    display_path: []const u8,
    row: usize,
    col: usize,
    line: []const u8,
) !void {
    if (search.results.items.len >= max_results) return;
    const owned_open_path = try allocator.dupe(u8, open_path);
    errdefer allocator.free(owned_open_path);
    const owned_display_path = try allocator.dupe(u8, display_path);
    errdefer allocator.free(owned_display_path);
    const snippet_len = @min(line.len, max_snippet_len);
    const owned_snippet = try allocator.dupe(u8, line[0..snippet_len]);
    errdefer allocator.free(owned_snippet);
    try search.results.append(allocator, .{ .content = .{
        .open_path = owned_open_path,
        .display_path = owned_display_path,
        .row = row,
        .col = col,
        .snippet = owned_snippet,
    } });
}

pub fn shouldIgnoreName(name: []const u8) bool {
    const ignored = [_][]const u8{
        ".",
        "..",
        ".git",
        ".gitignore",
        "zig-cache",
        ".zig-cache",
        "zig-out",
        "zig-pkg",
        "node_modules",
        "target",
        "build",
        ".DS_Store",
    };
    for (ignored) |candidate| {
        if (std.mem.eql(u8, name, candidate)) return true;
    }
    return false;
}

pub fn matchesLiteralAsciiInsensitive(haystack: []const u8, needle: []const u8) bool {
    return indexOfLiteralAsciiInsensitive(haystack, needle) != null;
}

fn indexOfLiteralAsciiInsensitive(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (haystack.len < needle.len) return null;

    var i: usize = 0;
    while (i <= haystack.len - needle.len) : (i += 1) {
        var matched = true;
        for (needle, 0..) |needle_ch, j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle_ch)) {
                matched = false;
                break;
            }
        }
        if (matched) return i;
    }
    return null;
}

fn relativeDisplayPath(root_path: []const u8, open_path: []const u8) []const u8 {
    if (std.mem.eql(u8, root_path, ".")) {
        if (std.mem.startsWith(u8, open_path, "./")) return open_path[2..];
        return open_path;
    }
    if (std.mem.startsWith(u8, open_path, root_path) and open_path.len > root_path.len) {
        var relative = open_path[root_path.len..];
        if (relative.len > 0 and (relative[0] == '/' or relative[0] == std.fs.path.sep)) {
            relative = relative[1..];
        }
        if (relative.len > 0) return relative;
    }
    return open_path;
}

pub fn isLikelyBinary(bytes: []const u8) bool {
    if (bytes.len == 0) return false;

    var control_count: usize = 0;
    for (bytes) |byte| {
        if (byte == 0) return true;
        if (byte < 32 and byte != '\n' and byte != '\r' and byte != '\t') {
            control_count += 1;
        }
    }

    return control_count * 100 > bytes.len * 30;
}

test "global search result deinit owns all result memory" {
    const allocator = std.testing.allocator;

    var path_result = GlobalSearchResult{ .path = .{
        .open_path = try allocator.dupe(u8, "src/main.zig"),
        .display_path = try allocator.dupe(u8, "src/main.zig"),
    } };
    path_result.deinit(allocator);

    var content_result = GlobalSearchResult{ .content = .{
        .open_path = try allocator.dupe(u8, "src/main.zig"),
        .display_path = try allocator.dupe(u8, "src/main.zig"),
        .row = 1,
        .col = 2,
        .snippet = try allocator.dupe(u8, "needle"),
    } };
    content_result.deinit(allocator);
}

test "global search literal ASCII case-insensitive matching" {
    try std.testing.expect(matchesLiteralAsciiInsensitive("src/Editor/Buffer.zig", "editor"));
    try std.testing.expect(matchesLiteralAsciiInsensitive("Flamingo", "FLA"));
    try std.testing.expect(!matchesLiteralAsciiInsensitive("src/main.zig", "needle"));
}

test "global search binary detection" {
    try std.testing.expect(isLikelyBinary("abc\x00def"));
    try std.testing.expect(!isLikelyBinary("line one\nline two\tok"));
    try std.testing.expect(isLikelyBinary("\x01\x02\x03\x04abcdef"));
}

test "global search query length controls content scanning" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "plain.txt", .data = "z appears only in content\n" });

    const root_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root_path);

    var search = GlobalSearch{};
    defer search.deinit(allocator);
    try search.open(allocator, root_path);

    try search.appendChar(allocator, io, 'z');
    try std.testing.expectEqual(@as(usize, 0), search.results.items.len);

    try search.appendChar(allocator, io, ' ');
    try std.testing.expectEqual(@as(usize, 1), search.results.items.len);
    switch (search.results.items[0]) {
        .content => |result| {
            try std.testing.expectEqual(@as(usize, 0), result.row);
            try std.testing.expectEqual(@as(usize, 0), result.col);
        },
        .path => return error.TestUnexpectedResult,
    }
}

test "global search ignores configured directories and returns files only" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "node_modules");
    try tmp.dir.writeFile(io, .{ .sub_path = "node_modules/needle.txt", .data = "needle\n" });
    try tmp.dir.createDirPath(io, "needle_dir");
    try tmp.dir.writeFile(io, .{ .sub_path = "needle_dir/child.txt", .data = "" });

    const root_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root_path);

    var search = GlobalSearch{};
    defer search.deinit(allocator);
    try search.open(allocator, root_path);
    try search.input.appendSlice(allocator, "needle");
    try search.refresh(allocator, io);

    try std.testing.expectEqual(@as(usize, 1), search.results.items.len);
    switch (search.results.items[0]) {
        .path => |result| try std.testing.expectEqualStrings("needle_dir/child.txt", result.display_path),
        .content => return error.TestUnexpectedResult,
    }
}

test "global search content metadata and CRLF snippets" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "plain.txt", .data = "first\r\nxxNeedle here\r\n" });

    const root_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root_path);

    var search = GlobalSearch{};
    defer search.deinit(allocator);
    try search.open(allocator, root_path);
    try search.input.appendSlice(allocator, "needle");
    try search.refresh(allocator, io);

    try std.testing.expectEqual(@as(usize, 1), search.results.items.len);
    switch (search.results.items[0]) {
        .content => |result| {
            try std.testing.expectEqual(@as(usize, 1), result.row);
            try std.testing.expectEqual(@as(usize, 2), result.col);
            try std.testing.expect(std.mem.indexOfScalar(u8, result.snippet, '\r') == null);
        },
        .path => return error.TestUnexpectedResult,
    }
}

test "global search skips binary content but keeps binary path matches" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "binary-needle.bin", .data = "needle\x00still binary" });

    const root_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root_path);

    var search = GlobalSearch{};
    defer search.deinit(allocator);
    try search.open(allocator, root_path);
    try search.input.appendSlice(allocator, "needle");
    try search.refresh(allocator, io);

    try std.testing.expectEqual(@as(usize, 1), search.results.items.len);
    switch (search.results.items[0]) {
        .path => |result| try std.testing.expectEqualStrings("binary-needle.bin", result.display_path),
        .content => return error.TestUnexpectedResult,
    }
}

test "global search caps content matches per file" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "plain.txt", .data = "aa aa aa aa aa aa aa aa aa aa aa aa\n" });

    const root_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root_path);

    var search = GlobalSearch{};
    defer search.deinit(allocator);
    try search.open(allocator, root_path);
    try search.input.appendSlice(allocator, "aa");
    try search.refresh(allocator, io);

    try std.testing.expectEqual(max_content_matches_per_file, search.results.items.len);
}

test "global search caps total results" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    for (0..max_results + 20) |i| {
        const name = try std.fmt.allocPrint(allocator, "hit-{d}.txt", .{i});
        defer allocator.free(name);
        try tmp.dir.writeFile(io, .{ .sub_path = name, .data = "" });
    }

    const root_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root_path);

    var search = GlobalSearch{};
    defer search.deinit(allocator);
    try search.open(allocator, root_path);
    try search.input.appendSlice(allocator, "hit");
    try search.refresh(allocator, io);

    try std.testing.expectEqual(max_results, search.results.items.len);
}

test "global search selection wraps and scrolls" {
    const allocator = std.testing.allocator;
    var search = GlobalSearch{};
    defer search.deinit(allocator);

    for (0..8) |i| {
        const name = try std.fmt.allocPrint(allocator, "file-{d}.zig", .{i});
        errdefer allocator.free(name);
        const display = try std.fmt.allocPrint(allocator, "file-{d}.zig", .{i});
        errdefer allocator.free(display);
        try search.results.append(allocator, .{ .path = .{
            .open_path = name,
            .display_path = display,
        } });
    }

    search.selected_index = 0;
    for (0..6) |_| search.selectNext();
    try std.testing.expectEqual(@as(?usize, 6), search.selected_index);
    try std.testing.expectEqual(@as(usize, 1), search.scroll_offset);

    for (0..8) |_| search.selectNext();
    try std.testing.expectEqual(@as(?usize, 6), search.selected_index);

    search.selectPrevious();
    try std.testing.expectEqual(@as(?usize, 5), search.selected_index);
}
