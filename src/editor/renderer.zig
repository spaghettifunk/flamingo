const std = @import("std");
const render_mod = @import("render.zig");
const buffer = @import("buffer.zig");

pub const EditorRenderer = struct {
    legacy_frame: std.ArrayListUnmanaged(u8) = .empty,
    screen: render_mod.VirtualScreen,
    screen_renderer: render_mod.VirtualScreenRenderer,

    pub fn init(allocator: std.mem.Allocator) EditorRenderer {
        return .{
            .screen = render_mod.VirtualScreen.init(allocator),
            .screen_renderer = render_mod.VirtualScreenRenderer.init(allocator),
        };
    }

    pub fn deinit(self: *EditorRenderer, allocator: std.mem.Allocator) void {
        self.legacy_frame.deinit(allocator);
        self.legacy_frame = .empty;
        self.screen.deinit();
        self.screen_renderer.deinit();
    }
};

/// Calculates total gutter width: 1 space + num_digits + 1 space separator.
pub fn calculateGutterWidth(total_lines: usize) usize {
    return @max(buffer.countDigits(total_lines), 2) + 2;
}

test "calculateGutterWidth" {
    try std.testing.expectEqual(@as(usize, 4), calculateGutterWidth(5));
    try std.testing.expectEqual(@as(usize, 4), calculateGutterWidth(99));
    try std.testing.expectEqual(@as(usize, 5), calculateGutterWidth(100));
    try std.testing.expectEqual(@as(usize, 5), calculateGutterWidth(999));
}
