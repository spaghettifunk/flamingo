const std = @import("std");
const ts = @import("tree-sitter");
const buffer = @import("model/buffer.zig");

extern fn tree_sitter_zig() callconv(.c) *const anyopaque;
extern fn tree_sitter_go() callconv(.c) *const anyopaque;
extern fn tree_sitter_toml() callconv(.c) *const anyopaque;
extern fn tree_sitter_yaml() callconv(.c) *const anyopaque;
extern fn tree_sitter_json() callconv(.c) *const anyopaque;
extern fn tree_sitter_markdown() callconv(.c) *const anyopaque;
extern fn tree_sitter_markdown_inline() callconv(.c) *const anyopaque;
extern fn tree_sitter_proto() callconv(.c) *const anyopaque;

const zig_query = @embedFile("queries/zig.scm");
const go_query = @embedFile("queries/go.scm");
const toml_query = @embedFile("queries/toml.scm");
const yaml_query = @embedFile("queries/yaml.scm");
const json_query = @embedFile("queries/json.scm");
const markdown_query = @embedFile("queries/markdown.scm");
const markdown_inline_query = @embedFile("queries/markdown_inline.scm");
const proto_query = @embedFile("queries/proto.scm");

pub const LanguageId = enum {
    zig,
    go,
    toml,
    yaml,
    json,
    markdown,
    proto,
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

pub const HighlightRunCursor = struct {
    runs: []const HighlightRun,
    index: usize = 0,

    pub fn styleAt(self: *HighlightRunCursor, col: usize) ?Style {
        while (self.index < self.runs.len and self.runs[self.index].end_col <= col) {
            self.index += 1;
        }

        var best: ?Style = null;
        var i = self.index;
        while (i < self.runs.len) : (i += 1) {
            const run = self.runs[i];
            if (run.start_col > col) break;
            if (col < run.end_col and (best == null or run.style.priority() > best.?.priority())) {
                best = run.style;
            }
        }
        return best;
    }
};

pub const ParseResult = struct {
    buffer_id: u64,
    revision: u64,
    language: LanguageId,
    source: []u8,
    tree: ?*ts.Tree,
    markdown_inline_tree: ?*ts.Tree = null,

    pub fn deinit(self: *ParseResult, allocator: std.mem.Allocator) void {
        if (self.tree) |tree| {
            tree.destroy();
            self.tree = null;
        }
        if (self.markdown_inline_tree) |tree| {
            tree.destroy();
            self.markdown_inline_tree = null;
        }
        if (self.source.len > 0) {
            allocator.free(self.source);
            self.source = &.{};
        }
    }
};

pub fn languageFromFilename(filename: []const u8) ?LanguageId {
    const ext = std.fs.path.extension(filename);
    if (std.mem.eql(u8, ext, ".zig")) return .zig;
    if (std.mem.eql(u8, ext, ".go")) return .go;
    if (std.mem.eql(u8, ext, ".toml")) return .toml;
    if (std.mem.eql(u8, ext, ".yaml") or std.mem.eql(u8, ext, ".yml")) return .yaml;
    if (std.mem.eql(u8, ext, ".json")) return .json;
    if (std.mem.eql(u8, ext, ".md") or std.mem.eql(u8, ext, ".markdown")) return .markdown;
    if (std.mem.eql(u8, ext, ".proto")) return .proto;
    return null;
}

pub const ViewportCacheStatus = enum {
    none,
    hit,
    miss,
    unknown,

    pub fn name(self: ViewportCacheStatus) []const u8 {
        return switch (self) {
            .none => "none",
            .hit => "hit",
            .miss => "miss",
            .unknown => "unknown",
        };
    }
};

pub const Highlighter = struct {
    allocator: std.mem.Allocator,
    language: ?LanguageId = null,
    parser: ?*ts.Parser = null,
    query: ?*ts.Query = null,
    markdown_inline_query: ?*ts.Query = null,
    tree: ?*ts.Tree = null,
    markdown_inline_tree: ?*ts.Tree = null,
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

    pub fn prepareForAsyncBuffer(self: *Highlighter, buf: *const buffer.Buffer) !?LanguageId {
        const filename = buf.filename orelse {
            self.resetAll();
            return null;
        };

        const next_language = languageFromFilename(filename) orelse {
            self.resetAll();
            return null;
        };

        try self.ensureLanguageState(next_language, false);
        return next_language;
    }

    pub fn installParseResult(self: *Highlighter, result: *ParseResult) !void {
        if (result.tree == null) {
            return;
        }

        try self.ensureLanguageState(result.language, false);

        const old_source = self.source;
        const old_tree = self.tree;
        const old_markdown_inline_tree = self.markdown_inline_tree;

        self.source = result.source;
        result.source = &.{};
        self.tree = result.tree;
        result.tree = null;
        self.markdown_inline_tree = result.markdown_inline_tree;
        result.markdown_inline_tree = null;
        self.parsed_revision = result.revision;
        self.viewport_revision = null;
        self.viewport_first_line = 0;
        self.viewport_last_line = 0;
        self.spans.clearRetainingCapacity();
        self.clearLineRuns();
        self.full_reparse_count += 1;

        errdefer {
            if (old_tree) |tree| tree.destroy();
            if (old_markdown_inline_tree) |tree| tree.destroy();
            if (old_source.len > 0) self.allocator.free(old_source);
        }
        try self.rebuildLineStarts();

        if (old_tree) |tree| tree.destroy();
        if (old_markdown_inline_tree) |tree| tree.destroy();
        if (old_source.len > 0) self.allocator.free(old_source);
    }

    pub fn ensureViewportFromCommitted(self: *Highlighter, first_line: usize, last_line: usize, margin: usize) !void {
        const parsed_revision = self.parsed_revision orelse return;
        const query = self.query orelse return;
        const tree = self.tree orelse return;
        if (self.line_starts.items.len == 0) return;

        const line_count = self.line_starts.items.len;
        const requested_first = if (first_line > margin) first_line - margin else 0;
        const requested_last = @min(line_count, last_line + margin);

        if (self.viewport_revision == parsed_revision and
            requested_first >= self.viewport_first_line and
            requested_last <= self.viewport_last_line)
        {
            return;
        }

        const start_byte = self.lineStartByte(requested_first);
        const end_byte = self.lineEndByte(requested_last);

        self.spans.clearRetainingCapacity();
        self.clearLineRuns();
        try self.collectSpans(query, tree.rootNode(), start_byte, end_byte);
        try self.collectMarkdownInlineSpans(start_byte, end_byte);
        self.viewport_revision = parsed_revision;
        self.viewport_first_line = requested_first;
        self.viewport_last_line = requested_last;
    }

    pub fn viewportCacheStatusFromCommitted(self: *const Highlighter, first_line: usize, last_line: usize, margin: usize) ViewportCacheStatus {
        const parsed_revision = self.parsed_revision orelse return .none;
        if (self.query == null or self.tree == null or self.line_starts.items.len == 0) return .none;

        const line_count = self.line_starts.items.len;
        const requested_first = if (first_line > margin) first_line - margin else 0;
        const requested_last = @min(line_count, last_line + margin);

        if (self.viewport_revision == parsed_revision and
            requested_first >= self.viewport_first_line and
            requested_last <= self.viewport_last_line)
        {
            return .hit;
        }

        return .miss;
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

        try self.ensureLanguageState(next_language, true);

        if (self.parsed_revision != buf.revision) {
            const content = try buf.toOwnedTextSnapshot(self.allocator);
            errdefer self.allocator.free(content);

            const old_source = self.source;
            var old_tree = self.tree;
            const old_markdown_inline_tree = self.markdown_inline_tree;
            var used_incremental = false;
            self.markdown_inline_tree = null;

            if (old_tree) |tree| {
                if (self.parsed_revision) |parsed_revision| {
                    if (buf.editDeltasSince(parsed_revision)) |deltas| {
                        for (deltas) |delta| {
                            tree.edit(toInputEdit(delta));
                        }
                        used_incremental = deltas.len > 0;
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
                if (old_markdown_inline_tree) |old| old.destroy();
                if (old_source.len > 0) self.allocator.free(old_source);
                self.tree = null;
                self.parsed_revision = null;
                self.clearLineRuns();
                self.spans.clearRetainingCapacity();
                return;
            };
            const inline_tree = if (next_language == .markdown)
                parseMarkdownInlineTree(self.allocator, self.source, tree) catch |err| {
                    tree.destroy();
                    if (old_tree) |old| old.destroy();
                    if (old_markdown_inline_tree) |old| old.destroy();
                    if (old_source.len > 0) self.allocator.free(old_source);
                    if (self.source.len > 0) {
                        self.allocator.free(self.source);
                        self.source = &.{};
                    }
                    self.tree = null;
                    self.markdown_inline_tree = null;
                    self.parsed_revision = null;
                    self.spans.clearRetainingCapacity();
                    self.line_starts.clearRetainingCapacity();
                    self.clearLineRuns();
                    return err;
                }
            else
                null;

            if (old_tree) |old| old.destroy();
            if (old_markdown_inline_tree) |old| old.destroy();
            if (old_source.len > 0) self.allocator.free(old_source);
            self.tree = tree;
            self.markdown_inline_tree = inline_tree;
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
        try self.collectMarkdownInlineSpans(start_byte, end_byte);
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

    pub fn highlightRunCursor(self: *const Highlighter, row: usize) HighlightRunCursor {
        const runs = self.line_runs.get(row) orelse return .{ .runs = &.{} };
        return .{ .runs = runs.items };
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
        var runs_it = self.line_runs.valueIterator();
        while (runs_it.next()) |runs| {
            std.mem.sort(HighlightRun, runs.items, {}, lessThanRun);
        }
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

        var lo: usize = 0;
        var hi: usize = self.line_starts.items.len;
        while (lo + 1 < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.line_starts.items[mid] <= byte_offset) {
                lo = mid;
            } else {
                hi = mid;
            }
        }

        return .{
            .row = lo,
            .col = byte_offset - self.line_starts.items[lo],
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
        if (self.markdown_inline_query) |query| {
            query.destroy();
            self.markdown_inline_query = null;
        }
        if (self.parser) |parser| {
            parser.destroy();
            self.parser = null;
        }
    }

    fn ensureLanguageState(self: *Highlighter, next_language: LanguageId, need_parser: bool) !void {
        if (self.language != next_language) {
            self.resetLanguageState();
            self.language = next_language;
        }

        if (need_parser and self.parser == null) {
            self.parser = ts.Parser.create();
            try self.parser.?.setLanguage(languagePtr(next_language));
        }

        if (self.query == null) {
            self.query = createQuery(next_language) catch null;
        }
        if (next_language == .markdown and self.markdown_inline_query == null) {
            self.markdown_inline_query = createMarkdownInlineQuery() catch null;
        }
    }

    fn clearParsedState(self: *Highlighter) void {
        if (self.tree) |tree| {
            tree.destroy();
            self.tree = null;
        }
        if (self.markdown_inline_tree) |tree| {
            tree.destroy();
            self.markdown_inline_tree = null;
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

    fn collectMarkdownInlineSpans(self: *Highlighter, start_byte: usize, end_byte: usize) !void {
        if (self.language != .markdown) return;
        const query = self.markdown_inline_query orelse return;
        const tree = self.markdown_inline_tree orelse return;
        try self.collectSpans(query, tree.rootNode(), start_byte, end_byte);
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

pub fn languagePtr(language: LanguageId) *const ts.Language {
    const ptr = switch (language) {
        .zig => tree_sitter_zig(),
        .go => tree_sitter_go(),
        .toml => tree_sitter_toml(),
        .yaml => tree_sitter_yaml(),
        .json => tree_sitter_json(),
        .markdown => tree_sitter_markdown(),
        .proto => tree_sitter_proto(),
    };
    return @ptrCast(@alignCast(ptr));
}

fn markdownInlineLanguagePtr() *const ts.Language {
    return @ptrCast(@alignCast(tree_sitter_markdown_inline()));
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
        .markdown => markdown_query,
        .proto => proto_query,
    };
}

fn createMarkdownInlineQuery() ts.Query.Error!*ts.Query {
    var error_offset: u32 = 0;
    return ts.Query.create(markdownInlineLanguagePtr(), markdown_inline_query, &error_offset);
}

/// Returns an owned markdown_inline tree for `source`, or null when the block
/// tree has no inline ranges. The caller owns the returned tree.
pub fn parseMarkdownInlineTree(allocator: std.mem.Allocator, source: []const u8, block_tree: *ts.Tree) !?*ts.Tree {
    var ranges = std.ArrayList(ts.Range).empty;
    defer ranges.deinit(allocator);
    try collectMarkdownInlineRanges(allocator, &ranges, block_tree.rootNode());
    if (ranges.items.len == 0) return null;

    const parser = ts.Parser.create();
    defer parser.destroy();
    try parser.setLanguage(markdownInlineLanguagePtr());
    try parser.setIncludedRanges(ranges.items);
    return parser.parseString(source, null);
}

fn collectMarkdownInlineRanges(allocator: std.mem.Allocator, ranges: *std.ArrayList(ts.Range), node: ts.Node) !void {
    if (std.mem.eql(u8, node.kind(), "inline")) {
        const start = node.startByte();
        const end = node.endByte();
        if (start < end) {
            try ranges.append(allocator, .{
                .start_point = node.startPoint(),
                .end_point = node.endPoint(),
                .start_byte = start,
                .end_byte = end,
            });
        }
        return;
    }

    const child_count = node.childCount();
    var i: u32 = 0;
    while (i < child_count) : (i += 1) {
        if (node.child(i)) |child| {
            try collectMarkdownInlineRanges(allocator, ranges, child);
        }
    }
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

fn lessThanRun(_: void, lhs: HighlightRun, rhs: HighlightRun) bool {
    if (lhs.start_col == rhs.start_col) {
        return lhs.style.priority() > rhs.style.priority();
    }
    return lhs.start_col < rhs.start_col;
}

test "byteToPoint handles empty and single-line line starts" {
    const allocator = std.testing.allocator;
    var highlighter = Highlighter.init(allocator);
    defer highlighter.deinit();

    try std.testing.expectEqual(buffer.TextPoint{ .row = 0, .col = 7 }, highlighter.byteToPoint(7));

    try highlighter.line_starts.append(allocator, 0);
    try std.testing.expectEqual(buffer.TextPoint{ .row = 0, .col = 0 }, highlighter.byteToPoint(0));
    try std.testing.expectEqual(buffer.TextPoint{ .row = 0, .col = 12 }, highlighter.byteToPoint(12));
}

test "byteToPoint maps first middle final and exact line-start offsets" {
    const allocator = std.testing.allocator;
    var highlighter = Highlighter.init(allocator);
    defer highlighter.deinit();

    try highlighter.line_starts.appendSlice(allocator, &.{ 0, 6, 12, 19 });

    try std.testing.expectEqual(buffer.TextPoint{ .row = 0, .col = 0 }, highlighter.byteToPoint(0));
    try std.testing.expectEqual(buffer.TextPoint{ .row = 0, .col = 3 }, highlighter.byteToPoint(3));
    try std.testing.expectEqual(buffer.TextPoint{ .row = 0, .col = 5 }, highlighter.byteToPoint(5));
    try std.testing.expectEqual(buffer.TextPoint{ .row = 1, .col = 0 }, highlighter.byteToPoint(6));
    try std.testing.expectEqual(buffer.TextPoint{ .row = 1, .col = 4 }, highlighter.byteToPoint(10));
    try std.testing.expectEqual(buffer.TextPoint{ .row = 2, .col = 0 }, highlighter.byteToPoint(12));
    try std.testing.expectEqual(buffer.TextPoint{ .row = 3, .col = 0 }, highlighter.byteToPoint(19));
    try std.testing.expectEqual(buffer.TextPoint{ .row = 3, .col = 11 }, highlighter.byteToPoint(30));
}

test "byteToPoint uses binary-search behavior for large line tables" {
    const allocator = std.testing.allocator;
    var highlighter = Highlighter.init(allocator);
    defer highlighter.deinit();

    const line_count = 10_000;
    const stride = 17;
    try highlighter.line_starts.ensureTotalCapacity(allocator, line_count);
    for (0..line_count) |i| {
        highlighter.line_starts.appendAssumeCapacity(i * stride);
    }

    try std.testing.expectEqual(buffer.TextPoint{ .row = 0, .col = 0 }, highlighter.byteToPoint(0));
    try std.testing.expectEqual(buffer.TextPoint{ .row = 1234, .col = 9 }, highlighter.byteToPoint(1234 * stride + 9));
    try std.testing.expectEqual(buffer.TextPoint{ .row = 9999, .col = 0 }, highlighter.byteToPoint(9999 * stride));
    try std.testing.expectEqual(buffer.TextPoint{ .row = 9999, .col = 16 }, highlighter.byteToPoint(9999 * stride + 16));
}

test "languageFromFilename maps supported extensions" {
    try std.testing.expectEqual(LanguageId.zig, languageFromFilename("main.zig").?);
    try std.testing.expectEqual(LanguageId.go, languageFromFilename("main.go").?);
    try std.testing.expectEqual(LanguageId.toml, languageFromFilename("flamingo.toml").?);
    try std.testing.expectEqual(LanguageId.yaml, languageFromFilename("config.yaml").?);
    try std.testing.expectEqual(LanguageId.yaml, languageFromFilename("config.yml").?);
    try std.testing.expectEqual(LanguageId.json, languageFromFilename("package.json").?);
    try std.testing.expectEqual(LanguageId.markdown, languageFromFilename("README.md").?);
    try std.testing.expectEqual(LanguageId.markdown, languageFromFilename("README.markdown").?);
    try std.testing.expectEqual(LanguageId.proto, languageFromFilename("foo/bar/service.proto").?);
    try std.testing.expect(languageFromFilename("component.mdx") == null);
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
        .{ .filename = "service.proto", .source = "syntax = \"proto3\";\npackage foo.bar;\nmessage User { string name = 1; }\nservice UserService { rpc GetUser (GetUserRequest) returns (User); }\n// hi\n", .style = .keyword },
        .{ .filename = "service.proto", .source = "syntax = \"proto3\";\npackage foo.bar;\nmessage User { string name = 1; }\nservice UserService { rpc GetUser (GetUserRequest) returns (User); }\n// hi\n", .style = .type },
        .{ .filename = "service.proto", .source = "syntax = \"proto3\";\npackage foo.bar;\nmessage User { string name = 1; }\nservice UserService { rpc GetUser (GetUserRequest) returns (User); }\n// hi\n", .style = .function },
        .{ .filename = "service.proto", .source = "syntax = \"proto3\";\npackage foo.bar;\nmessage User { string name = 1; }\nservice UserService { rpc GetUser (GetUserRequest) returns (User); }\n// hi\n", .style = .string },
        .{ .filename = "service.proto", .source = "syntax = \"proto3\";\npackage foo.bar;\nmessage User { string name = 1; }\nservice UserService { rpc GetUser (GetUserRequest) returns (User); }\n// hi\n", .style = .number },
        .{ .filename = "service.proto", .source = "syntax = \"proto3\";\npackage foo.bar;\nmessage User { string name = 1; }\nservice UserService { rpc GetUser (GetUserRequest) returns (User); }\n// hi\n", .style = .comment },
        .{ .filename = "service.proto", .source = "syntax = \"proto3\";\nmessage User { optional string name = 1 [(google.api.http) = { get: \"/v1/users/{name}\" }]; }\n", .style = .property },
        .{ .filename = "service.proto", .source = "syntax = \"proto3\";\nmessage User { optional string name = 1 [(google.api.http) = { get: \"/v1/users/{name}\" }]; }\n", .style = .operator },
        .{ .filename = "service.proto", .source = "syntax = \"proto3\";\nmessage User { optional string name = 1 [(google.api.http) = { get: \"/v1/users/{name}\" }]; }\n", .style = .punctuation },
        .{ .filename = "README.md", .source = "# Heading\n\n> Quote\n\n- Item\n\n[Example](https://example.com)\n\n```zig\nconst x = 42;\n```\n", .style = .keyword },
        .{ .filename = "README.md", .source = "# Heading\n\n> Quote\n\n- Item\n\n[Example](https://example.com)\n\n```zig\nconst x = 42;\n```\n", .style = .string },
        .{ .filename = "README.md", .source = "# Heading\n\n> Quote\n\n- Item\n\n[Example](https://example.com)\n\n```zig\nconst x = 42;\n```\n", .style = .function },
        .{ .filename = "README.md", .source = "# Heading\n\n> Quote\n\n- Item\n\n[Example](https://example.com)\n\n```zig\nconst x = 42;\n```\n", .style = .comment },
        .{ .filename = "README.md", .source = "# Heading\n\n> Quote\n\n- Item\n\n[Example](https://example.com)\n\n```zig\nconst x = 42;\n```\n", .style = .punctuation },
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

test "markdown highlighter captures inline styles" {
    const allocator = std.testing.allocator;

    var buf = try buffer.Buffer.init(allocator);
    defer buf.deinit();
    try buf.setFilename("README.md");

    var first = buf.lines.orderedRemove(0);
    first.deinit();

    const source = "Some **bold** text, some *italic* text, `inline code`, and [a link](https://example.com).\n";
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        try buf.lines.append(allocator, try buffer.Line.fromSlice(allocator, line));
    }

    var highlighter = Highlighter.init(allocator);
    defer highlighter.deinit();
    try highlighter.ensureForBuffer(&buf);

    try std.testing.expect(highlighter.hasStyle(.constant));
    try std.testing.expect(highlighter.hasStyle(.type));
    try std.testing.expect(highlighter.hasStyle(.string));
    try std.testing.expect(highlighter.hasStyle(.function));
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

test "highlighter applies multiple contiguous tree-sitter edits" {
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

    try std.testing.expectEqual(@as(usize, 1), highlighter.full_reparse_count);
    try std.testing.expectEqual(@as(usize, 1), highlighter.incremental_reparse_count);
}

test "highlighter discards stale edit deltas when history is cleared" {
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
    buf.markChanged();
    try highlighter.ensureForBuffer(&buf);

    try std.testing.expectEqual(@as(usize, 2), highlighter.full_reparse_count);
    try std.testing.expectEqual(@as(usize, 0), highlighter.incremental_reparse_count);
}

test "highlighter keeps highlights aligned after edit before token" {
    const allocator = std.testing.allocator;

    var buf = try buffer.Buffer.init(allocator);
    defer buf.deinit();
    try buf.setFilename("main.zig");
    const source = "const value = 1;";
    for (source, 0..) |c, i| {
        try buf.insertChar(0, i, c);
    }

    var highlighter = Highlighter.init(allocator);
    defer highlighter.deinit();
    try highlighter.ensureForBuffer(&buf);
    try std.testing.expectEqual(Style.keyword, highlighter.styleAtLine(0, 0).?);

    try buf.insertNewline(0, 0);
    try highlighter.ensureForBuffer(&buf);

    try std.testing.expect(highlighter.styleAtLine(0, 0) == null);
    try std.testing.expectEqual(Style.keyword, highlighter.styleAtLine(1, 0).?);
}
