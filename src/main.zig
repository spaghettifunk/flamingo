const std = @import("std");
const context = @import("context.zig");
const config = @import("config.zig");
const logger = @import("logger.zig");
const editor = @import("editor.zig");
const terminal = @import("terminal.zig");

const c = @cImport({
    @cInclude("signal.h");
});

pub fn main() !void {
    var alloc_impl: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = alloc_impl.deinit();
    const allocator = alloc_impl.allocator();

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

    _ = c.signal(c.SIGSEGV, handleSignal);
    _ = c.signal(c.SIGABRT, handleSignal);
    _ = c.signal(c.SIGINT, handleSignal);
    _ = c.signal(c.SIGTERM, handleSignal);

    // initiate logger
    try logger.init(allocator, ctx.log_level);
    defer logger.shutdown() catch {};

    const stdout = std.fs.File.stdout();
    defer terminal.restoreTerminal(stdout);

    try editor.start_editor(&ctx);
}

pub fn panicHandler(msg: []const u8, trace: ?*std.builtin.StackTrace) noreturn {
    const stdout = std.fs.File.stdout();
    terminal.restoreTerminal(stdout);

    std.debug.print("panic: {s}\n", .{msg});

    if (trace) |t| {
        std.debug.dumpStackTrace(t.*);
    }

    std.process.exit(1);
}

pub fn handleSignal(sig: c_int) callconv(.c) void {
    const stdout = std.fs.File.stdout();

    // Best-effort restore only
    terminal.restoreTerminal(stdout);

    // Avoid std.debug.print here (not signal-safe)
    _ = sig;

    std.process.exit(1);
}
