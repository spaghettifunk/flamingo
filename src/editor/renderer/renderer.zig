const std = @import("std");
const render_mod = @import("virtual_screen.zig");
const buffer = @import("../model/buffer.zig");

pub const EditorRenderer = struct {
    screen: render_mod.VirtualScreen,
    screen_renderer: render_mod.VirtualScreenRenderer,

    pub fn init(allocator: std.mem.Allocator) EditorRenderer {
        return .{
            .screen = render_mod.VirtualScreen.init(allocator),
            .screen_renderer = render_mod.VirtualScreenRenderer.init(allocator),
        };
    }

    pub fn deinit(self: *EditorRenderer, _: std.mem.Allocator) void {
        self.screen.deinit();
        self.screen_renderer.deinit();
    }
};

/// Calculates total gutter width: 1 space + num_digits + 1 space + 1 git diff marker + 1 space separator.
pub fn calculateGutterWidth(total_lines: usize) usize {
    return @max(buffer.countDigits(total_lines), 2) + 4;
}

test "calculateGutterWidth" {
    try std.testing.expectEqual(@as(usize, 6), calculateGutterWidth(5));
    try std.testing.expectEqual(@as(usize, 6), calculateGutterWidth(99));
    try std.testing.expectEqual(@as(usize, 7), calculateGutterWidth(100));
    try std.testing.expectEqual(@as(usize, 7), calculateGutterWidth(999));
}
