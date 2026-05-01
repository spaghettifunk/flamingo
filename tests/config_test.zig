//! config_test.zig — unit tests for config.zig
//!
//! Uses toml.Parser.parseString so no actual files are read.

const std = @import("std");
const config = @import("../src/config.zig");
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
    try std.testing.expectEqualStrings("ctrl+e", cfg.keybindings.switch_focus);
    try std.testing.expectEqualStrings("ctrl+w", cfg.keybindings.close_tab);
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
