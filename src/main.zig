const std = @import("std");
const chilli = @import("chilli");
const context = @import("context.zig");
const config = @import("config.zig");
const logger = @import("logger.zig");
const router = @import("./router/router.zig");
const querier = @import("./querier/querier.zig");
const compactor = @import("./compactor/compactor.zig");
const alertmanager = @import("./alertmanager/scheduler.zig");

fn rootExec(ctx: chilli.CommandContext) !void {
    const is_verbose = try ctx.getFlag("verbose", bool);
    if (ctx.getContextData(context.FlamingoContext)) |app_ctx| {
        app_ctx.log_level = if (is_verbose) 1 else 0;
    }
    try ctx.command.printHelp();
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var result = try config.loadFile(allocator, "flamingo.example.toml");
    defer result.deinit();

    const cfg = result.value;
    try config.validate(&cfg);

    // setup context
    var ctx = context.FlamingoContext{
        .log_level = 0,
        .start_time = std.time.timestamp(),
        .config = cfg,
    };

    var root_cmd = try chilli.Command.init(allocator, .{
        .name = "flamingo",
        .description = "Flamingo database",
        .version = "v0.0.1",
        .exec = rootExec,
    });
    defer root_cmd.deinit();

    // initiate logger
    try logger.init(allocator, ctx.log_level);
    defer logger.shutdown() catch {};

    try root_cmd.addFlag(.{
        .name = "verbose",
        .shortcut = 'v',
        .description = "Enable verbose output",
        .type = .Bool,
        .default_value = .{ .Bool = false },
    });

    const router_cmd = try chilli.Command.init(allocator, .{
        .name = "router",
        .description = "Router service",
        .shortcut = 'r',
        .exec = router.router,
    });
    try root_cmd.addSubcommand(router_cmd);

    const querier_cmd = try chilli.Command.init(allocator, .{
        .name = "querier",
        .description = "Querier service",
        .shortcut = 'q',
        .exec = querier.querier,
    });
    try root_cmd.addSubcommand(querier_cmd);

    const compactor_cmd = try chilli.Command.init(allocator, .{
        .name = "compactor",
        .description = "Compactor service",
        .shortcut = 'c',
        .exec = compactor.compactor,
    });
    try root_cmd.addSubcommand(compactor_cmd);

    const alertmanager_cmd = try chilli.Command.init(allocator, .{
        .name = "alertmanager",
        .description = "AlertManager service",
        .shortcut = 'a',
        .exec = alertmanager.alertmanager,
    });
    try root_cmd.addSubcommand(alertmanager_cmd);

    try root_cmd.run(&ctx);
}
