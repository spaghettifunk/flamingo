const std = @import("std");
const lsp_manager = @import("../src/lsp/manager.zig");
const event_queue = @import("../src/editor/event_queue.zig");

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
