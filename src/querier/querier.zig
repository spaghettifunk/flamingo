const std = @import("std");
const chilli = @import("chilli");

pub fn querier(_: chilli.CommandContext) !void {
    std.debug.print("Hello from Querier\n", .{});
}
