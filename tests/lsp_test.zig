const std = @import("std");
const lsp_manager = @import("../src/lsp/manager.zig");
const event_queue = @import("../src/editor/event_queue.zig");
const editor_mod = @import("../src/editor/editor.zig");
const buffer_mod = @import("../src/editor/buffer.zig");
const th = @import("test_helpers.zig");

test "LspManager: pathToUri constructs correct absolute URIs" {
    const a = std.testing.allocator;
    const queue = try a.create(event_queue.EventQueue);
    queue.* = event_queue.EventQueue.init(a, std.testing.io);
    defer {
        queue.deinit();
        a.destroy(queue);
    }

    var mgr = try lsp_manager.LspManager.init(a, std.testing.io, queue);
    defer mgr.deinit();

    // Test with relative path
    const rel_path = "src/main.zig";
    const uri = try mgr.pathToUri(a, rel_path);
    defer a.free(uri);

    try std.testing.expect(std.mem.startsWith(u8, uri, "file:///"));
    try std.testing.expect(std.mem.endsWith(u8, uri, "/src/main.zig"));

    // Test with absolute path
    const abs_path = "/tmp/test.zig";
    const uri2 = try mgr.pathToUri(a, abs_path);
    defer a.free(uri2);

    try std.testing.expectEqualStrings("file:///tmp/test.zig", uri2);
}

test "Editor: opening file with missing LSP command does not quit" {
    const a = std.testing.allocator;
    const logger = try th.setupLogger(a);
    defer logger.deinit();

    var ed = try editor_mod.Editor.init(a, std.testing.io, .{});
    defer ed.deinit();

    if (ed.lsp_mgr) |*mgr| {
        try mgr.plugin_mgr.plugins.append(a, .{
            .name = "missing-test-lsp",
            .extensions = &[_][]const u8{".missing-lsp-test"},
            .lsp_command = &[_][]const u8{"__flamingo_missing_lsp_command__"},
        });
    }

    var buf = try buffer_mod.Buffer.init(a);
    errdefer buf.deinit();
    try buf.setFilename("example.missing-lsp-test");

    try ed.addTab(buf);
    ed.mode = .Normal;

    try std.testing.expect(!ed.should_quit);
    try std.testing.expectEqual(@as(usize, 1), ed.tabs.items.len);
    if (ed.lsp_mgr) |*mgr| {
        try std.testing.expect(!mgr.clients.contains("missing-test-lsp"));
    }
}
