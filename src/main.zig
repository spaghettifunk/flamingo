const std = @import("std");
const context = @import("context.zig");
const config = @import("config.zig");
const logger = @import("logger.zig");
const editor = @import("editor.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var result = try config.loadFile(allocator, "flamingo.toml");
    defer result.deinit();

    const cfg = result.value;
    try config.validate(&cfg);

    // setup context
    var ctx = context.FlamingoContext{
        .log_level = 0,
        .start_time = std.time.timestamp(),
        .config = cfg,
    };

    // initiate logger
    try logger.init(allocator, ctx.log_level);
    defer logger.shutdown() catch {};

    try editor.start_editor(&ctx);
}
