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

    pub fn init(allocator: std.mem.Allocator) Highlighter {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Highlighter) void {
        self.resetLanguageState();
        self.spans.deinit(self.allocator);
        self.line_starts.deinit(self.allocator);
        if (self.source.len > 0) {
            self.allocator.free(self.source);
            self.source = &.{};
        }
    }

    pub fn ensureForBuffer(self: *Highlighter, buf: *const buffer.Buffer) !void {
        const filename = buf.filename orelse {
            self.resetAll();
            return;
        };

        const next_language = languageFromFilename(filename) orelse {
            self.resetAll();
            return;
        };

        if (self.language == next_language and self.parsed_revision == buf.revision) {
            return;
        }

        if (self.language != next_language) {
            self.resetLanguageState();
            self.language = next_language;
            self.parser = ts.Parser.create();
            try self.parser.?.setLanguage(languagePtr(next_language));
            self.query = createQuery(next_language) catch null;
        }

        const content = try buf.toString(self.allocator);
        errdefer self.allocator.free(content);

        self.clearParsedState();
        self.source = content;
        try self.rebuildLineStarts();

        const parser = self.parser orelse return;
        const tree = parser.parseString(self.source, null) orelse return;
        self.tree = tree;
        self.parsed_revision = buf.revision;

        const query = self.query orelse return;
        try self.collectSpans(query, tree.rootNode());
    }

    pub fn lineStartByte(self: *const Highlighter, row: usize) usize {
        if (row >= self.line_starts.items.len) return 0;
        return self.line_starts.items[row];
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

    fn collectSpans(self: *Highlighter, query: *ts.Query, root: ts.Node) !void {
        var cursor = ts.QueryCursor.create();
        defer cursor.destroy();
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

            try self.spans.append(self.allocator, .{
                .start = start,
                .end = end,
                .style = style,
            });
        }

        std.mem.sort(HighlightSpan, self.spans.items, {}, lessThanSpan);
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
        self.parsed_revision = null;
    }
};

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
