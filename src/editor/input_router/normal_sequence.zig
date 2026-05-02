const terminal = @import("../../terminal.zig");

pub const max_sequence_len = 4;

pub const NormalCommand = enum {
    jump_top,
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
