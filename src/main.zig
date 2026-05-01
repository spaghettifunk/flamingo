const std = @import("std");
const config = @import("config.zig");
const logger = @import("logger.zig");
const editor = @import("editor/editor.zig");
const terminal = @import("terminal.zig");

const c = @cImport({
    @cInclude("signal.h");
});

var global_io: ?std.Io = null;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    global_io = io;
    const allocator = std.heap.smp_allocator;

    var result = try config.loadFile(io, allocator, "config.toml");
    defer result.deinit();

    const cfg = result.value;
    try config.validate(&cfg);

    // initiate logger
    try logger.init(io, allocator, cfg.debug);
    defer logger.shutdown() catch {};

    _ = c.signal(c.SIGSEGV, handleSignal);
    _ = c.signal(c.SIGABRT, handleSignal);
    _ = c.signal(c.SIGINT, handleSignal);
    _ = c.signal(c.SIGTERM, handleSignal);

    const stdout: std.Io.File = .stdout();
    defer terminal.restoreTerminal(io, stdout);

    try editor.start_editor(io, allocator, cfg);
}

pub fn handleSignal(sig: c_int) callconv(.c) void {
    const stdout: std.Io.File = .stdout();
    if (global_io) |io| {
        // Best-effort restore only
        terminal.restoreTerminal(io, stdout);
    }

    // Avoid std.debug.print here (not signal-safe)
    _ = sig;

    std.process.exit(1);
}

test {
    std.testing.refAllDecls(@This());
}
