const std = @import("std");
const ts = @import("tree-sitter");
const buffer = @import("buffer.zig");

extern fn tree_sitter_zig() callconv(.c) *const anyopaque;
extern fn tree_sitter_go() callconv(.c) *const anyopaque;
extern fn tree_sitter_toml() callconv(.c) *const anyopaque;
extern fn tree_sitter_yaml() callconv(.c) *const anyopaque;
extern fn tree_sitter_json() callconv(.c) *const anyopaque;

const zig_query = @embedFile("queries/zig.scm");
const go_query = @embedFile("queries/go.scm");
const toml_query = @embedFile("queries/toml.scm");
const yaml_query = @embedFile("queries/yaml.scm");
const json_query = @embedFile("queries/json.scm");

pub const LanguageId = enum {
    zig,
    go,
    toml,
    yaml,
    json,
};

pub const Style = enum {
    keyword,
    string,
    comment,
    number,
    constant,
    type,
    function,
    property,
    operator,
    punctuation,

    pub fn ansi(self: Style) []const u8 {
        return switch (self) {
            .keyword => "\x1b[38;5;177m",
            .string => "\x1b[38;5;150m",
            .comment => "\x1b[38;5;244m",
            .number => "\x1b[38;5;216m",
            .constant => "\x1b[38;5;203m",
            .type => "\x1b[38;5;116m",
            .function => "\x1b[38;5;111m",
            .property => "\x1b[38;5;180m",
            .operator => "\x1b[38;5;250m",
            .punctuation => "\x1b[38;5;245m",
        };
    }

    fn priority(self: Style) u8 {
        return switch (self) {
            .comment => 100,
            .string => 90,
            .keyword => 80,
            .function => 70,
            .type => 60,
            .constant => 55,
            .number => 50,
            .property => 45,
            .operator => 35,
            .punctuation => 30,
        };
    }
};

pub const HighlightSpan = struct {
    start: usize,
    end: usize,
    style: Style,
};

pub const HighlightRun = struct {
    start_col: usize,
    end_col: usize,
    style: Style,
};

pub fn languageFromFilename(filename: []const u8) ?LanguageId {
    const ext = std.fs.path.extension(filename);
    if (std.mem.eql(u8, ext, ".zig")) return .zig;
    if (std.mem.eql(u8, ext, ".go")) return .go;
    if (std.mem.eql(u8, ext, ".toml")) return .toml;
    if (std.mem.eql(u8, ext, ".yaml") or std.mem.eql(u8, ext, ".yml")) return .yaml;
    if (std.mem.eql(u8, ext, ".json")) return .json;
    return null;
}

pub const Highlighter = struct {
    allocator: std.mem.Allocator,
    language: ?LanguageId = null,
    parser: ?*ts.Parser = null,
    query: ?*ts.Query = null,
    tree: ?*ts.Tree = null,
    source: []u8 = &.{},
    parsed_revision: ?u64 = null,
    spans: std.ArrayList(HighlightSpan) = .empty,
    line_starts: std.ArrayList(usize) = .empty,
    line_runs: std.AutoHashMap(usize, std.ArrayList(HighlightRun)),
    viewport_revision: ?u64 = null,
    viewport_first_line: usize = 0,
    viewport_last_line: usize = 0,
    full_reparse_count: usize = 0,
    incremental_reparse_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator) Highlighter {
        return .{
            .allocator = allocator,
            .line_runs = std.AutoHashMap(usize, std.ArrayList(HighlightRun)).init(allocator),
        };
    }

    pub fn deinit(self: *Highlighter) void {
        self.resetLanguageState();
        self.clearLineRuns();
        self.line_runs.deinit();
        self.spans.deinit(self.allocator);
        self.line_starts.deinit(self.allocator);
        if (self.source.len > 0) {
            self.allocator.free(self.source);
            self.source = &.{};
        }
    }

    pub fn ensureForBuffer(self: *Highlighter, buf: *const buffer.Buffer) !void {
        try self.ensureForViewport(buf, 0, buf.lines.items.len, 0);
    }

    pub fn ensureForViewport(self: *Highlighter, buf: *const buffer.Buffer, first_line: usize, last_line: usize, margin: usize) !void {
        const filename = buf.filename orelse {
            self.resetAll();
            return;
        };

        const next_language = languageFromFilename(filename) orelse {
            self.resetAll();
            return;
        };

        const line_count = buf.lines.items.len;
        const requested_first = if (first_line > margin) first_line - margin else 0;
        const requested_last = @min(line_count, last_line + margin);

        if (self.language == next_language and
            self.parsed_revision == buf.revision and
            self.viewport_revision == buf.revision and
            requested_first >= self.viewport_first_line and
            requested_last <= self.viewport_last_line)
        {
            return;
        }

        if (self.language != next_language) {
            self.resetLanguageState();
            self.language = next_language;
            self.parser = ts.Parser.create();
            try self.parser.?.setLanguage(languagePtr(next_language));
            self.query = createQuery(next_language) catch null;
        }

        if (self.parsed_revision != buf.revision) {
            const content = try buf.toString(self.allocator);
            errdefer self.allocator.free(content);

            const old_source = self.source;
            var old_tree = self.tree;
            var used_incremental = false;

            if (old_tree) |tree| {
                if (buf.lastEditDelta()) |delta| {
                    if (delta.revision == buf.revision and self.parsed_revision != null and self.parsed_revision.? +% 1 == buf.revision) {
                        tree.edit(toInputEdit(delta));
                        used_incremental = true;
                    } else {
                        tree.destroy();
                        old_tree = null;
                    }
                } else {
                    tree.destroy();
                    old_tree = null;
                }
            }

            self.source = content;
            try self.rebuildLineStarts();

            const parser = self.parser orelse return;
            const tree = parser.parseString(self.source, old_tree) orelse {
                if (old_tree) |old| old.destroy();
                if (old_source.len > 0) self.allocator.free(old_source);
                self.tree = null;
                self.parsed_revision = null;
                self.clearLineRuns();
                self.spans.clearRetainingCapacity();
                return;
            };

            if (old_tree) |old| old.destroy();
            if (old_source.len > 0) self.allocator.free(old_source);
            self.tree = tree;
            self.parsed_revision = buf.revision;
            if (used_incremental) {
                self.incremental_reparse_count += 1;
            } else {
                self.full_reparse_count += 1;
            }
        }

        const query = self.query orelse return;
        const tree = self.tree orelse return;
        const start_byte = self.lineStartByte(requested_first);
        const end_byte = self.lineEndByte(requested_last);

        self.spans.clearRetainingCapacity();
        self.clearLineRuns();
        try self.collectSpans(query, tree.rootNode(), start_byte, end_byte);
        self.viewport_revision = buf.revision;
        self.viewport_first_line = requested_first;
        self.viewport_last_line = requested_last;
    }

    pub fn lineStartByte(self: *const Highlighter, row: usize) usize {
        if (row >= self.line_starts.items.len) return 0;
        return self.line_starts.items[row];
    }

    pub fn lineEndByte(self: *const Highlighter, row: usize) usize {
        if (row == 0) return 0;
        if (row < self.line_starts.items.len) {
            return self.line_starts.items[row] -| 1;
        }
        return self.source.len;
    }

    pub fn styleAtLine(self: *const Highlighter, row: usize, col: usize) ?Style {
        const runs = self.line_runs.get(row) orelse return null;
        var best: ?Style = null;
        for (runs.items) |run| {
            if (col < run.start_col) continue;
            if (col >= run.end_col) continue;
            if (best == null or run.style.priority() > best.?.priority()) {
                best = run.style;
            }
        }
        return best;
    }

    pub fn styleAt(self: *const Highlighter, byte_offset: usize) ?Style {
        var best: ?Style = null;
        for (self.spans.items) |span| {
            if (byte_offset < span.start) break;
            if (byte_offset >= span.start and byte_offset < span.end) {
                if (best == null or span.style.priority() > best.?.priority()) {
                    best = span.style;
                }
            }
        }
        return best;
    }

    pub fn hasStyle(self: *const Highlighter, style: Style) bool {
        for (self.spans.items) |span| {
            if (span.style == style) return true;
        }
        return false;
    }

    fn collectSpans(self: *Highlighter, query: *ts.Query, root: ts.Node, start_byte: usize, end_byte: usize) !void {
        var cursor = ts.QueryCursor.create();
        defer cursor.destroy();
        try cursor.setByteRange(@intCast(start_byte), @intCast(end_byte));
        cursor.exec(query, root);

        while (cursor.nextCapture()) |item| {
            const capture_index, const match = item;
            if (capture_index >= match.captures.len) continue;

            const capture = match.captures[capture_index];
            const capture_name = query.captureNameForId(capture.index) orelse continue;
            const style = styleForCapture(capture_name) orelse continue;
            const start = @as(usize, @intCast(capture.node.startByte()));
            const end = @as(usize, @intCast(capture.node.endByte()));
            if (start >= end) continue;
            if (end <= start_byte or start >= end_byte) continue;

            try self.spans.append(self.allocator, .{
                .start = start,
                .end = end,
                .style = style,
            });
            try self.appendLineRuns(start, end, style);
        }

        std.mem.sort(HighlightSpan, self.spans.items, {}, lessThanSpan);
    }

    fn appendLineRuns(self: *Highlighter, start_byte: usize, end_byte: usize, style: Style) !void {
        const start = self.byteToPoint(start_byte);
        const end = self.byteToPoint(end_byte);
        var row = start.row;
        while (row <= end.row and row < self.line_starts.items.len) : (row += 1) {
            const start_col = if (row == start.row) start.col else 0;
            const end_col = if (row == end.row) end.col else self.lineLength(row);
            if (start_col >= end_col) continue;

            const entry = try self.line_runs.getOrPut(row);
            if (!entry.found_existing) {
                entry.value_ptr.* = std.ArrayList(HighlightRun).empty;
            }
            try entry.value_ptr.append(self.allocator, .{
                .start_col = start_col,
                .end_col = end_col,
                .style = style,
            });
        }
    }

    fn byteToPoint(self: *const Highlighter, byte_offset: usize) buffer.TextPoint {
        if (self.line_starts.items.len == 0) return .{ .row = 0, .col = byte_offset };

        var row: usize = 0;
        while (row + 1 < self.line_starts.items.len and self.line_starts.items[row + 1] <= byte_offset) : (row += 1) {}
        return .{
            .row = row,
            .col = byte_offset - self.line_starts.items[row],
        };
    }

    fn lineLength(self: *const Highlighter, row: usize) usize {
        if (row >= self.line_starts.items.len) return 0;
        const start = self.line_starts.items[row];
        const end = if (row + 1 < self.line_starts.items.len)
            self.line_starts.items[row + 1] -| 1
        else
            self.source.len;
        return end -| start;
    }

    fn rebuildLineStarts(self: *Highlighter) !void {
        self.line_starts.clearRetainingCapacity();
        try self.line_starts.append(self.allocator, 0);
        for (self.source, 0..) |c, i| {
            if (c == '\n' and i + 1 < self.source.len) {
                try self.line_starts.append(self.allocator, i + 1);
            }
        }
    }

    fn resetAll(self: *Highlighter) void {
        self.resetLanguageState();
        self.language = null;
    }

    fn resetLanguageState(self: *Highlighter) void {
        self.clearParsedState();
        if (self.query) |query| {
            query.destroy();
            self.query = null;
        }
        if (self.parser) |parser| {
            parser.destroy();
            self.parser = null;
        }
    }

    fn clearParsedState(self: *Highlighter) void {
        if (self.tree) |tree| {
            tree.destroy();
            self.tree = null;
        }
        if (self.source.len > 0) {
            self.allocator.free(self.source);
            self.source = &.{};
        }
        self.spans.clearRetainingCapacity();
        self.line_starts.clearRetainingCapacity();
        self.clearLineRuns();
        self.parsed_revision = null;
        self.viewport_revision = null;
    }

    fn clearLineRuns(self: *Highlighter) void {
        var it = self.line_runs.valueIterator();
        while (it.next()) |runs| {
            runs.deinit(self.allocator);
        }
        self.line_runs.clearRetainingCapacity();
    }
};

fn toInputEdit(delta: buffer.TextEditDelta) ts.InputEdit {
    return .{
        .start_byte = @intCast(delta.start_byte),
        .old_end_byte = @intCast(delta.old_end_byte),
        .new_end_byte = @intCast(delta.new_end_byte),
        .start_point = .{ .row = @intCast(delta.start_point.row), .column = @intCast(delta.start_point.col) },
        .old_end_point = .{ .row = @intCast(delta.old_end_point.row), .column = @intCast(delta.old_end_point.col) },
        .new_end_point = .{ .row = @intCast(delta.new_end_point.row), .column = @intCast(delta.new_end_point.col) },
    };
}

fn languagePtr(language: LanguageId) *const ts.Language {
    const ptr = switch (language) {
        .zig => tree_sitter_zig(),
        .go => tree_sitter_go(),
        .toml => tree_sitter_toml(),
        .yaml => tree_sitter_yaml(),
        .json => tree_sitter_json(),
    };
    return @ptrCast(@alignCast(ptr));
}

fn createQuery(language: LanguageId) ts.Query.Error!*ts.Query {
    var error_offset: u32 = 0;
    return ts.Query.create(languagePtr(language), querySource(language), &error_offset);
}

fn querySource(language: LanguageId) []const u8 {
    return switch (language) {
        .zig => zig_query,
        .go => go_query,
        .toml => toml_query,
        .yaml => yaml_query,
        .json => json_query,
    };
}

fn styleForCapture(capture: []const u8) ?Style {
    if (std.mem.startsWith(u8, capture, "keyword")) return .keyword;
    if (std.mem.startsWith(u8, capture, "string")) return .string;
    if (std.mem.startsWith(u8, capture, "comment")) return .comment;
    if (std.mem.startsWith(u8, capture, "number") or std.mem.startsWith(u8, capture, "float")) return .number;
    if (std.mem.startsWith(u8, capture, "boolean") or
        std.mem.startsWith(u8, capture, "constant") or
        std.mem.eql(u8, capture, "null"))
    {
        return .constant;
    }
    if (std.mem.startsWith(u8, capture, "type")) return .type;
    if (std.mem.startsWith(u8, capture, "function") or std.mem.startsWith(u8, capture, "method")) return .function;
    if (std.mem.startsWith(u8, capture, "property") or
        std.mem.startsWith(u8, capture, "field") or
        std.mem.startsWith(u8, capture, "variable.member"))
    {
        return .property;
    }
    if (std.mem.startsWith(u8, capture, "operator")) return .operator;
    if (std.mem.startsWith(u8, capture, "punctuation")) return .punctuation;
    return null;
}

fn lessThanSpan(_: void, lhs: HighlightSpan, rhs: HighlightSpan) bool {
    if (lhs.start == rhs.start) {
        return lhs.style.priority() > rhs.style.priority();
    }
    return lhs.start < rhs.start;
}

test "languageFromFilename maps supported extensions" {
    try std.testing.expectEqual(LanguageId.zig, languageFromFilename("main.zig").?);
    try std.testing.expectEqual(LanguageId.go, languageFromFilename("main.go").?);
    try std.testing.expectEqual(LanguageId.toml, languageFromFilename("flamingo.toml").?);
    try std.testing.expectEqual(LanguageId.yaml, languageFromFilename("config.yaml").?);
    try std.testing.expectEqual(LanguageId.yaml, languageFromFilename("config.yml").?);
    try std.testing.expectEqual(LanguageId.json, languageFromFilename("package.json").?);
    try std.testing.expect(languageFromFilename("README.md") == null);
}

test "highlighter captures supported language styles" {
    const allocator = std.testing.allocator;

    const cases = [_]struct {
        filename: []const u8,
        source: []const u8,
        style: Style,
    }{
        .{ .filename = "main.zig", .source = "const x: u32 = 1;\n", .style = .keyword },
        .{ .filename = "main.go", .source = "package main\nfunc main() { println(\"hi\") }\n", .style = .keyword },
        .{ .filename = "config.toml", .source = "name = \"flamingo\"\n", .style = .string },
        .{ .filename = "config.yaml", .source = "name: flamingo\n", .style = .property },
        .{ .filename = "package.json", .source = "{\"name\":\"flamingo\"}\n", .style = .string },
    };

    for (cases) |case| {
        var buf = try buffer.Buffer.init(allocator);
        defer buf.deinit();
        try buf.setFilename(case.filename);

        var first = buf.lines.orderedRemove(0);
        first.deinit();

        var lines = std.mem.splitScalar(u8, case.source, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            try buf.lines.append(allocator, try buffer.Line.fromSlice(allocator, line));
        }

        var highlighter = Highlighter.init(allocator);
        defer highlighter.deinit();
        try highlighter.ensureForBuffer(&buf);
        try std.testing.expect(highlighter.hasStyle(case.style));
    }
}

test "highlighter skips unchanged buffer revision and reparses changed revision" {
    const allocator = std.testing.allocator;

    var buf = try buffer.Buffer.init(allocator);
    defer buf.deinit();
    try buf.setFilename("main.zig");
    try buf.insertChar(0, 0, 'c');
    try buf.insertChar(0, 1, 'o');
    try buf.insertChar(0, 2, 'n');
    try buf.insertChar(0, 3, 's');
    try buf.insertChar(0, 4, 't');

    var highlighter = Highlighter.init(allocator);
    defer highlighter.deinit();

    try highlighter.ensureForBuffer(&buf);
    const first_revision = highlighter.parsed_revision;
    const first_source_ptr = highlighter.source.ptr;

    try highlighter.ensureForBuffer(&buf);
    try std.testing.expectEqual(first_revision, highlighter.parsed_revision);
    try std.testing.expectEqual(first_source_ptr, highlighter.source.ptr);

    try buf.insertChar(0, 5, ' ');
    try highlighter.ensureForBuffer(&buf);
    try std.testing.expectEqual(buf.revision, highlighter.parsed_revision.?);
}

test "highlighter caches only requested viewport lines" {
    const allocator = std.testing.allocator;

    var buf = try buffer.Buffer.init(allocator);
    defer buf.deinit();
    try buf.setFilename("main.zig");

    var first = buf.lines.orderedRemove(0);
    first.deinit();
    try buf.lines.append(allocator, try buffer.Line.fromSlice(allocator, "const visible = 1;"));
    try buf.lines.append(allocator, try buffer.Line.fromSlice(allocator, "const hidden = 2;"));

    var highlighter = Highlighter.init(allocator);
    defer highlighter.deinit();
    try highlighter.ensureForViewport(&buf, 0, 1, 0);

    try std.testing.expect(highlighter.styleAtLine(0, 0) != null);
    try std.testing.expect(highlighter.styleAtLine(1, 0) == null);
}

test "highlighter uses incremental tree-sitter edits for matching buffer delta" {
    const allocator = std.testing.allocator;

    var buf = try buffer.Buffer.init(allocator);
    defer buf.deinit();
    try buf.setFilename("main.zig");
    try buf.insertChar(0, 0, 'c');
    try buf.insertChar(0, 1, 'o');
    try buf.insertChar(0, 2, 'n');
    try buf.insertChar(0, 3, 's');
    try buf.insertChar(0, 4, 't');

    var highlighter = Highlighter.init(allocator);
    defer highlighter.deinit();
    try highlighter.ensureForBuffer(&buf);
    try std.testing.expectEqual(@as(usize, 1), highlighter.full_reparse_count);
    try std.testing.expectEqual(@as(usize, 0), highlighter.incremental_reparse_count);

    try buf.insertChar(0, 5, ' ');
    try highlighter.ensureForBuffer(&buf);
    try std.testing.expectEqual(@as(usize, 1), highlighter.full_reparse_count);
    try std.testing.expectEqual(@as(usize, 1), highlighter.incremental_reparse_count);
}

test "highlighter discards stale edit deltas when revisions are skipped" {
    const allocator = std.testing.allocator;

    var buf = try buffer.Buffer.init(allocator);
    defer buf.deinit();
    try buf.setFilename("main.zig");
    try buf.insertChar(0, 0, 'c');
    try buf.insertChar(0, 1, 'o');
    try buf.insertChar(0, 2, 'n');
    try buf.insertChar(0, 3, 's');
    try buf.insertChar(0, 4, 't');

    var highlighter = Highlighter.init(allocator);
    defer highlighter.deinit();
    try highlighter.ensureForBuffer(&buf);

    try buf.insertChar(0, 5, ' ');
    try buf.insertChar(0, 6, 'x');
    try highlighter.ensureForBuffer(&buf);

    try std.testing.expectEqual(@as(usize, 2), highlighter.full_reparse_count);
    try std.testing.expectEqual(@as(usize, 0), highlighter.incremental_reparse_count);
}
