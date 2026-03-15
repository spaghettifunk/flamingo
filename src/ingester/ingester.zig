const std = @import("std");
const chilli = @import("chilli");

pub fn ingester(_: chilli.CommandContext) !void {
    std.debug.print("Hello from Ingester\n", .{});
}
