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

    try logger.init(io, allocator, false);
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
    const syntax_buffer_id = ed.next_syntax_buffer_id;
    ed.next_syntax_buffer_id +%= 1;
    try ed.tabs.append(allocator, .{
        .buf = buf,
        .cursors = cursors,
        .syntax_highlighter = syntax.Highlighter.init(allocator),
        .syntax_buffer_id = syntax_buffer_id,
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

    var cursor_timings: [frames]u64 = undefined;
    var cursor_total_bytes: usize = 0;
    {
        const tab = ed.currentTab().?;
        tab.scroll_row = 0;
        tab.mainCursor().row = 1;
        tab.mainCursor().col = 0;
        ed.mode = .Normal;
        ed.explorer_visible = false;
        ed.explorer_focused = false;
        ed.completion_active = false;
        ed.search_buffer.clearRetainingCapacity();

        for (0..frames) |i| {
            const key = if (i % 2 == 0) ed.keys.move_down else ed.keys.move_up;
            out.clearRetainingCapacity();
            const start = perf.nowNs();
            if (!try ed.renderBenchmarkCursorMove(&out.writer, key)) {
                return error.FastCursorMoveBenchmarkIneligible;
            }
            cursor_timings[i] = perf.elapsedNs(start);
            cursor_total_bytes += out.written().len;
        }
    }

    var sorted = timings;
    std.mem.sort(u64, &sorted, {}, lessThanU64);
    const p50 = sorted[frames / 2];
    const p95 = sorted[(frames * 95) / 100];
    const avg_bytes = total_bytes / frames;

    var cursor_sorted = cursor_timings;
    std.mem.sort(u64, &cursor_sorted, {}, lessThanU64);
    const cursor_p50 = cursor_sorted[frames / 2];
    const cursor_p95 = cursor_sorted[(frames * 95) / 100];
    const cursor_avg_bytes = cursor_total_bytes / frames;

    if (cursor_avg_bytes >= 300) return error.FastCursorMoveBytesTargetMissed;

    std.debug.print("flamingo perf benchmark: lines={d} frames={d} p50_ns={d} p95_ns={d} avg_bytes={d} cursor_p50_ns={d} cursor_p95_ns={d} cursor_avg_bytes={d}\n", .{
        line_count,
        frames,
        p50,
        p95,
        avg_bytes,
        cursor_p50,
        cursor_p95,
        cursor_avg_bytes,
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
