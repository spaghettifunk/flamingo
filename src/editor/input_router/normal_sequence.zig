const std = @import("std");
const terminal = @import("../../terminal.zig");
const commands = @import("../commands.zig");
const keybindings = @import("../keybindings.zig");

pub const max_sequence_len = keybindings.KeySequence.max_len;
pub const KeySequence = keybindings.KeySequence;

pub const NormalCommand = enum {
    jump_top,
    jump_bottom,
    jump_matching_bracket,
    jump_to_function_definition,
    scroll_left_small,
    scroll_right_small,
    scroll_left_half,
    scroll_right_half,
    scroll_cursor_start,
    scroll_cursor_end,
    fold_current,
    unfold_current,
    toggle_fold_current,
    fold_all,
    unfold_all,
    toggle_fold_all,
    next_comment,
    previous_comment,
};

pub const ResolveResult = union(enum) {
    none,
    prefix,
    command: NormalCommand,
};

pub fn normalCommandFromCommandId(id: commands.CommandId) ?NormalCommand {
    return switch (id) {
        .navigation_goto_file_start => .jump_top,
        .navigation_goto_file_end => .jump_bottom,
        .navigation_matching_bracket => .jump_matching_bracket,
        .navigation_goto_definition => .jump_to_function_definition,
        .navigation_scroll_left => .scroll_left_small,
        .navigation_scroll_right => .scroll_right_small,
        .navigation_scroll_left_half_page => .scroll_left_half,
        .navigation_scroll_right_half_page => .scroll_right_half,
        .navigation_scroll_cursor_start => .scroll_cursor_start,
        .navigation_scroll_cursor_end => .scroll_cursor_end,
        .fold_close => .fold_current,
        .fold_open => .unfold_current,
        .fold_toggle => .toggle_fold_current,
        .fold_close_all => .fold_all,
        .fold_open_all => .unfold_all,
        .fold_toggle_all => .toggle_fold_all,
        .navigation_next_comment => .next_comment,
        .navigation_previous_comment => .previous_comment,
        else => null,
    };
}

pub fn isMovementCommandId(id: commands.CommandId) bool {
    return switch (id) {
        .navigation_move_up,
        .navigation_move_down,
        .navigation_move_left,
        .navigation_move_right,
        .navigation_page_up,
        .navigation_page_down,
        .navigation_line_start,
        .navigation_line_end,
        .navigation_word_left,
        .navigation_word_right,
        => true,
        else => false,
    };
}

pub fn resolveMovementCommand(registry: *const keybindings.Registry, event: terminal.KeyEvent) ?commands.CommandId {
    const sequence = KeySequence.fromEvent(event);
    const result = registry.resolve(.normal, sequence);
    const id = switch (result) {
        .command => |id| id,
        else => return null,
    };
    return if (isMovementCommandId(id)) id else null;
}

pub fn isJumpCommandId(id: commands.CommandId) bool {
    return switch (id) {
        .navigation_jump_back,
        .navigation_jump_forward,
        => true,
        else => false,
    };
}

pub fn resolveJumpCommand(registry: *const keybindings.Registry, event: terminal.KeyEvent) ?commands.CommandId {
    const sequence = KeySequence.fromEvent(event);
    const result = registry.resolve(.normal, sequence);
    const id = switch (result) {
        .command => |id| id,
        else => return null,
    };
    return if (isJumpCommandId(id)) id else null;
}

pub fn isActionCommandId(id: commands.CommandId) bool {
    return switch (id) {
        .mode_normal,
        .mode_insert,
        .mode_command,
        .mode_search,
        .file_write,
        .editing_undo,
        .editing_redo,
        .editing_select_all,
        .editing_copy,
        .editing_cut,
        .editing_paste,
        .editing_delete_word_back,
        .editing_duplicate_line,
        .editing_delete_line,
        .editing_add_cursor_above,
        .editing_add_cursor_below,
        .editing_select_next_occurrence,
        .completion_auto_trigger,
        .completion_trigger,
        => true,
        else => false,
    };
}

pub fn resolveActionCommand(registry: *const keybindings.Registry, event: terminal.KeyEvent) ?commands.CommandId {
    const sequence = KeySequence.fromEvent(event);
    const result = registry.resolve(.normal, sequence);
    const id = switch (result) {
        .command => |id| id,
        else => return null,
    };
    return if (isActionCommandId(id)) id else null;
}

pub fn isGlobalActionCommandId(id: commands.CommandId) bool {
    return switch (id) {
        .app_quit_flamingo,
        .app_close_tab,
        .app_next_tab,
        .app_previous_tab,
        .app_cycle_panel_focus,
        .explorer_toggle,
        .terminal_toggle,
        => true,
        else => false,
    };
}

pub fn resolveGlobalActionCommand(registry: *const keybindings.Registry, event: terminal.KeyEvent) ?commands.CommandId {
    const sequence = KeySequence.fromEvent(event);
    const result = registry.resolve(.global, sequence);
    const id = switch (result) {
        .command => |id| id,
        else => return null,
    };
    return if (isGlobalActionCommandId(id)) id else null;
}

pub fn resolve(registry: *const keybindings.Registry, sequence: KeySequence) ResolveResult {
    var exact_command: ?NormalCommand = null;
    var has_longer_prefix_match = false;

    for (registry.bindings) |binding| {
        if (binding.context != .normal) continue;
        const normal_command = normalCommandFromCommandId(binding.command) orelse continue;
        if (!binding.sequence.startsWith(sequence)) continue;

        if (binding.sequence.len == sequence.len) {
            exact_command = normal_command;
        } else {
            has_longer_prefix_match = true;
        }
    }

    // Preserve the original ambiguity policy: a complete command executes
    // immediately even if it ever becomes a prefix of a longer sequence.
    if (exact_command) |command| return .{ .command = command };
    if (has_longer_prefix_match) return .prefix;
    return .none;
}

fn charKey(c: u8) terminal.KeyEvent {
    return .{ .key = .Char, .char = c };
}

fn specialKey(key: terminal.Key) terminal.KeyEvent {
    return .{ .key = key };
}

fn altKey(key: terminal.Key) terminal.KeyEvent {
    return .{ .key = key, .alt = true };
}

fn altCharKey(c: u8) terminal.KeyEvent {
    return .{ .key = .Char, .char = c, .alt = true };
}

fn shiftKey(key: terminal.Key) terminal.KeyEvent {
    return .{ .key = key, .shift = true };
}

fn shiftAltKey(key: terminal.Key) terminal.KeyEvent {
    return .{ .key = key, .alt = true, .shift = true };
}

fn expectCommand(sequence: KeySequence, expected: NormalCommand) !void {
    const registry = keybindings.defaultRegistry();
    const command = switch (resolve(&registry, sequence)) {
        .command => |command| command,
        else => return error.ExpectedCommand,
    };
    try std.testing.expectEqual(expected, command);
}

test "normal resolver uses central registry for all legacy sequences" {
    const cases = [_]struct {
        keys: KeySequence,
        command: NormalCommand,
    }{
        .{ .keys = KeySequence.fromKeys(&.{ charKey('g'), charKey('g') }), .command = .jump_top },
        .{ .keys = KeySequence.fromKeys(&.{charKey('G')}), .command = .jump_bottom },
        .{ .keys = KeySequence.fromKeys(&.{charKey('%')}), .command = .jump_matching_bracket },
        .{ .keys = KeySequence.fromKeys(&.{charKey('f')}), .command = .jump_to_function_definition },
        .{ .keys = KeySequence.fromKeys(&.{ charKey('z'), charKey('h') }), .command = .scroll_left_small },
        .{ .keys = KeySequence.fromKeys(&.{ charKey('z'), charKey('l') }), .command = .scroll_right_small },
        .{ .keys = KeySequence.fromKeys(&.{ charKey('z'), charKey('H') }), .command = .scroll_left_half },
        .{ .keys = KeySequence.fromKeys(&.{ charKey('z'), charKey('L') }), .command = .scroll_right_half },
        .{ .keys = KeySequence.fromKeys(&.{ charKey('z'), charKey('s') }), .command = .scroll_cursor_start },
        .{ .keys = KeySequence.fromKeys(&.{ charKey('z'), charKey('e') }), .command = .scroll_cursor_end },
        .{ .keys = KeySequence.fromKeys(&.{ charKey('z'), charKey('c') }), .command = .fold_current },
        .{ .keys = KeySequence.fromKeys(&.{ charKey('z'), charKey('o') }), .command = .unfold_current },
        .{ .keys = KeySequence.fromKeys(&.{ charKey('z'), charKey('a') }), .command = .toggle_fold_current },
        .{ .keys = KeySequence.fromKeys(&.{ charKey('z'), charKey('M') }), .command = .fold_all },
        .{ .keys = KeySequence.fromKeys(&.{ charKey('z'), charKey('R') }), .command = .unfold_all },
        .{ .keys = KeySequence.fromKeys(&.{ charKey('z'), charKey('A') }), .command = .toggle_fold_all },
        .{ .keys = KeySequence.fromKeys(&.{ charKey(']'), charKey('c') }), .command = .next_comment },
        .{ .keys = KeySequence.fromKeys(&.{ charKey('['), charKey('c') }), .command = .previous_comment },
    };

    for (cases) |case| {
        try expectCommand(case.keys, case.command);
    }
}

test "normal resolver preserves prefix and no-match behavior" {
    const registry = keybindings.defaultRegistry();
    try std.testing.expect(resolve(&registry, KeySequence.fromKeys(&.{charKey('g')})) == .prefix);
    try std.testing.expect(resolve(&registry, KeySequence.fromKeys(&.{charKey('z')})) == .prefix);
    try std.testing.expect(resolve(&registry, KeySequence.fromKeys(&.{ charKey('g'), charKey('x') })) == .none);
    try std.testing.expect(resolve(&registry, KeySequence.fromKeys(&.{charKey('x')})) == .none);
}

test "normal resolver executes single-key commands immediately" {
    try expectCommand(KeySequence.fromKeys(&.{charKey('G')}), .jump_bottom);
    try expectCommand(KeySequence.fromKeys(&.{charKey('%')}), .jump_matching_bracket);
    try expectCommand(KeySequence.fromKeys(&.{charKey('f')}), .jump_to_function_definition);
}

test "normal movement resolver uses central registry for migrated single chords" {
    const registry = keybindings.defaultRegistry();
    const cases = [_]struct {
        event: terminal.KeyEvent,
        command: commands.CommandId,
    }{
        .{ .event = specialKey(.Up), .command = .navigation_move_up },
        .{ .event = specialKey(.Down), .command = .navigation_move_down },
        .{ .event = specialKey(.Left), .command = .navigation_move_left },
        .{ .event = specialKey(.Right), .command = .navigation_move_right },
        .{ .event = specialKey(.PageUp), .command = .navigation_page_up },
        .{ .event = specialKey(.PageDown), .command = .navigation_page_down },
        .{ .event = altKey(.Down), .command = .navigation_line_start },
        .{ .event = altKey(.Up), .command = .navigation_line_end },
        .{ .event = altKey(.Left), .command = .navigation_word_left },
        .{ .event = altKey(.Right), .command = .navigation_word_right },
        .{ .event = shiftKey(.Up), .command = .navigation_move_up },
        .{ .event = shiftKey(.Down), .command = .navigation_move_down },
        .{ .event = shiftKey(.Left), .command = .navigation_move_left },
        .{ .event = shiftKey(.Right), .command = .navigation_move_right },
        .{ .event = shiftKey(.PageUp), .command = .navigation_page_up },
        .{ .event = shiftKey(.PageDown), .command = .navigation_page_down },
        .{ .event = shiftAltKey(.Down), .command = .navigation_line_start },
        .{ .event = shiftAltKey(.Up), .command = .navigation_line_end },
        .{ .event = shiftAltKey(.Left), .command = .navigation_word_left },
        .{ .event = shiftAltKey(.Right), .command = .navigation_word_right },
    };

    for (cases) |case| {
        try std.testing.expectEqual(case.command, resolveMovementCommand(&registry, case.event).?);
    }
}

test "normal movement resolver ignores sequence prefixes and non-movement commands" {
    const registry = keybindings.defaultRegistry();
    try std.testing.expect(resolveMovementCommand(&registry, charKey('g')) == null);
    try std.testing.expect(resolveMovementCommand(&registry, charKey('z')) == null);
    try std.testing.expect(resolveMovementCommand(&registry, charKey('G')) == null);
    try std.testing.expect(resolveMovementCommand(&registry, charKey('%')) == null);
    try std.testing.expect(resolveMovementCommand(&registry, charKey('f')) == null);
    try std.testing.expect(resolveMovementCommand(&registry, charKey('i')) == null);
}

test "normal jump resolver uses central registry for migrated single chords" {
    const registry = keybindings.defaultRegistry();
    try std.testing.expectEqual(commands.CommandId.navigation_jump_back, resolveJumpCommand(&registry, altCharKey('o')).?);
    try std.testing.expectEqual(commands.CommandId.navigation_jump_forward, resolveJumpCommand(&registry, altCharKey('p')).?);
    try std.testing.expect(resolveJumpCommand(&registry, specialKey(.Up)) == null);
    try std.testing.expect(resolveJumpCommand(&registry, charKey('g')) == null);
    try std.testing.expect(resolveJumpCommand(&registry, charKey('z')) == null);
}

test "normal action resolver uses central registry for migrated action shortcuts" {
    const registry = keybindings.defaultRegistry();
    const cases = [_]struct {
        event: terminal.KeyEvent,
        command: commands.CommandId,
    }{
        .{ .event = charKey('i'), .command = .mode_insert },
        .{ .event = charKey(':'), .command = .mode_command },
        .{ .event = charKey('/'), .command = .mode_search },
        .{ .event = specialKey(.Esc), .command = .mode_normal },
        .{ .event = .{ .key = .Char, .char = 's', .ctrl = true }, .command = .file_write },
        .{ .event = .{ .key = .Char, .char = 'z', .ctrl = true }, .command = .editing_undo },
        .{ .event = .{ .key = .Char, .char = 'y', .ctrl = true }, .command = .editing_redo },
        .{ .event = .{ .key = .Char, .char = 'a', .ctrl = true }, .command = .editing_select_all },
        .{ .event = .{ .key = .Char, .char = 'c', .ctrl = true }, .command = .editing_copy },
        .{ .event = .{ .key = .Char, .char = 'x', .ctrl = true }, .command = .editing_cut },
        .{ .event = .{ .key = .Char, .char = 'v', .ctrl = true }, .command = .editing_paste },
        .{ .event = altKey(.Delete), .command = .editing_delete_word_back },
        .{ .event = altKey(.Backspace), .command = .editing_delete_word_back },
        .{ .event = .{ .key = .Char, .char = 'd', .ctrl = true }, .command = .editing_duplicate_line },
        .{ .event = .{ .key = .Char, .char = 'k', .ctrl = true, .shift = true }, .command = .editing_delete_line },
        .{ .event = .{ .key = .Char, .char = 'k', .ctrl = true }, .command = .editing_delete_line },
        .{ .event = .{ .key = .Up, .ctrl = true, .alt = true }, .command = .editing_add_cursor_above },
        .{ .event = .{ .key = .Down, .ctrl = true, .alt = true }, .command = .editing_add_cursor_below },
        .{ .event = charKey('.'), .command = .completion_auto_trigger },
        .{ .event = .{ .key = .Char, .char = ' ', .ctrl = true }, .command = .completion_trigger },
    };

    for (cases) |case| {
        try std.testing.expectEqual(case.command, resolveActionCommand(&registry, case.event).?);
    }
}

test "normal action resolver ignores sequence prefixes movement and sequence commands" {
    const registry = keybindings.defaultRegistry();
    try std.testing.expect(resolveActionCommand(&registry, charKey('g')) == null);
    try std.testing.expect(resolveActionCommand(&registry, charKey('z')) == null);
    try std.testing.expect(resolveActionCommand(&registry, specialKey(.Up)) == null);
    try std.testing.expect(resolveActionCommand(&registry, charKey('G')) == null);
    try std.testing.expect(resolveActionCommand(&registry, charKey('%')) == null);
    try std.testing.expect(resolveActionCommand(&registry, charKey('f')) == null);
}

test "normal global action resolver uses central registry for migrated global shortcuts" {
    const registry = keybindings.defaultRegistry();
    const cases = [_]struct {
        event: terminal.KeyEvent,
        command: commands.CommandId,
    }{
        .{ .event = .{ .key = .Char, .char = 'q', .ctrl = true }, .command = .app_quit_flamingo },
        .{ .event = .{ .key = .Char, .char = 'b', .ctrl = true }, .command = .explorer_toggle },
        .{ .event = .{ .key = .Char, .char = 't', .ctrl = true }, .command = .terminal_toggle },
        .{ .event = .{ .key = .Char, .char = 'e', .ctrl = true }, .command = .app_cycle_panel_focus },
        .{ .event = .{ .key = .Char, .char = 'w', .ctrl = true }, .command = .app_close_tab },
        .{ .event = altCharKey(']'), .command = .app_next_tab },
        .{ .event = altCharKey('['), .command = .app_previous_tab },
    };

    for (cases) |case| {
        try std.testing.expectEqual(case.command, resolveGlobalActionCommand(&registry, case.event).?);
    }

    try std.testing.expect(resolveGlobalActionCommand(&registry, charKey('g')) == null);
    try std.testing.expect(resolveGlobalActionCommand(&registry, specialKey(.Up)) == null);
}

test "normal command mapping covers registry-backed normal sequence commands" {
    const expected = [_]commands.CommandId{
        .navigation_goto_file_start,
        .navigation_goto_file_end,
        .navigation_matching_bracket,
        .navigation_goto_definition,
        .navigation_scroll_left,
        .navigation_scroll_right,
        .navigation_scroll_left_half_page,
        .navigation_scroll_right_half_page,
        .navigation_scroll_cursor_start,
        .navigation_scroll_cursor_end,
        .fold_close,
        .fold_open,
        .fold_toggle,
        .fold_close_all,
        .fold_open_all,
        .fold_toggle_all,
        .navigation_next_comment,
        .navigation_previous_comment,
    };

    for (expected) |id| {
        try std.testing.expect(normalCommandFromCommandId(id) != null);

        var has_binding = false;
        for (keybindings.defaultBindings()) |binding| {
            if (binding.context == .normal and binding.command == id) {
                has_binding = true;
                break;
            }
        }
        try std.testing.expect(has_binding);
    }
}

test "non-sequence normal defaults stay outside compatibility resolver" {
    const registry = keybindings.defaultRegistry();
    try std.testing.expect(resolve(&registry, KeySequence.fromKeys(&.{charKey('i')})) == .none);
    try std.testing.expect(resolve(&registry, KeySequence.fromKeys(&.{.{ .key = .Down }})) == .none);
}
