const std = @import("std");
const lsp_manager = @import("../src/lsp/manager.zig");
const event_queue = @import("../src/editor/runtime/event_queue.zig");
const editor_mod = @import("../src/editor/editor.zig");
const buffer_mod = @import("../src/editor/model/buffer.zig");
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

test "LSP helper converts file URIs to local paths" {
    const a = std.testing.allocator;

    const basic = try lsp_manager.fileUriToPathAlloc(a, "file:///tmp/main.zig");
    defer a.free(basic);
    try std.testing.expectEqualStrings("/tmp/main.zig", basic);

    const escaped = try lsp_manager.fileUriToPathAlloc(a, "file:///tmp/a%20b%2Ezig");
    defer a.free(escaped);
    try std.testing.expectEqualStrings("/tmp/a b.zig", escaped);

    const localhost = try lsp_manager.fileUriToPathAlloc(a, "file://localhost/tmp/main.zig");
    defer a.free(localhost);
    try std.testing.expectEqualStrings("/tmp/main.zig", localhost);

    try std.testing.expectError(error.UnsupportedUri, lsp_manager.fileUriToPathAlloc(a, "https://example.test/main.zig"));
}

test "LSP helper extracts first definition location from supported response shapes" {
    const a = std.testing.allocator;

    try std.testing.expect(lsp_manager.firstDefinitionLocation(.null) == null);

    var single = try std.json.parseFromSlice(
        std.json.Value,
        a,
        \\{"uri":"file:///tmp/main.zig","range":{"start":{"line":4,"character":2},"end":{"line":4,"character":8}}}
    ,
        .{},
    );
    defer single.deinit();
    const single_location = lsp_manager.firstDefinitionLocation(single.value) orelse return error.ExpectedLocation;
    try std.testing.expectEqualStrings("file:///tmp/main.zig", single_location.uri);
    try std.testing.expectEqual(@as(usize, 4), single_location.row);
    try std.testing.expectEqual(@as(usize, 2), single_location.col);

    var array = try std.json.parseFromSlice(
        std.json.Value,
        a,
        \\[null,{"uri":"file:///tmp/other.zig","range":{"start":{"line":9,"character":1},"end":{"line":9,"character":5}}}]
    ,
        .{},
    );
    defer array.deinit();
    const array_location = lsp_manager.firstDefinitionLocation(array.value) orelse return error.ExpectedLocation;
    try std.testing.expectEqualStrings("file:///tmp/other.zig", array_location.uri);
    try std.testing.expectEqual(@as(usize, 9), array_location.row);
    try std.testing.expectEqual(@as(usize, 1), array_location.col);

    var link = try std.json.parseFromSlice(
        std.json.Value,
        a,
        \\[{"targetUri":"file:///tmp/link.zig","targetSelectionRange":{"start":{"line":3,"character":7},"end":{"line":3,"character":11}}}]
    ,
        .{},
    );
    defer link.deinit();
    const link_location = lsp_manager.firstDefinitionLocation(link.value) orelse return error.ExpectedLocation;
    try std.testing.expectEqualStrings("file:///tmp/link.zig", link_location.uri);
    try std.testing.expectEqual(@as(usize, 3), link_location.row);
    try std.testing.expectEqual(@as(usize, 7), link_location.col);
}

test "Editor: opening file with missing LSP command does not quit" {
    const a = std.testing.allocator;
    const logger = try th.setupLogger(a);
    defer logger.deinit();

    var ed = try editor_mod.Editor.init(a, std.testing.io, .{});
    defer ed.deinit();

    if (ed.runtime.lsp_mgr) |*mgr| {
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
    ed.state.mode = .Normal;

    try std.testing.expect(!ed.should_quit);
    try std.testing.expectEqual(@as(usize, 1), ed.state.tabs.items.len);
    if (ed.runtime.lsp_mgr) |*mgr| {
        try std.testing.expect(!mgr.clients.contains("missing-test-lsp"));
    }
}
