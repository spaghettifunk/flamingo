//! config_test.zig — unit tests for config.zig
//!
//! Uses toml.Parser.parseString so no actual files are read.

const std = @import("std");
const config = @import("../src/config.zig");
const keybindings = @import("../src/editor/keybindings.zig");
const commands = @import("../src/editor/commands.zig");
const toml = @import("toml");

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
