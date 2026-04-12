const std = @import("std");
const chilli = @import("chilli");
const c = @cImport({
    @cInclude("duckdb.h");
});

pub fn compactor(_: chilli.CommandContext) !void {
    std.debug.print("Hello from Compactor\n", .{});
}
