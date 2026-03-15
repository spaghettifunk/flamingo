const std = @import("std");
const chilli = @import("chilli");

pub fn router(_: chilli.CommandContext) !void {
    std.debug.print("Hello from Router\n", .{});
}
