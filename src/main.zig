const std = @import("std");
const chilli = @import("chilli");
const logger = @import("logger/logger.zig");
const router = @import("./router/router.zig");
const querier = @import("./querier/querier.zig");
const ingester = @import("./ingester/ingester.zig");
const compactor = @import("./compactor/compactor.zig");
const alertmanager = @import("./alertmanager/alertmanager.zig");

const FlamingoContext = struct {
    log_level: u3,
    start_time: i64,
};

fn rootExec(ctx: chilli.CommandContext) !void {
    const is_verbose = try ctx.getFlag("verbose", bool);
    if (ctx.getContextData(FlamingoContext)) |app_ctx| {
        app_ctx.log_level = if (is_verbose) 1 else 0;
    }

    try ctx.command.printHelp();
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var context = FlamingoContext{
        .log_level = 0,
        .start_time = std.time.timestamp(),
    };

    var root_cmd = try chilli.Command.init(allocator, .{
        .name = "flamingo",
        .description = "Flamingo database",
        .version = "v0.0.1",
        .exec = rootExec, // The function to run
    });
    defer root_cmd.deinit();

    // initiate logger
    try logger.init(allocator, context.log_level);
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

    const ingester_cmd = try chilli.Command.init(allocator, .{
        .name = "ingester",
        .description = "Ingester service",
        .shortcut = 'i',
        .exec = ingester.ingester,
    });
    try root_cmd.addSubcommand(ingester_cmd);

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

    try root_cmd.run(&context);
}
