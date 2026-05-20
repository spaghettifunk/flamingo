//! config_test.zig — unit tests for config.zig
//!
//! Uses toml.Parser.parseString so no actual files are read.

const std = @import("std");
const config = @import("../src/config.zig");
const keybindings = @import("../src/editor/keybindings.zig");
const commands = @import("../src/editor/commands.zig");
const toml = @import("toml");

fn testingTmpRoot(allocator: std.mem.Allocator, tmp: anytype) ![]u8 {
    return std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
}

test "Config: zero-value has correct defaults" {
    const cfg = config.Config{};
    try std.testing.expect(!cfg.debug);
    try std.testing.expect(cfg.keybindings.global == null);
    try std.testing.expect(cfg.keybindings.normal == null);
    try std.testing.expectEqual(@as(usize, 0), cfg.keybindings.unknown_contexts.len);
    try std.testing.expectEqual(@as(u8, 20), cfg.explorer.width_percentage);
}

test "Config: parse empty TOML gives defaults" {
    const allocator = std.testing.allocator;
    var parser = toml.Parser(config.Config).init(allocator);
    defer parser.deinit();

    var result = try parser.parseString("");
    defer result.deinit();

    const cfg = result.value;
    try std.testing.expect(!cfg.debug);
    try std.testing.expect(cfg.keybindings.normal == null);
    try std.testing.expectEqual(@as(u8, 20), cfg.explorer.width_percentage);
}

test "Config: parse debug flag" {
    const allocator = std.testing.allocator;
    var parser = toml.Parser(config.Config).init(allocator);
    defer parser.deinit();

    var result = try parser.parseString("debug = true");
    defer result.deinit();

    try std.testing.expect(result.value.debug);
}

test "Config: parse context keybinding override" {
    const allocator = std.testing.allocator;
    var parser = toml.Parser(config.Config).init(allocator);
    defer parser.deinit();

    const src =
        \\[keybindings.global]
        \\"ctrl+g" = "explorer.toggle"
    ;

    var result = try parser.parseString(src);
    defer result.deinit();

    try std.testing.expect(result.value.keybindings.global != null);
}

test "Config: parse explorer width_percentage" {
    const allocator = std.testing.allocator;
    var parser = toml.Parser(config.Config).init(allocator);
    defer parser.deinit();

    const src =
        \\[explorer]
        \\width_percentage = 30
    ;

    var result = try parser.parseString(src);
    defer result.deinit();

    try std.testing.expectEqual(@as(u8, 30), result.value.explorer.width_percentage);
}

test "Config: parse author table" {
    const allocator = std.testing.allocator;
    var parser = toml.Parser(config.Config).init(allocator);
    defer parser.deinit();

    const src =
        \\[author]
        \\name = "Davide"
        \\email = "davide@example.com"
    ;

    var result = try parser.parseString(src);
    defer result.deinit();

    try std.testing.expectEqualStrings("Davide", result.value.author.name.?);
    try std.testing.expectEqualStrings("davide@example.com", result.value.author.email.?);
}

test "Config: validate passes on default config" {
    const cfg = config.Config{};
    // Should not return an error
    try config.validate(&cfg);
}

test "Config: parse context keybinding tables and unbinds" {
    const allocator = std.testing.allocator;
    var parser = toml.Parser(config.Config).init(allocator);
    defer parser.deinit();

    const src =
        \\[keybindings.normal]
        \\"x" = "mode.insert"
        \\"ctrl+s" = "file.write"
        \\
        \\[keybindings.normal.unbind]
        \\keys = ["i"]
        \\
        \\[keybindings.command_line]
        \\"ctrl+j" = "command.execute"
    ;

    var result = try parser.parseString(src);
    defer result.deinit();

    var diagnostics = keybindings.BuildDiagnostics{};
    defer diagnostics.deinit(allocator);
    var registry = try config.buildKeybindingRegistry(allocator, &result.value, &diagnostics);
    defer registry.deinit(allocator);

    try std.testing.expectEqual(commands.CommandId.mode_insert, switch (registry.resolve(.normal, keybindings.keyChar('x'))) {
        .command => |command| command,
        else => return error.ExpectedCommand,
    });
    try std.testing.expect(registry.resolve(.normal, keybindings.keyChar('i')) == .none);
    try std.testing.expectEqual(commands.CommandId.command_execute, switch (registry.resolve(.command_line, keybindings.ctrlChar('j'))) {
        .command => |command| command,
        else => return error.ExpectedCommand,
    });
}

test "Config: new keybinding tables validate unknown command context and key errors" {
    const allocator = std.testing.allocator;

    {
        var parser = toml.Parser(config.Config).init(allocator);
        defer parser.deinit();
        var result = try parser.parseString(
            \\[keybindings.mystery]
            \\"x" = "mode.insert"
        );
        defer result.deinit();

        var diagnostics = keybindings.BuildDiagnostics{};
        defer diagnostics.deinit(allocator);
        try std.testing.expectError(error.InvalidKeybindingConfig, config.buildKeybindingRegistry(allocator, &result.value, &diagnostics));
        try std.testing.expect(diagnostics.hasErrors());
    }

    {
        var parser = toml.Parser(config.Config).init(allocator);
        defer parser.deinit();
        var result = try parser.parseString(
            \\[keybindings.normal]
            \\"x" = "not.a_command"
            \\"hyperdrive" = "mode.insert"
            \\"y" = "search.accept"
        );
        defer result.deinit();

        var diagnostics = keybindings.BuildDiagnostics{};
        defer diagnostics.deinit(allocator);
        try std.testing.expectError(error.InvalidKeybindingConfig, config.buildKeybindingRegistry(allocator, &result.value, &diagnostics));
        try std.testing.expect(diagnostics.hasErrors());
    }
}

test "Config: inline command args are rejected clearly" {
    const allocator = std.testing.allocator;
    var parser = toml.Parser(config.Config).init(allocator);
    defer parser.deinit();
    var result = try parser.parseString(
        \\[keybindings.normal]
        \\"tab" = { command = "editing.indent", args = { spaces = 4 } }
    );
    defer result.deinit();

    var diagnostics = keybindings.BuildDiagnostics{};
    defer diagnostics.deinit(allocator);
    try std.testing.expectError(error.InvalidKeybindingConfig, config.buildKeybindingRegistry(allocator, &result.value, &diagnostics));
    try std.testing.expect(diagnostics.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, diagnostics.items.items[0].message, "inline command args") != null);
}

test "Config: legacy flat keybindings are rejected" {
    const allocator = std.testing.allocator;
    var parser = toml.Parser(config.Config).init(allocator);
    defer parser.deinit();

    var result = try parser.parseString(
        \\[keybindings]
        \\toggle_explorer = "ctrl+g"
    );
    defer result.deinit();

    var diagnostics = keybindings.BuildDiagnostics{};
    defer diagnostics.deinit(allocator);
    try std.testing.expectError(error.InvalidKeybindingConfig, config.buildKeybindingRegistry(allocator, &result.value, &diagnostics));
    try std.testing.expect(diagnostics.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, diagnostics.items.items[0].message, "legacy flat [keybindings] field") != null);
}

test "Config bootstrap: resolves default user config path from home" {
    const allocator = std.testing.allocator;
    var paths = try config.resolveUserConfigPathsFromHome(allocator, "/tmp/flamingo-home");
    defer paths.deinit(allocator);

    try std.testing.expectEqualStrings("/tmp/flamingo-home/.flamingo", paths.dir);
    try std.testing.expectEqualStrings("/tmp/flamingo-home/.flamingo/config.toml", paths.file);
}

test "Config bootstrap: creates directory and default config when missing" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const home = try testingTmpRoot(allocator, tmp);
    defer allocator.free(home);

    const config_path = try config.ensureUserConfigInHome(allocator, io, home);
    defer allocator.free(config_path);

    _ = try tmp.dir.statFile(io, ".flamingo", .{});
    _ = try tmp.dir.statFile(io, ".flamingo/config.toml", .{});

    const source = try std.Io.Dir.cwd().readFileAlloc(io, config_path, allocator, std.Io.Limit.limited(4 * 1024 * 1024));
    defer allocator.free(source);
    try std.testing.expectEqualStrings(config.default_config_toml, source);
}

test "Config bootstrap: does not overwrite existing config" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, ".flamingo");
    try tmp.dir.writeFile(io, .{ .sub_path = ".flamingo/config.toml", .data = "# custom marker\n" });

    const home = try testingTmpRoot(allocator, tmp);
    defer allocator.free(home);

    const config_path = try config.ensureUserConfigInHome(allocator, io, home);
    defer allocator.free(config_path);

    const source = try std.Io.Dir.cwd().readFileAlloc(io, config_path, allocator, std.Io.Limit.limited(4 * 1024 * 1024));
    defer allocator.free(source);
    try std.testing.expectEqualStrings("# custom marker\n", source);
}

test "Config bootstrap: generated default config parses successfully" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const home = try testingTmpRoot(allocator, tmp);
    defer allocator.free(home);

    const config_path = try config.ensureUserConfigInHome(allocator, io, home);
    defer allocator.free(config_path);

    var result = try config.loadFile(io, allocator, config_path);
    defer result.deinit();
    try config.validate(&result.value);
}

test "Config bootstrap: embedded default matches repository local config" {
    const allocator = std.testing.allocator;
    const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "config.toml", allocator, std.Io.Limit.limited(4 * 1024 * 1024));
    defer allocator.free(source);

    try std.testing.expectEqualStrings(source, config.default_config_toml);
}

test "Config bootstrap: missing home is rejected" {
    try std.testing.expectError(error.MissingHome, config.resolveUserConfigPathsFromHome(std.testing.allocator, ""));
    try std.testing.expectError(error.MissingHome, config.ensureUserConfigInHome(std.testing.allocator, std.testing.io, ""));
}

test "Config path priority: --config wins over environment and default" {
    const allocator = std.testing.allocator;
    var selected = try config.resolveSelectedConfigPathFromHome(
        allocator,
        &.{ "--config", "./explicit.toml" },
        "/tmp/env.toml",
        "/tmp/home",
    );
    defer selected.deinit(allocator);

    try std.testing.expectEqual(config.ConfigPathSource.cli, selected.source);
    try std.testing.expectEqualStrings("./explicit.toml", selected.path);
}

test "Config path priority: invalid CLI config args are rejected" {
    try std.testing.expectError(error.MissingConfigPath, config.configPathFromArgs(std.testing.allocator, &.{"--config"}));
    try std.testing.expectError(error.UnknownCliArgument, config.configPathFromArgs(std.testing.allocator, &.{"--bogus"}));
    try std.testing.expectError(error.UnknownCliArgument, config.configPathFromArgs(std.testing.allocator, &.{ "--config", "a.toml", "--bogus" }));
}

test "Config path priority: FLAMINGO_CONFIG wins over default" {
    const allocator = std.testing.allocator;
    var selected = try config.resolveSelectedConfigPathFromHome(
        allocator,
        &.{},
        "/tmp/env.toml",
        "/tmp/home",
    );
    defer selected.deinit(allocator);

    try std.testing.expectEqual(config.ConfigPathSource.env, selected.source);
    try std.testing.expectEqualStrings("/tmp/env.toml", selected.path);
}

test "Config path priority: explicit config does not create default user config" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const home = try testingTmpRoot(allocator, tmp);
    defer allocator.free(home);

    var selected = try config.resolveSelectedConfigPathFromHome(
        allocator,
        &.{ "--config", "./config.toml" },
        null,
        home,
    );
    defer selected.deinit(allocator);

    try std.testing.expectEqual(config.ConfigPathSource.cli, selected.source);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, ".flamingo", .{}));
}
