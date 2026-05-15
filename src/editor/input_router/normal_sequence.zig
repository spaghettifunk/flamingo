const std = @import("std");
const terminal = @import("../../terminal.zig");

pub const max_sequence_len = 4;

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
};

pub const ResolveResult = union(enum) {
    none,
    prefix,
    command: NormalCommand,
};

pub const KeySequence = struct {
    // KeyEvent is used directly because it currently contains only semantic key
    // identity fields and eql(). If non-semantic fields are added later, replace
    // this with a normalized sequence key type.
    keys: [max_sequence_len]terminal.KeyEvent = [_]terminal.KeyEvent{.{}} ** max_sequence_len,
    len: usize = 0,

    pub fn fromKeys(comptime keys: []const terminal.KeyEvent) KeySequence {
        comptime {
            if (keys.len > max_sequence_len) @compileError("normal key sequence is too long");
        }

        var sequence = KeySequence{};
        inline for (keys) |key| {
            sequence.keys[sequence.len] = key;
            sequence.len += 1;
        }
        return sequence;
    }

    pub fn clear(self: *KeySequence) void {
        self.len = 0;
    }

    pub fn append(self: *KeySequence, key: terminal.KeyEvent) bool {
        if (self.len >= max_sequence_len) return false;
        self.keys[self.len] = key;
        self.len += 1;
        return true;
    }

    pub fn eql(self: KeySequence, other: KeySequence) bool {
        if (self.len != other.len) return false;
        for (0..self.len) |i| {
            if (!self.keys[i].eql(other.keys[i])) return false;
        }
        return true;
    }

    pub fn startsWith(self: KeySequence, prefix: KeySequence) bool {
        if (prefix.len > self.len) return false;
        for (0..prefix.len) |i| {
            if (!self.keys[i].eql(prefix.keys[i])) return false;
        }
        return true;
    }
};

pub const NormalKeyBinding = struct {
    sequence: KeySequence,
    command: NormalCommand,
};

fn charKey(c: u8) terminal.KeyEvent {
    return .{ .key = .Char, .char = c };
}

const normal_key_bindings = [_]NormalKeyBinding{
    .{
        .sequence = KeySequence.fromKeys(&.{ charKey('g'), charKey('g') }),
        .command = .jump_top,
    },
    .{
        .sequence = KeySequence.fromKeys(&.{charKey('G')}),
        .command = .jump_bottom,
    },
    .{
        .sequence = KeySequence.fromKeys(&.{charKey('%')}),
        .command = .jump_matching_bracket,
    },
    .{
        .sequence = KeySequence.fromKeys(&.{charKey('f')}),
        .command = .jump_to_function_definition,
    },
    .{
        .sequence = KeySequence.fromKeys(&.{ charKey('z'), charKey('h') }),
        .command = .scroll_left_small,
    },
    .{
        .sequence = KeySequence.fromKeys(&.{ charKey('z'), charKey('l') }),
        .command = .scroll_right_small,
    },
    .{
        .sequence = KeySequence.fromKeys(&.{ charKey('z'), charKey('H') }),
        .command = .scroll_left_half,
    },
    .{
        .sequence = KeySequence.fromKeys(&.{ charKey('z'), charKey('L') }),
        .command = .scroll_right_half,
    },
    .{
        .sequence = KeySequence.fromKeys(&.{ charKey('z'), charKey('s') }),
        .command = .scroll_cursor_start,
    },
    .{
        .sequence = KeySequence.fromKeys(&.{ charKey('z'), charKey('e') }),
        .command = .scroll_cursor_end,
    },
    .{
        .sequence = KeySequence.fromKeys(&.{ charKey('z'), charKey('c') }),
        .command = .fold_current,
    },
    .{
        .sequence = KeySequence.fromKeys(&.{ charKey('z'), charKey('o') }),
        .command = .unfold_current,
    },
    .{
        .sequence = KeySequence.fromKeys(&.{ charKey('z'), charKey('a') }),
        .command = .toggle_fold_current,
    },
    .{
        .sequence = KeySequence.fromKeys(&.{ charKey('z'), charKey('M') }),
        .command = .fold_all,
    },
    .{
        .sequence = KeySequence.fromKeys(&.{ charKey('z'), charKey('R') }),
        .command = .unfold_all,
    },
    .{
        .sequence = KeySequence.fromKeys(&.{ charKey('z'), charKey('A') }),
        .command = .toggle_fold_all,
    },
};

pub fn resolve(sequence: KeySequence) ResolveResult {
    var exact_command: ?NormalCommand = null;
    var has_longer_prefix_match = false;

    for (normal_key_bindings) |binding| {
        if (!binding.sequence.startsWith(sequence)) continue;

        if (binding.sequence.len == sequence.len) {
            exact_command = binding.command;
        } else {
            has_longer_prefix_match = true;
        }
    }

    // Initial ambiguity policy: if a sequence is both complete and a prefix of
    // a longer command, execute the shorter command immediately. Timeout-based
    // disambiguation is intentionally out of scope for now.
    if (exact_command) |command| return .{ .command = command };
    if (has_longer_prefix_match) return .prefix;
    return .none;
}

test "normal z horizontal scroll sequences resolve" {
    const cases = [_]struct {
        keys: KeySequence,
        command: NormalCommand,
    }{
        .{ .keys = KeySequence.fromKeys(&.{ charKey('z'), charKey('h') }), .command = .scroll_left_small },
        .{ .keys = KeySequence.fromKeys(&.{ charKey('z'), charKey('l') }), .command = .scroll_right_small },
        .{ .keys = KeySequence.fromKeys(&.{ charKey('z'), charKey('H') }), .command = .scroll_left_half },
        .{ .keys = KeySequence.fromKeys(&.{ charKey('z'), charKey('L') }), .command = .scroll_right_half },
        .{ .keys = KeySequence.fromKeys(&.{ charKey('z'), charKey('s') }), .command = .scroll_cursor_start },
        .{ .keys = KeySequence.fromKeys(&.{ charKey('z'), charKey('e') }), .command = .scroll_cursor_end },
    };

    try std.testing.expect(resolve(KeySequence.fromKeys(&.{charKey('z')})) == .prefix);
    for (cases) |case| {
        const result = resolve(case.keys);
        const command = switch (result) {
            .command => |command| command,
            else => return error.ExpectedCommand,
        };
        try std.testing.expectEqual(case.command, command);
    }
}

test "normal z fold sequences resolve" {
    const cases = [_]struct {
        keys: KeySequence,
        command: NormalCommand,
    }{
        .{ .keys = KeySequence.fromKeys(&.{ charKey('z'), charKey('c') }), .command = .fold_current },
        .{ .keys = KeySequence.fromKeys(&.{ charKey('z'), charKey('o') }), .command = .unfold_current },
        .{ .keys = KeySequence.fromKeys(&.{ charKey('z'), charKey('a') }), .command = .toggle_fold_current },
        .{ .keys = KeySequence.fromKeys(&.{ charKey('z'), charKey('M') }), .command = .fold_all },
        .{ .keys = KeySequence.fromKeys(&.{ charKey('z'), charKey('R') }), .command = .unfold_all },
        .{ .keys = KeySequence.fromKeys(&.{ charKey('z'), charKey('A') }), .command = .toggle_fold_all },
    };

    try std.testing.expect(resolve(KeySequence.fromKeys(&.{charKey('z')})) == .prefix);
    for (cases) |case| {
        const result = resolve(case.keys);
        const command = switch (result) {
            .command => |command| command,
            else => return error.ExpectedCommand,
        };
        try std.testing.expectEqual(case.command, command);
    }
}

test "normal f resolves to jump to function definition" {
    const result = resolve(KeySequence.fromKeys(&.{charKey('f')}));
    const command = switch (result) {
        .command => |command| command,
        else => return error.ExpectedCommand,
    };
    try std.testing.expectEqual(NormalCommand.jump_to_function_definition, command);
}
