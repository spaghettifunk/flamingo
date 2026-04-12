const std = @import("std");
const chilli = @import("chilli");

pub fn alertmanager(_: chilli.CommandContext) !void {
    std.debug.print("Hello from AlertManager\n", .{});
}
