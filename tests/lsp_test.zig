const std = @import("std");
const lsp_manager = @import("../src/lsp/manager.zig");
const event_queue = @import("../src/editor/runtime/event_queue.zig");
const editor_mod = @import("../src/editor/editor.zig");
const buffer_mod = @import("../src/editor/model/buffer.zig");
const config = @import("../src/config.zig");
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
            .language_id = "missing-test-lsp",
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

test "LspManager: default protobuf plugin uses Buf LSP command" {
    const a = std.testing.allocator;
    const queue = try a.create(event_queue.EventQueue);
    queue.* = event_queue.EventQueue.init(a, std.testing.io);
    defer {
        queue.deinit();
        a.destroy(queue);
    }

    var mgr = try lsp_manager.LspManager.init(a, std.testing.io, queue);
    defer mgr.deinit();

    const p = mgr.plugin_mgr.getPluginForExtension(".proto") orelse return error.ExpectedPlugin;
    try std.testing.expectEqualStrings("protobuf", p.name);
    try std.testing.expectEqualStrings("proto", p.language_id);
    try std.testing.expectEqual(@as(usize, 3), p.lsp_command.len);
    try std.testing.expectEqualStrings("buf", p.lsp_command[0]);
    try std.testing.expectEqualStrings("lsp", p.lsp_command[1]);
    try std.testing.expectEqualStrings("serve", p.lsp_command[2]);
}

test "LspManager: protobuf workspace root prefers buf config over git root" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "repo/.git");
    try tmp.dir.createDirPath(io, "repo/proto/sub");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/proto/buf.yaml", .data = "version: v2\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/proto/sub/service.proto", .data = "syntax = \"proto3\";\n" });

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_root = path_buf[0..try tmp.dir.realPath(io, &path_buf)];
    const proto_path = try std.fmt.allocPrint(a, "{s}/repo/proto/sub/service.proto", .{tmp_root});
    defer a.free(proto_path);
    const expected_root = try std.fmt.allocPrint(a, "{s}/repo/proto", .{tmp_root});
    defer a.free(expected_root);

    const queue = try a.create(event_queue.EventQueue);
    queue.* = event_queue.EventQueue.init(a, io);
    defer {
        queue.deinit();
        a.destroy(queue);
    }
    var mgr = try lsp_manager.LspManager.init(a, io, queue);
    defer mgr.deinit();

    const root = try mgr.workspaceRootForFile(proto_path);
    defer a.free(root);
    try std.testing.expectEqualStrings(expected_root, root);
}

test "Editor: missing protobuf Buf command shows non-fatal status" {
    const a = std.testing.allocator;
    const logger = try th.setupLogger(a);
    defer logger.deinit();

    var ed = try editor_mod.Editor.init(a, std.testing.io, .{});
    defer ed.deinit();

    if (ed.runtime.lsp_mgr) |*mgr| {
        try mgr.plugin_mgr.overrideLsp("protobuf", "__flamingo_missing_buf_command__", &.{ "lsp", "serve" }, "proto");
    }

    var buf = try buffer_mod.Buffer.init(a);
    errdefer buf.deinit();
    try buf.setFilename("example.proto");

    try ed.addTab(buf);
    try std.testing.expect(!ed.should_quit);
    try std.testing.expectEqualStrings(
        "Protobuf LSP unavailable: install Buf or configure a protobuf language server.",
        ed.state.status_message.?,
    );
    if (ed.runtime.lsp_mgr) |*mgr| {
        try std.testing.expect(!mgr.clients.contains("protobuf"));
    }
}

test "Editor: protobuf LSP command can be overridden from config" {
    const a = std.testing.allocator;
    const logger = try th.setupLogger(a);
    defer logger.deinit();

    const cfg = config.Config{
        .languages = .{
            .protobuf = .{
                .lsp = .{
                    .command = "protols",
                    .args = &.{},
                    .language_id = "protobuf",
                },
            },
        },
    };
    var ed = try editor_mod.Editor.init(a, std.testing.io, cfg);
    defer ed.deinit();

    const p = ed.runtime.lsp_mgr.?.plugin_mgr.getPluginForExtension(".proto") orelse return error.ExpectedPlugin;
    try std.testing.expectEqual(@as(usize, 1), p.lsp_command.len);
    try std.testing.expectEqualStrings("protols", p.lsp_command[0]);
    try std.testing.expectEqualStrings("protobuf", p.language_id);
}
