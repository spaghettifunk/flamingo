const std = @import("std");
const chilli = @import("chilli");

pub fn compactor(_: chilli.CommandContext) !void {
    std.debug.print("Hello from Compactor\n", .{});
}
