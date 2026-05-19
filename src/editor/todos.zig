const std = @import("std");
const workspace = @import("workspace.zig");
const global_search = @import("global_search.zig");

pub const max_code_todos: usize = 1000;
pub const max_file_size: usize = 2 * 1024 * 1024;

pub const TodoTag = enum {
    todo,
    fixme,
    hack,
    bug,
    note,
    xxx,
    optimize,
    perf,

    pub fn label(self: TodoTag) []const u8 {
        return switch (self) {
            .todo => "TODO",
            .fixme => "FIXME",
            .hack => "HACK",
            .bug => "BUG",
            .note => "NOTE",
            .xxx => "XXX",
            .optimize => "OPTIMIZE",
            .perf => "PERF",
        };
    }
};

pub const CodeTodo = struct {
    tag: TodoTag,
    open_path: []u8,
    display_path: []u8,
    line: usize,
    column: usize,
    text: []u8,

    pub fn deinit(self: *CodeTodo, allocator: std.mem.Allocator) void {
        allocator.free(self.open_path);
        allocator.free(self.display_path);
        allocator.free(self.text);
        self.* = undefined;
    }
};

pub const ManualTodoStatus = enum {
    open,
    done,

    pub fn label(self: ManualTodoStatus) []const u8 {
        return switch (self) {
            .open => "open",
            .done => "done",
        };
    }

    pub fn fromString(value: []const u8) ManualTodoStatus {
        if (std.mem.eql(u8, value, "done")) return .done;
        return .open;
    }
};

pub const ManualTodo = struct {
    id: []u8,
    title: []u8,
    body: []u8,
    status: ManualTodoStatus,
    created_at_unix_ms: i64,
    updated_at_unix_ms: i64,

    pub fn deinit(self: *ManualTodo, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.title);
        allocator.free(self.body);
        self.* = undefined;
    }
};

pub const ScanStatus = enum {
    not_scanned,
    scanned,
    scan_failed,
};

pub const TodoLineMatch = struct {
    tag: TodoTag,
    column: usize,
    text: []const u8,
};

pub const TodoPanel = struct {
    visible: bool = false,
    focused: bool = false,
    selected_index: usize = 0,
    scroll_offset: usize = 0,
    code_items: std.ArrayListUnmanaged(CodeTodo) = .empty,
    manual_items: std.ArrayListUnmanaged(ManualTodo) = .empty,
    last_scan_root: ?[]u8 = null,
    scan_status: ScanStatus = .not_scanned,
    next_id_counter: u64 = 0,

    pub fn deinit(self: *TodoPanel, allocator: std.mem.Allocator) void {
        self.clearCode(allocator);
        self.clearManual(allocator);
        self.code_items.deinit(allocator);
        self.manual_items.deinit(allocator);
        if (self.last_scan_root) |root| allocator.free(root);
        self.* = .{};
    }

    pub fn clearCode(self: *TodoPanel, allocator: std.mem.Allocator) void {
        for (self.code_items.items) |*item| item.deinit(allocator);
        self.code_items.clearRetainingCapacity();
        if (self.last_scan_root) |root| {
            allocator.free(root);
            self.last_scan_root = null;
        }
        self.scan_status = .not_scanned;
        self.clampSelection();
    }

    pub fn clearManual(self: *TodoPanel, allocator: std.mem.Allocator) void {
        for (self.manual_items.items) |*item| item.deinit(allocator);
        self.manual_items.clearRetainingCapacity();
        self.clampSelection();
    }

    pub fn totalItems(self: *const TodoPanel) usize {
        return self.code_items.items.len + self.manual_items.items.len;
    }

    pub fn selectedKind(self: *const TodoPanel) ?union(enum) { code: usize, manual: usize } {
        if (self.totalItems() == 0) return null;
        if (self.selected_index < self.code_items.items.len) return .{ .code = self.selected_index };
        return .{ .manual = self.selected_index - self.code_items.items.len };
    }

    pub fn moveDown(self: *TodoPanel) void {
        const total = self.totalItems();
        if (total == 0) return;
        self.selected_index = @min(self.selected_index + 1, total - 1);
    }

    pub fn moveUp(self: *TodoPanel) void {
        if (self.selected_index > 0) self.selected_index -= 1;
    }

    pub fn clampSelection(self: *TodoPanel) void {
        const total = self.totalItems();
        if (total == 0) {
            self.selected_index = 0;
            self.scroll_offset = 0;
        } else if (self.selected_index >= total) {
            self.selected_index = total - 1;
        }
    }

    pub fn adjustScroll(self: *TodoPanel, body_rows: usize) void {
        if (body_rows == 0 or self.totalItems() == 0) {
            self.scroll_offset = 0;
            return;
        }
        if (self.selected_index < self.scroll_offset) {
            self.scroll_offset = self.selected_index;
        } else if (self.selected_index >= self.scroll_offset + body_rows) {
            self.scroll_offset = self.selected_index - body_rows + 1;
        }
    }
};

pub const ManualStoreError = error{
    NoWorkspace,
    InvalidWorkspace,
    MalformedTodosJson,
};

pub fn manualTodosPath(allocator: std.mem.Allocator, io: std.Io, root_path: []const u8) ![]u8 {
    const status = try workspace.detectWorkspace(allocator, io, root_path);
    switch (status) {
        .valid => return std.fs.path.join(allocator, &.{ root_path, workspace.directory_name, "todos.json" }),
        .none => return error.NoWorkspace,
        .invalid_path_exists => return error.InvalidWorkspace,
    }
}

pub fn loadManualTodos(allocator: std.mem.Allocator, io: std.Io, root_path: []const u8, out: *std.ArrayListUnmanaged(ManualTodo)) !void {
    const path = try manualTodosPath(allocator, io, root_path);
    defer allocator.free(path);

    const contents = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, std.Io.Limit.limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer allocator.free(contents);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, contents, .{}) catch return error.MalformedTodosJson;
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |object| object,
        else => return error.MalformedTodosJson,
    };
    const version = jsonInteger(root.get("version") orelse return error.MalformedTodosJson) orelse return error.MalformedTodosJson;
    if (version != 1) return error.MalformedTodosJson;
    const items = switch (root.get("items") orelse return error.MalformedTodosJson) {
        .array => |array| array.items,
        else => return error.MalformedTodosJson,
    };

    for (items) |value| {
        const item_object = switch (value) {
            .object => |object| object,
            else => return error.MalformedTodosJson,
        };
        const id = jsonString(item_object.get("id") orelse return error.MalformedTodosJson) orelse return error.MalformedTodosJson;
        const title = jsonString(item_object.get("title") orelse return error.MalformedTodosJson) orelse return error.MalformedTodosJson;
        const body = jsonString(item_object.get("body") orelse .{ .string = "" }) orelse "";
        const status_text = jsonString(item_object.get("status") orelse .{ .string = "open" }) orelse "open";
        const created = jsonInteger(item_object.get("created_at_unix_ms") orelse .{ .integer = 0 }) orelse 0;
        const updated = jsonInteger(item_object.get("updated_at_unix_ms") orelse .{ .integer = created }) orelse created;

        const owned_id = try allocator.dupe(u8, id);
        errdefer allocator.free(owned_id);
        const owned_title = try allocator.dupe(u8, title);
        errdefer allocator.free(owned_title);
        const owned_body = try allocator.dupe(u8, body);
        errdefer allocator.free(owned_body);
        try out.append(allocator, .{
            .id = owned_id,
            .title = owned_title,
            .body = owned_body,
            .status = ManualTodoStatus.fromString(status_text),
            .created_at_unix_ms = created,
            .updated_at_unix_ms = updated,
        });
    }
}

pub fn saveManualTodos(allocator: std.mem.Allocator, io: std.Io, root_path: []const u8, items: []const ManualTodo) !void {
    const path = try manualTodosPath(allocator, io, root_path);
    defer allocator.free(path);
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(tmp_path);

    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\n  \"version\": 1,\n  \"items\": [\n");
    for (items, 0..) |item, i| {
        if (i > 0) try out.writer.writeAll(",\n");
        try out.writer.writeAll("    {\n");
        try writeJsonField(&out.writer, "id", item.id, true);
        try writeJsonField(&out.writer, "title", item.title, true);
        try writeJsonField(&out.writer, "body", item.body, true);
        try writeJsonField(&out.writer, "status", item.status.label(), true);
        try out.writer.print("      \"created_at_unix_ms\": {d},\n", .{item.created_at_unix_ms});
        try out.writer.print("      \"updated_at_unix_ms\": {d}\n", .{item.updated_at_unix_ms});
        try out.writer.writeAll("    }");
    }
    try out.writer.writeAll("\n  ]\n}\n");

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp_path, .data = out.written() });
    try std.Io.Dir.cwd().rename(tmp_path, std.Io.Dir.cwd(), path, io);
}

pub fn appendManualTodo(panel: *TodoPanel, allocator: std.mem.Allocator, io: std.Io, title: []const u8) !void {
    const now = std.Io.Timestamp.now(io, .real).toMilliseconds();
    panel.next_id_counter +%= 1;
    const id = try std.fmt.allocPrint(allocator, "{d}-{d}", .{ now, panel.next_id_counter });
    errdefer allocator.free(id);
    const owned_title = try allocator.dupe(u8, title);
    errdefer allocator.free(owned_title);
    const body = try allocator.dupe(u8, "");
    errdefer allocator.free(body);
    try panel.manual_items.append(allocator, .{
        .id = id,
        .title = owned_title,
        .body = body,
        .status = .open,
        .created_at_unix_ms = now,
        .updated_at_unix_ms = now,
    });
    panel.selected_index = panel.code_items.items.len + panel.manual_items.items.len - 1;
}

pub fn editManualTodo(panel: *TodoPanel, allocator: std.mem.Allocator, io: std.Io, manual_index: usize, title: []const u8) !void {
    if (manual_index >= panel.manual_items.items.len) return;
    const owned_title = try allocator.dupe(u8, title);
    const item = &panel.manual_items.items[manual_index];
    allocator.free(item.title);
    item.title = owned_title;
    item.updated_at_unix_ms = std.Io.Timestamp.now(io, .real).toMilliseconds();
}

pub fn deleteManualTodo(panel: *TodoPanel, allocator: std.mem.Allocator, manual_index: usize) void {
    if (manual_index >= panel.manual_items.items.len) return;
    var item = panel.manual_items.orderedRemove(manual_index);
    item.deinit(allocator);
    panel.clampSelection();
}

pub fn toggleManualTodo(panel: *TodoPanel, io: std.Io, manual_index: usize) void {
    if (manual_index >= panel.manual_items.items.len) return;
    const item = &panel.manual_items.items[manual_index];
    item.status = if (item.status == .open) .done else .open;
    item.updated_at_unix_ms = std.Io.Timestamp.now(io, .real).toMilliseconds();
}

pub fn scanRoot(allocator: std.mem.Allocator, io: std.Io, root_path: []const u8, out: *std.ArrayListUnmanaged(CodeTodo)) !void {
    var dir = std.Io.Dir.cwd().openDir(io, root_path, .{ .iterate = true }) catch return error.RootOpenFailed;
    dir.close(io);
    try scanDirectory(allocator, io, root_path, root_path, out);
}

fn scanDirectory(allocator: std.mem.Allocator, io: std.Io, root_path: []const u8, dir_path: []const u8, out: *std.ArrayListUnmanaged(CodeTodo)) !void {
    if (out.items.len >= max_code_todos) return;
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var it = dir.iterate();
    while (true) {
        const maybe_entry = it.next(io) catch return;
        const entry = maybe_entry orelse break;
        if (shouldIgnoreName(entry.name)) continue;

        const open_path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
        defer allocator.free(open_path);

        switch (entry.kind) {
            .directory => try scanDirectory(allocator, io, root_path, open_path, out),
            .file => try scanFile(allocator, io, root_path, open_path, out),
            else => {},
        }
        if (out.items.len >= max_code_todos) return;
    }
}

fn scanFile(allocator: std.mem.Allocator, io: std.Io, root_path: []const u8, open_path: []const u8, out: *std.ArrayListUnmanaged(CodeTodo)) !void {
    const stat = std.Io.Dir.cwd().statFile(io, open_path, .{}) catch return;
    if (stat.size > max_file_size) return;

    const contents = std.Io.Dir.cwd().readFileAlloc(io, open_path, allocator, std.Io.Limit.limited(max_file_size)) catch return;
    defer allocator.free(contents);
    if (global_search.isLikelyBinary(contents)) return;

    const display_path = relativeDisplayPath(root_path, open_path);
    var row: usize = 0;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line_raw| : (row += 1) {
        var line = line_raw;
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        if (findTodoInLine(line)) |found| {
            const owned_open = try allocator.dupe(u8, open_path);
            errdefer allocator.free(owned_open);
            const owned_display = try allocator.dupe(u8, display_path);
            errdefer allocator.free(owned_display);
            const owned_text = try allocator.dupe(u8, found.text);
            errdefer allocator.free(owned_text);
            try out.append(allocator, .{
                .tag = found.tag,
                .open_path = owned_open,
                .display_path = owned_display,
                .line = row + 1,
                .column = found.column + 1,
                .text = owned_text,
            });
            if (out.items.len >= max_code_todos) return;
        }
    }
}

pub fn findTodoInLine(line: []const u8) ?TodoLineMatch {
    const markers = [_][]const u8{ "//", "#", "--", "<!--", "/*" };
    var best: ?TodoLineMatch = null;
    var best_col: usize = std.math.maxInt(usize);

    for (markers) |marker| {
        const marker_col = std.mem.indexOf(u8, line, marker) orelse continue;
        const after_marker = line[marker_col + marker.len ..];
        if (findTag(after_marker)) |tag_match| {
            const col = marker_col + marker.len + tag_match.offset;
            if (col < best_col) {
                best_col = col;
                var text = std.mem.trim(u8, tag_match.rest, " \t:-");
                if (std.mem.endsWith(u8, text, "-->")) text = std.mem.trimEnd(u8, text[0 .. text.len - 3], " \t");
                if (std.mem.endsWith(u8, text, "*/")) text = std.mem.trimEnd(u8, text[0 .. text.len - 2], " \t");
                best = .{ .tag = tag_match.tag, .column = col, .text = text };
            }
        }
    }
    return best;
}

fn findTag(text: []const u8) ?struct { tag: TodoTag, offset: usize, rest: []const u8 } {
    var offset: usize = 0;
    while (offset < text.len) : (offset += 1) {
        if (!std.ascii.isWhitespace(text[offset])) break;
    }

    const candidates = [_]struct { label: []const u8, tag: TodoTag }{
        .{ .label = "OPTIMIZE", .tag = .optimize },
        .{ .label = "FIXME", .tag = .fixme },
        .{ .label = "TODO", .tag = .todo },
        .{ .label = "HACK", .tag = .hack },
        .{ .label = "NOTE", .tag = .note },
        .{ .label = "PERF", .tag = .perf },
        .{ .label = "BUG", .tag = .bug },
        .{ .label = "XXX", .tag = .xxx },
    };

    for (candidates) |candidate| {
        if (text.len < offset + candidate.label.len) continue;
        const maybe = text[offset .. offset + candidate.label.len];
        if (!std.ascii.eqlIgnoreCase(maybe, candidate.label)) continue;
        if (text.len > offset + candidate.label.len) {
            const next = text[offset + candidate.label.len];
            if (std.ascii.isAlphanumeric(next) or next == '_') continue;
        }
        return .{
            .tag = candidate.tag,
            .offset = offset,
            .rest = text[offset + candidate.label.len ..],
        };
    }
    return null;
}

fn shouldIgnoreName(name: []const u8) bool {
    const ignored = [_][]const u8{
        ".",
        "..",
        ".git",
        ".flamingo",
        "node_modules",
        "zig-cache",
        ".zig-cache",
        "zig-pkg",
        "zig-out",
        "target",
        "dist",
        "build",
        ".DS_Store",
    };
    for (ignored) |candidate| {
        if (std.mem.eql(u8, name, candidate)) return true;
    }
    return false;
}

fn relativeDisplayPath(root_path: []const u8, open_path: []const u8) []const u8 {
    if (std.mem.eql(u8, root_path, ".")) {
        if (std.mem.startsWith(u8, open_path, "./")) return open_path[2..];
        return open_path;
    }
    if (std.mem.startsWith(u8, open_path, root_path) and open_path.len > root_path.len) {
        var relative = open_path[root_path.len..];
        if (relative.len > 0 and (relative[0] == '/' or relative[0] == std.fs.path.sep)) relative = relative[1..];
        if (relative.len > 0) return relative;
    }
    return open_path;
}

fn jsonString(value: std.json.Value) ?[]const u8 {
    return switch (value) {
        .string => |string| string,
        else => null,
    };
}

fn jsonInteger(value: std.json.Value) ?i64 {
    return switch (value) {
        .integer => |integer| @intCast(integer),
        else => null,
    };
}

fn writeJsonField(writer: anytype, name: []const u8, value: []const u8, comma: bool) !void {
    try writer.print("      \"{s}\": \"", .{name});
    try writeJsonStringContents(writer, value);
    try writer.writeAll(if (comma) "\",\n" else "\"\n");
}

fn writeJsonStringContents(writer: anytype, value: []const u8) !void {
    for (value) |ch| {
        switch (ch) {
            '\\' => try writer.writeAll("\\\\"),
            '"' => try writer.writeAll("\\\""),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (ch < 0x20) {
                    try writer.print("\\u{X:0>4}", .{ch});
                } else {
                    try writer.writeByte(ch);
                }
            },
        }
    }
}

test "todo scanner recognizes supported comment styles" {
    const cases = [_]struct {
        line: []const u8,
        tag: TodoTag,
        text: []const u8,
    }{
        .{ .line = "// TODO: refactor this", .tag = .todo, .text = "refactor this" },
        .{ .line = "# FIXME handle errors", .tag = .fixme, .text = "handle errors" },
        .{ .line = "-- HACK temporary", .tag = .hack, .text = "temporary" },
        .{ .line = "<!-- NOTE: important detail -->", .tag = .note, .text = "important detail" },
        .{ .line = "/* PERF: make fast */", .tag = .perf, .text = "make fast" },
    };
    for (cases) |case| {
        const found = findTodoInLine(case.line) orelse return error.ExpectedTodo;
        try std.testing.expectEqual(case.tag, found.tag);
        try std.testing.expectEqualStrings(case.text, found.text);
    }
}

test "todo scanner ignores excluded directories and .flamingo" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, ".flamingo");
    try tmp.dir.writeFile(io, .{ .sub_path = ".flamingo/ignored.zig", .data = "// TODO ignored\n" });
    try tmp.dir.createDirPath(io, "node_modules");
    try tmp.dir.writeFile(io, .{ .sub_path = "node_modules/ignored.zig", .data = "// TODO ignored\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "main.zig", .data = "// TODO visible\n" });

    const root_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root_path);

    var items: std.ArrayListUnmanaged(CodeTodo) = .empty;
    defer {
        for (items.items) |*item| item.deinit(allocator);
        items.deinit(allocator);
    }
    try scanRoot(allocator, io, root_path, &items);
    try std.testing.expectEqual(@as(usize, 1), items.items.len);
    try std.testing.expectEqualStrings("main.zig", items.items[0].display_path);
}

test "manual todo load save round trip and invalid workspace handling" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const root_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root_path);

    var missing: std.ArrayListUnmanaged(ManualTodo) = .empty;
    defer missing.deinit(allocator);
    try std.testing.expectError(error.NoWorkspace, loadManualTodos(allocator, io, root_path, &missing));

    try tmp.dir.createDirPath(io, ".flamingo");
    var panel = TodoPanel{};
    defer panel.deinit(allocator);
    try appendManualTodo(&panel, allocator, io, "Write README");
    try saveManualTodos(allocator, io, root_path, panel.manual_items.items);

    var loaded: std.ArrayListUnmanaged(ManualTodo) = .empty;
    defer {
        for (loaded.items) |*item| item.deinit(allocator);
        loaded.deinit(allocator);
    }
    try loadManualTodos(allocator, io, root_path, &loaded);
    try std.testing.expectEqual(@as(usize, 1), loaded.items.len);
    try std.testing.expectEqualStrings("Write README", loaded.items[0].title);
}

test "manual todo storage rejects file marker workspace" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = ".flamingo", .data = "not a directory" });
    const root_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root_path);

    var items: [0]ManualTodo = .{};
    try std.testing.expectError(error.InvalidWorkspace, saveManualTodos(allocator, io, root_path, &items));
}
