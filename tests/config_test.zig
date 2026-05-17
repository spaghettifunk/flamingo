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
    try std.testing.expectEqualStrings("ctrl+n", cfg.keybindings.new_file);
    try std.testing.expectEqualStrings("ctrl+o", cfg.keybindings.open_file);
    try std.testing.expectEqualStrings("ctrl+f", cfg.keybindings.open_folder);
    try std.testing.expectEqualStrings("ctrl+p", cfg.keybindings.settings);
    try std.testing.expectEqualStrings("ctrl+q", cfg.keybindings.quit);
    try std.testing.expectEqualStrings("ctrl+b", cfg.keybindings.toggle_explorer);
    try std.testing.expectEqualStrings("ctrl+t", cfg.keybindings.toggle_terminal);
    try std.testing.expectEqualStrings("ctrl+e", cfg.keybindings.switch_focus);
    try std.testing.expectEqualStrings("ctrl+w", cfg.keybindings.close_tab);
    try std.testing.expectEqualStrings("alt+o", cfg.keybindings.jump_back);
    try std.testing.expectEqualStrings("alt+p", cfg.keybindings.jump_forward);
    try std.testing.expectEqualStrings("ctrl+s", cfg.keybindings.save);
    try std.testing.expectEqualStrings("alt+left", cfg.keybindings.word_left);
    try std.testing.expectEqualStrings("ctrl+space", cfg.keybindings.completion_trigger);
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
    try std.testing.expectEqualStrings("ctrl+n", cfg.keybindings.new_file);
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

test "Config: parse keybinding override" {
    const allocator = std.testing.allocator;
    var parser = toml.Parser(config.Config).init(allocator);
    defer parser.deinit();

    const src =
        \\[keybindings]
        \\new_file = "alt+n"
        \\switch_focus = "ctrl+tab"
    ;

    var result = try parser.parseString(src);
    defer result.deinit();

    const cfg = result.value;
    try std.testing.expectEqualStrings("alt+n", cfg.keybindings.new_file);
    try std.testing.expectEqualStrings("ctrl+tab", cfg.keybindings.switch_focus);
    // Unchanged keys keep defaults
    try std.testing.expectEqualStrings("ctrl+o", cfg.keybindings.open_file);
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

test "Config: validate rejects unknown keybinding" {
    var cfg = config.Config{};
    cfg.keybindings.toggle_explorer = "hyperdrive";
    try std.testing.expectError(error.InvalidKeybinding, config.validate(&cfg));
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

test "Config: legacy keybindings translate into resolved registry" {
    var cfg = config.Config{};
    cfg.keybindings.toggle_explorer = "ctrl+g";
    cfg.keybindings.save = "ctrl+w";

    var diagnostics = keybindings.BuildDiagnostics{};
    defer diagnostics.deinit(std.testing.allocator);
    var registry = try config.buildKeybindingRegistry(std.testing.allocator, &cfg, &diagnostics);
    defer registry.deinit(std.testing.allocator);

    try std.testing.expectEqual(commands.CommandId.explorer_toggle, switch (registry.resolve(.global, keybindings.ctrlChar('g'))) {
        .command => |command| command,
        else => return error.ExpectedCommand,
    });
    try std.testing.expectEqual(commands.CommandId.file_write, switch (registry.resolve(.normal, keybindings.ctrlChar('w'))) {
        .command => |command| command,
        else => return error.ExpectedCommand,
    });
    try std.testing.expectEqual(commands.CommandId.file_write, switch (registry.resolve(.insert, keybindings.ctrlChar('w'))) {
        .command => |command| command,
        else => return error.ExpectedCommand,
    });
}
