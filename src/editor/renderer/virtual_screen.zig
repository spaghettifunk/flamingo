const std = @import("std");
const terminal = @import("../../terminal.zig");

pub const RenderInvalidation = enum {
    none,
    partial,
    full,
};

pub const RenderStyle = enum {
    normal,
    editor_bg,
    dim,
    gutter_current,
    keyword,
    string,
    comment,
    number,
    constant,
    type_name,
    function_name,
    property,
    operator,
    punctuation,
    selection,
    search_match,
    search_active,
    status_normal,
    status_insert,
    status_command,
    search_status,
    error_style,
    completion,
    completion_selected,
    command_popup,
    command_popup_border,
    global_search_popup_border,
    command_popup_title,
    command_popup_prompt,
    command_popup_selected,
    global_search_file,
    global_search_file_selected,
    global_search_result,
    global_search_result_selected,
    explorer_bg,
    explorer_header,
    explorer_folder,
    explorer_zig,
    explorer_config,
    explorer_md,
    explorer_license,
    explorer_file,
    explorer_dim,
    explorer_selected,
    explorer_selected_focus,
    git_modified,
    git_ignored,
    status_bg,
    status_mode_normal,
    status_mode_insert,
    status_mode_command,
    status_mode_search,
    status_branch,
    status_file,
    status_context,
    status_right,
    status_error,
    status_sep_normal,
    status_sep_insert,
    status_sep_command,
    status_sep_search,
    status_sep_branch,
    status_sep_file,
    status_sep_context,
    status_sep_right,
    status_sep_error,

    pub fn ansi(self: RenderStyle) []const u8 {
        return switch (self) {
            .normal => "\x1b[0m",
            .editor_bg => "\x1b[48;2;30;32;48m\x1b[38;2;204;211;245m",
            .dim => "\x1b[2;37m",
            .gutter_current => "\x1b[33;1m",
            .keyword => "\x1b[38;5;177m",
            .string => "\x1b[38;5;150m",
            .comment => "\x1b[38;5;244m",
            .number => "\x1b[38;5;216m",
            .constant => "\x1b[38;5;203m",
            .type_name => "\x1b[38;5;116m",
            .function_name => "\x1b[38;5;111m",
            .property => "\x1b[38;5;180m",
            .operator => "\x1b[38;5;250m",
            .punctuation => "\x1b[38;5;245m",
            .selection => "\x1b[48;5;239m",
            .search_match => "\x1b[48;5;228m\x1b[30m",
            .search_active => "\x1b[48;5;214m\x1b[30m",
            .status_normal => "\x1b[48;5;121m\x1b[30m",
            .status_insert => "\x1b[48;5;117m\x1b[30m",
            .status_command => "\x1b[48;5;220m\x1b[30m",
            .search_status => "\x1b[48;5;228m\x1b[30m",
            .error_style => "\x1b[31;1m",
            .completion => "\x1b[48;5;236m\x1b[38;5;250m",
            .completion_selected => "\x1b[48;5;25m\x1b[38;5;255m",
            .command_popup => "\x1b[48;5;235m\x1b[38;5;255m",
            .command_popup_border => "\x1b[48;5;235m\x1b[38;5;121m",
            .global_search_popup_border => "\x1b[48;5;235m\x1b[38;5;220m",
            .command_popup_title => "\x1b[48;5;235m\x1b[38;5;250m",
            .command_popup_prompt => "\x1b[48;5;235m\x1b[38;5;250m",
            .command_popup_selected => "\x1b[48;5;238m\x1b[38;5;255m",
            .global_search_file => "\x1b[48;5;235m\x1b[38;5;220m",
            .global_search_file_selected => "\x1b[48;5;238m\x1b[38;5;220m",
            .global_search_result => "\x1b[48;5;235m\x1b[38;5;121m",
            .global_search_result_selected => "\x1b[48;5;238m\x1b[38;5;121m",
            .explorer_bg => "\x1b[48;2;30;32;48m\x1b[38;2;148;156;184m",
            .explorer_header => "\x1b[48;2;30;32;48m\x1b[38;2;116;158;231m\x1b[1m",
            .explorer_folder => "\x1b[48;2;30;32;48m\x1b[38;2;116;158;231m\x1b[1m",
            .explorer_zig => "\x1b[48;2;30;32;48m\x1b[38;2;255;139;97m",
            .explorer_config => "\x1b[48;2;30;32;48m\x1b[38;2;255;139;97m",
            .explorer_md => "\x1b[48;2;30;32;48m\x1b[38;2;166;183;255m",
            .explorer_license => "\x1b[48;2;30;32;48m\x1b[38;2;125;224;167m",
            .explorer_file => "\x1b[48;2;30;32;48m\x1b[38;2;185;193;224m",
            .explorer_dim => "\x1b[48;2;30;32;48m\x1b[38;2;91;98;125m\x1b[2m",
            .explorer_selected => "\x1b[48;2;48;52;78m\x1b[38;2;204;211;245m",
            .explorer_selected_focus => "\x1b[48;2;58;63;94m\x1b[38;2;222;226;255m",
            .git_modified => "\x1b[48;2;30;32;48m\x1b[38;2;255;139;97m",
            .git_ignored => "\x1b[48;2;30;32;48m\x1b[38;2;91;98;125m",
            .status_bg => "\x1b[48;2;30;32;48m\x1b[38;2;148;156;184m",
            .status_mode_normal => "\x1b[48;2;116;158;231m\x1b[38;2;17;19;31m\x1b[1m",
            .status_mode_insert => "\x1b[48;2;125;224;167m\x1b[38;2;17;19;31m\x1b[1m",
            .status_mode_command => "\x1b[48;2;238;212;159m\x1b[38;2;17;19;31m\x1b[1m",
            .status_mode_search => "\x1b[48;2;137;180;250m\x1b[38;2;17;19;31m\x1b[1m",
            .status_branch => "\x1b[48;2;43;47;70m\x1b[38;2;116;158;231m",
            .status_file => "\x1b[48;2;35;38;58m\x1b[38;2;204;211;245m",
            .status_context => "\x1b[48;2;35;38;58m\x1b[38;2;94;234;212m",
            .status_right => "\x1b[48;2;43;47;70m\x1b[38;2;166;183;255m\x1b[1m",
            .status_error => "\x1b[48;2;243;139;168m\x1b[38;2;17;19;31m\x1b[1m",
            .status_sep_normal => "\x1b[48;2;43;47;70m\x1b[38;2;116;158;231m",
            .status_sep_insert => "\x1b[48;2;43;47;70m\x1b[38;2;125;224;167m",
            .status_sep_command => "\x1b[48;2;43;47;70m\x1b[38;2;238;212;159m",
            .status_sep_search => "\x1b[48;2;43;47;70m\x1b[38;2;137;180;250m",
            .status_sep_branch => "\x1b[48;2;35;38;58m\x1b[38;2;43;47;70m",
            .status_sep_file => "\x1b[48;2;35;38;58m\x1b[38;2;35;38;58m",
            .status_sep_context => "\x1b[48;2;30;32;48m\x1b[38;2;35;38;58m",
            .status_sep_right => "\x1b[48;2;30;32;48m\x1b[38;2;43;47;70m",
            .status_sep_error => "\x1b[48;2;35;38;58m\x1b[38;2;243;139;168m",
        };
    }
};

pub const RenderCell = struct {
    bytes: u32 = ' ',
    len: u3 = 1,
    style: RenderStyle = .normal,

    pub fn eql(self: RenderCell, other: RenderCell) bool {
        return self.len == other.len and
            self.style == other.style and
            self.bytes == other.bytes;
    }

    pub fn fromAscii(ch: u8, style: RenderStyle) RenderCell {
        return .{ .bytes = ch, .len = 1, .style = style };
    }

    pub fn fromGlyph(glyph: []const u8, style: RenderStyle) RenderCell {
        if (glyph.len == 1) return fromAscii(glyph[0], style);
        const len = @min(glyph.len, @sizeOf(u32));
        var bytes: u32 = 0;
        for (glyph[0..len], 0..) |byte, i| {
            bytes |= @as(u32, byte) << @intCast(i * 8);
        }
        return .{ .bytes = bytes, .len = @intCast(@max(len, 1)), .style = style };
    }

    pub fn glyphBytes(self: *const RenderCell) []const u8 {
        return std.mem.asBytes(&self.bytes)[0..self.len];
    }
};

pub const VirtualScreen = struct {
    allocator: std.mem.Allocator,
    width: usize = 0,
    height: usize = 0,
    cells: std.ArrayList(RenderCell) = .empty,

    pub fn init(allocator: std.mem.Allocator) VirtualScreen {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *VirtualScreen) void {
        self.cells.deinit(self.allocator);
    }

    pub fn resize(self: *VirtualScreen, width: usize, height: usize) !bool {
        if (self.width == width and self.height == height and self.cells.items.len == width * height) {
            return false;
        }

        self.width = width;
        self.height = height;
        try self.cells.resize(self.allocator, width * height);
        self.clear();
        return true;
    }

    pub fn clear(self: *VirtualScreen) void {
        @memset(self.cells.items, RenderCell{});
    }

    pub fn index(self: *const VirtualScreen, row: usize, col: usize) usize {
        return row * self.width + col;
    }

    pub fn set(self: *VirtualScreen, row: usize, col: usize, ch: u8, style: RenderStyle) void {
        if (row >= self.height or col >= self.width) return;
        self.cells.items[self.index(row, col)] = RenderCell.fromAscii(ch, style);
    }

    pub fn setGlyph(self: *VirtualScreen, row: usize, col: usize, glyph: []const u8, style: RenderStyle) void {
        if (row >= self.height or col >= self.width) return;
        self.cells.items[self.index(row, col)] = RenderCell.fromGlyph(glyph, style);
    }

    pub fn writeText(self: *VirtualScreen, row: usize, col: usize, text: []const u8, style: RenderStyle) void {
        if (row >= self.height or col >= self.width) return;
        var x = col;
        var i: usize = 0;
        while (i < text.len) {
            if (x >= self.width) break;
            if (text[i] < 0x80) {
                self.set(row, x, text[i], style);
                i += 1;
            } else {
                const len = utf8CellLen(text[i]);
                const end = @min(i + len, text.len);
                self.setGlyph(row, x, text[i..end], style);
                i = end;
            }
            x += 1;
        }
    }

    pub fn fillRow(self: *VirtualScreen, row: usize, ch: u8, style: RenderStyle) void {
        if (row >= self.height) return;
        for (0..self.width) |col| {
            self.set(row, col, ch, style);
        }
    }
};

pub fn utf8CellLen(first: u8) usize {
    return if (first & 0xe0 == 0xc0)
        2
    else if (first & 0xf0 == 0xe0)
        3
    else if (first & 0xf8 == 0xf0)
        4
    else
        1;
}

pub fn displayCellCount(text: []const u8) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (count += 1) {
        i += @min(utf8CellLen(text[i]), text.len - i);
    }
    return count;
}

pub const VirtualScreenRenderer = struct {
    allocator: std.mem.Allocator,
    previous: VirtualScreen,
    invalidation: RenderInvalidation = .full,

    pub fn init(allocator: std.mem.Allocator) VirtualScreenRenderer {
        return .{
            .allocator = allocator,
            .previous = VirtualScreen.init(allocator),
        };
    }

    pub fn deinit(self: *VirtualScreenRenderer) void {
        self.previous.deinit();
    }

    pub fn invalidate(self: *VirtualScreenRenderer, invalidation: RenderInvalidation) void {
        if (invalidation == .full or self.invalidation == .none) {
            self.invalidation = invalidation;
        }
    }

    pub fn emit(self: *VirtualScreenRenderer, writer: anytype, current: *const VirtualScreen) !usize {
        const size_changed = self.previous.width != current.width or self.previous.height != current.height;
        const full = size_changed or self.invalidation == .full;
        var bytes: usize = 0;

        if (full) {
            try terminal.clearScreen(writer);
            bytes += "\x1b[2J\x1b[H".len;
        }

        if (size_changed) {
            _ = try self.previous.resize(current.width, current.height);
        }

        var active_style: RenderStyle = .normal;
        for (0..current.height) |row| {
            var col: usize = 0;
            while (col < current.width) {
                const idx = current.index(row, col);
                const cell = current.cells.items[idx];
                const prev_cell = self.previous.cells.items[idx];
                if (!full and cell.eql(prev_cell)) {
                    col += 1;
                    continue;
                }

                try terminal.moveCursor(writer, row + 1, col + 1);
                bytes += 16;

                while (col < current.width) : (col += 1) {
                    const run_idx = current.index(row, col);
                    const run_cell = current.cells.items[run_idx];
                    const run_prev = self.previous.cells.items[run_idx];
                    if (!full and run_cell.eql(run_prev)) break;

                    if (run_cell.style != active_style) {
                        const ansi = run_cell.style.ansi();
                        try writer.writeAll(ansi);
                        bytes += ansi.len;
                        active_style = run_cell.style;
                    }
                    try writer.writeAll(run_cell.glyphBytes());
                    bytes += run_cell.len;
                    self.previous.cells.items[run_idx] = run_cell;
                }
            }
        }

        if (active_style != .normal) {
            const reset = RenderStyle.normal.ansi();
            try writer.writeAll(reset);
            bytes += reset.len;
        }

        self.invalidation = .none;
        return bytes;
    }
};

test "virtual screen unchanged frame emits no content changes" {
    const allocator = std.testing.allocator;
    var current = VirtualScreen.init(allocator);
    defer current.deinit();
    _ = try current.resize(8, 2);
    current.writeText(0, 0, "hello", .normal);

    var renderer = VirtualScreenRenderer.init(allocator);
    defer renderer.deinit();

    var out = std.ArrayListUnmanaged(u8).empty;
    defer out.deinit(allocator);
    var aw = std.Io.Writer.Allocating.fromArrayList(allocator, &out);
    defer aw.deinit();

    _ = try renderer.emit(&aw.writer, &current);
    aw.clearRetainingCapacity();
    _ = try renderer.emit(&aw.writer, &current);
    try std.testing.expectEqual(@as(usize, 0), aw.written().len);
}

test "virtual screen groups changed cells and clears shorter rows" {
    const allocator = std.testing.allocator;
    var current = VirtualScreen.init(allocator);
    defer current.deinit();
    _ = try current.resize(6, 1);
    current.writeText(0, 0, "abcdef", .normal);

    var renderer = VirtualScreenRenderer.init(allocator);
    defer renderer.deinit();

    var out = std.ArrayListUnmanaged(u8).empty;
    defer out.deinit(allocator);
    var aw = std.Io.Writer.Allocating.fromArrayList(allocator, &out);
    defer aw.deinit();

    _ = try renderer.emit(&aw.writer, &current);
    current.clear();
    current.writeText(0, 0, "ab", .normal);

    aw.clearRetainingCapacity();
    _ = try renderer.emit(&aw.writer, &current);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "    ") != null);
}

test "virtual screen stores and emits utf8 glyph cells" {
    const allocator = std.testing.allocator;
    var current = VirtualScreen.init(allocator);
    defer current.deinit();
    _ = try current.resize(4, 1);
    current.writeText(0, 0, "a", .explorer_zig);

    try std.testing.expectEqual(@as(usize, 2), displayCellCount("a"));
    try std.testing.expectEqualStrings("", current.cells.items[current.index(0, 0)].glyphBytes());
    try std.testing.expectEqualStrings("a", current.cells.items[current.index(0, 1)].glyphBytes());

    var renderer = VirtualScreenRenderer.init(allocator);
    defer renderer.deinit();

    var out = std.ArrayListUnmanaged(u8).empty;
    defer out.deinit(allocator);
    var aw = std.Io.Writer.Allocating.fromArrayList(allocator, &out);
    defer aw.deinit();

    _ = try renderer.emit(&aw.writer, &current);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "a") != null);
}

test "virtual screen diff emits changed utf8 glyph without corrupting bytes" {
    const allocator = std.testing.allocator;
    var current = VirtualScreen.init(allocator);
    defer current.deinit();
    _ = try current.resize(3, 1);
    current.writeText(0, 0, "", .explorer_zig);

    var renderer = VirtualScreenRenderer.init(allocator);
    defer renderer.deinit();

    var out = std.ArrayListUnmanaged(u8).empty;
    defer out.deinit(allocator);
    var aw = std.Io.Writer.Allocating.fromArrayList(allocator, &out);
    defer aw.deinit();

    _ = try renderer.emit(&aw.writer, &current);
    current.writeText(0, 0, "", .explorer_md);

    aw.clearRetainingCapacity();
    _ = try renderer.emit(&aw.writer, &current);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "") == null);
}

test "virtual screen resize forces full redraw" {
    const allocator = std.testing.allocator;
    var current = VirtualScreen.init(allocator);
    defer current.deinit();
    _ = try current.resize(4, 1);

    var renderer = VirtualScreenRenderer.init(allocator);
    defer renderer.deinit();

    var out = std.ArrayListUnmanaged(u8).empty;
    defer out.deinit(allocator);
    var aw = std.Io.Writer.Allocating.fromArrayList(allocator, &out);
    defer aw.deinit();

    _ = try renderer.emit(&aw.writer, &current);
    _ = try current.resize(5, 1);

    aw.clearRetainingCapacity();
    _ = try renderer.emit(&aw.writer, &current);
    try std.testing.expect(std.mem.startsWith(u8, aw.written(), "\x1b[2J\x1b[H"));
}
