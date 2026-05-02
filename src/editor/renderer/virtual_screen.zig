const std = @import("std");
const terminal = @import("../../terminal.zig");

pub const RenderInvalidation = enum {
    none,
    partial,
    full,
};

pub const RenderStyle = enum {
    normal,
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
    search_status,
    error_style,
    completion,
    completion_selected,

    pub fn ansi(self: RenderStyle) []const u8 {
        return switch (self) {
            .normal => "\x1b[0m",
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
            .search_status => "\x1b[48;5;228m\x1b[30m",
            .error_style => "\x1b[31;1m",
            .completion => "\x1b[48;5;236m\x1b[38;5;250m",
            .completion_selected => "\x1b[48;5;25m\x1b[38;5;255m",
        };
    }
};

pub const RenderCell = struct {
    ch: u8 = ' ',
    style: RenderStyle = .normal,

    pub fn eql(self: RenderCell, other: RenderCell) bool {
        return self.ch == other.ch and self.style == other.style;
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
        self.cells.items[self.index(row, col)] = .{ .ch = ch, .style = style };
    }

    pub fn writeText(self: *VirtualScreen, row: usize, col: usize, text: []const u8, style: RenderStyle) void {
        if (row >= self.height or col >= self.width) return;
        var x = col;
        for (text) |ch| {
            if (x >= self.width) break;
            self.set(row, x, ch, style);
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
                    try writer.writeByte(run_cell.ch);
                    bytes += 1;
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
