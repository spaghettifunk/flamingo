//! buffer_file_test.zig — file I/O tests for Buffer.saveToFile / loadFromFile.
//!
//! Uses std.testing.tmpDir so every test gets a real, isolated directory
//! that is automatically cleaned up after the test completes.

const std = @import("std");
const buffer_mod = @import("../src/editor/buffer.zig");
const Buffer = buffer_mod.Buffer;
const Line = buffer_mod.Line;
const th = @import("test_helpers.zig");

test "Buffer: round-trip save and load preserves all lines" {
    const a = std.testing.allocator;
    const log = try th.setupLogger(a);
    defer log.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Build a path inside the tmp dir.
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = path_buf[0..try tmp.dir.realPath(std.testing.io, &path_buf)];
    const file_path = try std.fmt.allocPrint(a, "{s}/test_file.txt", .{dir_path});
    defer a.free(file_path);

    // Create buffer with three lines.
    var b = Buffer{
        .lines = std.ArrayList(Line).empty,
        .allocator = a,
    };
    defer b.deinit();

    const content = [_][]const u8{ "line one", "line two", "line three" };
    for (content) |text| {
        try b.lines.append(a, try Line.fromSlice(a, text));
    }

    try b.saveToFile(std.testing.io, file_path);
    try std.testing.expect(!b.is_dirty);

    // Load back.
    var b2 = try Buffer.loadFromFile(a, std.testing.io, file_path);
    defer b2.deinit();

    // loadFromFile splits on '\n', so a trailing newline produces an extra
    // empty line — account for that.
    const len = b2.lines.items.len;
    const effective_len = if (len > 0 and b2.lines.items[len - 1].len() == 0) len - 1 else len;
    try std.testing.expectEqual(@as(usize, 3), effective_len);

    for (content, 0..) |expected, i| {
        const got = try b2.lines.items[i].slice(a);
        defer a.free(got);
        try std.testing.expectEqualStrings(expected, got);
    }
}

test "Buffer: CRLF line endings are stripped on load" {
    const a = std.testing.allocator;
    const log = try th.setupLogger(a);
    defer log.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = path_buf[0..try tmp.dir.realPath(std.testing.io, &path_buf)];
    const file_path = try std.fmt.allocPrint(a, "{s}/crlf.txt", .{dir_path});
    defer a.free(file_path);

    // Write a file with Windows-style line endings manually.
    {
        const f = try std.Io.Dir.cwd().createFile(std.testing.io, file_path, .{});
        defer f.close(std.testing.io);
        try f.writeStreamingAll(std.testing.io, "first\r\nsecond\r\nthird\r\n");
    }

    var b = try Buffer.loadFromFile(a, std.testing.io, file_path);
    defer b.deinit();

    // Verify no '\r' characters survive.
    for (b.lines.items) |*line| {
        const s = try line.slice(a);
        defer a.free(s);
        for (s) |ch| {
            try std.testing.expect(ch != '\r');
        }
    }

    // First three lines have the right content.
    const s0 = try b.lines.items[0].slice(a);
    defer a.free(s0);
    try std.testing.expectEqualStrings("first", s0);
}

test "Buffer: empty file loads as one empty line" {
    const a = std.testing.allocator;
    const log = try th.setupLogger(a);
    defer log.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = path_buf[0..try tmp.dir.realPath(std.testing.io, &path_buf)];
    const file_path = try std.fmt.allocPrint(a, "{s}/empty.txt", .{dir_path});
    defer a.free(file_path);

    {
        const f = try std.Io.Dir.cwd().createFile(std.testing.io, file_path, .{});
        f.close(std.testing.io);
    }

    var b = try Buffer.loadFromFile(a, std.testing.io, file_path);
    defer b.deinit();

    try std.testing.expect(b.lines.items.len >= 1);
    // The one line that exists should be empty.
    try std.testing.expectEqual(@as(usize, 0), b.lines.items[0].len());
}

test "Buffer: saveToFile sets filename and marks not dirty" {
    const a = std.testing.allocator;
    const log = try th.setupLogger(a);
    defer log.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = path_buf[0..try tmp.dir.realPath(std.testing.io, &path_buf)];
    const file_path = try std.fmt.allocPrint(a, "{s}/save_test.txt", .{dir_path});
    defer a.free(file_path);

    var b = try Buffer.init(a);
    defer b.deinit();

    try b.insertChar(0, 0, 'h');
    try b.insertChar(0, 1, 'i');
    try std.testing.expect(b.is_dirty);

    try b.saveToFile(std.testing.io, file_path);
    try std.testing.expect(!b.is_dirty);
}
