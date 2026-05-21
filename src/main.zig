const std = @import("std");
const config = @import("config.zig");
const logger = @import("logger.zig");
const editor = @import("editor/editor.zig");
const keybindings = @import("editor/keybindings.zig");
const terminal = @import("terminal.zig");
const version = @import("version.zig");

const c = @cImport({
    @cInclude("signal.h");
});

var global_io: ?std.Io = null;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    global_io = io;
    const allocator = std.heap.smp_allocator;

    var argv = std.ArrayListUnmanaged([]const u8).empty;
    defer argv.deinit(allocator);
    var arg_iter = std.process.Args.Iterator.init(init.minimal.args);
    defer arg_iter.deinit();
    _ = arg_iter.skip();
    while (arg_iter.next()) |arg| {
        try argv.append(allocator, arg);
    }

    if (try handleCliCommand(io, argv.items)) return;

    const selected_config = try selectedConfigPath(allocator, io, argv.items, init.environ_map);
    defer selected_config.deinit(allocator);

    var result = config.loadFile(io, allocator, selected_config.path) catch |err| {
        std.debug.print("Failed to load config: {s}: {s}\n", .{ selected_config.path, @errorName(err) });
        return err;
    };
    defer result.deinit();

    const cfg = result.value;
    try config.validate(&cfg);
    var keybinding_diagnostics = keybindings.BuildDiagnostics{};
    defer keybinding_diagnostics.deinit(allocator);
    var resolved_keybindings = config.buildKeybindingRegistry(allocator, &cfg, &keybinding_diagnostics) catch |err| {
        keybinding_diagnostics.print();
        return err;
    };
    resolved_keybindings.deinit(allocator);
    keybinding_diagnostics.print();

    // initiate logger
    try logger.init(io, allocator, cfg.debug);
    defer logger.shutdown() catch {};

    _ = c.signal(c.SIGSEGV, handleSignal);
    _ = c.signal(c.SIGABRT, handleSignal);
    _ = c.signal(c.SIGINT, handleSignal);
    _ = c.signal(c.SIGTERM, handleSignal);

    const stdout: std.Io.File = .stdout();
    defer terminal.restoreTerminal(io, stdout);

    try editor.start_editor(io, allocator, cfg, selected_config.path, selected_config.source);
}

const CliCommand = enum {
    help,
    version,
};

fn cliCommand(args: []const []const u8) ?CliCommand {
    if (args.len != 1) return null;
    if (std.mem.eql(u8, args[0], "--version") or std.mem.eql(u8, args[0], "version")) return .version;
    if (std.mem.eql(u8, args[0], "--help") or std.mem.eql(u8, args[0], "-h") or std.mem.eql(u8, args[0], "help")) return .help;
    return null;
}

fn handleCliCommand(io: std.Io, args: []const []const u8) !bool {
    const command = cliCommand(args) orelse return false;

    const stdout = std.Io.File.stdout();
    var stdout_buf: [0]u8 = .{};
    var writer = stdout.writerStreaming(io, &stdout_buf);

    switch (command) {
        .version => try writer.interface.print("flamingo {s}\n", .{version.version}),
        .help => try writer.interface.writeAll(
            \\Usage: flamingo [--config <path>]
            \\
            \\Options:
            \\  --config <path>  Use a specific config file
            \\  --help, -h       Show this help text
            \\  --version        Show the Flamingo version
            \\
        ),
    }
    return true;
}

fn selectedConfigPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: []const []const u8,
    environ: *const std.process.Environ.Map,
) !config.SelectedConfigPath {
    if (config.configPathFromArgs(allocator, args)) |path_or_null| {
        if (path_or_null) |path| return .{ .path = path, .source = .cli };
    } else |err| switch (err) {
        error.MissingConfigPath => {
            std.debug.print("Missing value for --config\n", .{});
            return err;
        },
        error.UnknownCliArgument => {
            std.debug.print("Unknown CLI argument\n", .{});
            return err;
        },
        else => return err,
    }

    if (environ.get("FLAMINGO_CONFIG")) |env_path| {
        if (env_path.len != 0) return .{ .path = try allocator.dupe(u8, env_path), .source = .env };
    }

    const path = config.ensureUserConfig(allocator, io, environ) catch |err| {
        switch (err) {
            error.MissingHome => std.debug.print("Unable to determine home directory: HOME is not set\n", .{}),
            else => std.debug.print("Unable to create or load default user config: {s}\n", .{@errorName(err)}),
        }
        return err;
    };
    return .{ .path = path, .source = .default_user };
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

test "CLI command detection recognizes non-interactive checks" {
    try std.testing.expectEqual(CliCommand.version, cliCommand(&.{"--version"}).?);
    try std.testing.expectEqual(CliCommand.version, cliCommand(&.{"version"}).?);
    try std.testing.expectEqual(CliCommand.help, cliCommand(&.{"--help"}).?);
    try std.testing.expectEqual(CliCommand.help, cliCommand(&.{"-h"}).?);
    try std.testing.expectEqual(CliCommand.help, cliCommand(&.{"help"}).?);
    try std.testing.expect(cliCommand(&.{}) == null);
    try std.testing.expect(cliCommand(&.{ "--config", "config.toml" }) == null);
    try std.testing.expect(cliCommand(&.{"--bogus"}) == null);
}
