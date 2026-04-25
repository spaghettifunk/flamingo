const std = @import("std");
const context = @import("context.zig");

pub fn start_editor(ctx: *context.FlamingoContext) !void {
    std.debug.print("start-time: {d}\n", .{ctx.start_time});
}
