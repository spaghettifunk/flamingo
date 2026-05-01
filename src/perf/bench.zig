const std = @import("std");
const config = @import("../config.zig");
const editor = @import("../editor/editor.zig");
const buffer = @import("../editor/buffer.zig");
const syntax = @import("../editor/syntax.zig");
const perf = @import("perf.zig");
const logger = @import("../logger.zig");

const line_count = 10_000;
const frames = 240;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = std.heap.smp_allocator;

    try logger.init(io, allocator, 0);
    defer logger.shutdown() catch {};

    var ed = try editor.Editor.init(allocator, io, .{});
    defer ed.deinit();
    ed.width = 120;
    ed.height = 40;
    ed.mode = .Normal;

    var buf = try makeLargeBuffer(allocator);
    errdefer buf.deinit();

    var cursors = std.ArrayListUnmanaged(editor.Cursor).empty;
    try cursors.append(allocator, .{});
    try ed.tabs.append(allocator, .{
        .buf = buf,
        .cursors = cursors,
        .syntax_highlighter = syntax.Highlighter.init(allocator),
        .lsp_notified_revision = buf.revision,
    });
    ed.active_tab_index = 0;
    buf = undefined;

    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();

    var timings: [frames]u64 = undefined;
    var total_bytes: usize = 0;

    for (0..frames) |i| {
        const tab = ed.currentTab().?;
        const max_scroll = tab.buf.lines.items.len - 1;
        tab.scroll_row = @min(max_scroll, i * 7);
        tab.mainCursor().row = tab.scroll_row;
        tab.mainCursor().col = 0;
        ed.markDirty(if (i == 0) .full else .partial);

        out.clearRetainingCapacity();
        const start = perf.nowNs();
        try ed.renderBenchmarkFrame(&out.writer);
        timings[i] = perf.elapsedNs(start);
        total_bytes += out.written().len;
    }

    var sorted = timings;
    std.mem.sort(u64, &sorted, {}, lessThanU64);
    const p50 = sorted[frames / 2];
    const p95 = sorted[(frames * 95) / 100];
    const avg_bytes = total_bytes / frames;

    std.debug.print("flamingo perf benchmark: lines={d} frames={d} p50_ns={d} p95_ns={d} avg_bytes={d}\n", .{
        line_count,
        frames,
        p50,
        p95,
        avg_bytes,
    });
}

fn makeLargeBuffer(allocator: std.mem.Allocator) !buffer.Buffer {
    var buf = buffer.Buffer{
        .lines = std.ArrayList(buffer.Line).empty,
        .allocator = allocator,
        .filename = try allocator.dupe(u8, "perf_bench.zig"),
        .is_dirty = false,
        .revision = 0,
        .saved_revision = 0,
    };
    errdefer buf.deinit();

    for (0..line_count) |i| {
        var line_buf: [160]u8 = undefined;
        const line = try std.fmt.bufPrint(&line_buf, "const value_{d}: u32 = {d}; // benchmark line for flamingo rendering", .{ i, i });
        try buf.lines.append(allocator, try buffer.Line.fromSlice(allocator, line));
    }

    return buf;
}

fn lessThanU64(_: void, lhs: u64, rhs: u64) bool {
    return lhs < rhs;
}
