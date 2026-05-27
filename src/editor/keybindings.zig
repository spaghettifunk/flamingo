const std = @import("std");
const terminal = @import("../terminal.zig");
const commands = @import("commands.zig");

pub const BindingContext = commands.CommandContext;

pub const KeyChord = struct {
    key: terminal.Key = .None,
    char: u8 = 0,
    ctrl: bool = false,
    alt: bool = false,
    shift: bool = false,

    pub fn eql(a: KeyChord, b: KeyChord) bool {
        return a.key == b.key and
            a.char == b.char and
            a.ctrl == b.ctrl and
            a.alt == b.alt and
            a.shift == b.shift;
    }

    pub fn fromEvent(event: terminal.KeyEvent) KeyChord {
        return .{
            .key = event.key,
            .char = event.char,
            .ctrl = event.ctrl,
            .alt = event.alt,
            .shift = event.shift,
        };
    }

    pub fn toEvent(self: KeyChord) terminal.KeyEvent {
        return .{
            .key = self.key,
            .char = self.char,
            .ctrl = self.ctrl,
            .alt = self.alt,
            .shift = self.shift,
        };
    }
};

pub const KeySequence = struct {
    pub const max_len = 4;

    chords: [max_len]KeyChord = [_]KeyChord{.{}} ** max_len,
    len: usize = 0,

    pub fn fromChords(comptime chords: []const KeyChord) KeySequence {
        comptime {
            if (chords.len > max_len) @compileError("key sequence is too long");
        }

        var sequence = KeySequence{};
        inline for (chords) |chord| {
            sequence.chords[sequence.len] = chord;
            sequence.len += 1;
        }
        return sequence;
    }

    pub fn fromChord(chord: KeyChord) KeySequence {
        var sequence = KeySequence{};
        sequence.chords[0] = chord;
        sequence.len = 1;
        return sequence;
    }

    pub fn fromEvent(event: terminal.KeyEvent) KeySequence {
        return fromChord(KeyChord.fromEvent(event));
    }

    pub fn fromKeys(comptime keys: []const terminal.KeyEvent) KeySequence {
        comptime {
            if (keys.len > max_len) @compileError("key sequence is too long");
        }

        var sequence = KeySequence{};
        inline for (keys) |key| {
            sequence.chords[sequence.len] = KeyChord.fromEvent(key);
            sequence.len += 1;
        }
        return sequence;
    }

    pub fn clear(self: *KeySequence) void {
        self.len = 0;
    }

    pub fn append(self: *KeySequence, event: terminal.KeyEvent) bool {
        return self.appendChord(KeyChord.fromEvent(event));
    }

    pub fn appendChord(self: *KeySequence, chord: KeyChord) bool {
        if (self.len >= max_len) return false;
        self.chords[self.len] = chord;
        self.len += 1;
        return true;
    }

    pub fn eql(a: KeySequence, b: KeySequence) bool {
        if (a.len != b.len) return false;
        for (0..a.len) |i| {
            if (!KeyChord.eql(a.chords[i], b.chords[i])) return false;
        }
        return true;
    }

    pub fn startsWith(a: KeySequence, prefix: KeySequence) bool {
        if (prefix.len > a.len) return false;
        for (0..prefix.len) |i| {
            if (!KeyChord.eql(a.chords[i], prefix.chords[i])) return false;
        }
        return true;
    }
};

pub const BindingSource = enum {
    default,
    user_config,
};

pub const Binding = struct {
    context: BindingContext,
    sequence: KeySequence,
    command: commands.CommandId,
    source: BindingSource = .default,
};

pub const ResolveResult = union(enum) {
    none,
    prefix,
    command: commands.CommandId,
};

pub const KeyParseError = error{
    EmptyKey,
    InvalidChord,
    InvalidModifier,
    SequenceTooLong,
    UnknownKey,
};

pub const DiagnosticSeverity = enum {
    err,
    warning,
};

pub const Diagnostic = struct {
    severity: DiagnosticSeverity,
    message: []const u8,
};

pub const BuildDiagnostics = struct {
    items: std.ArrayListUnmanaged(Diagnostic) = .empty,

    pub fn deinit(self: *BuildDiagnostics, allocator: std.mem.Allocator) void {
        for (self.items.items) |item| {
            allocator.free(item.message);
        }
        self.items.deinit(allocator);
        self.* = .{};
    }

    pub fn hasErrors(self: *const BuildDiagnostics) bool {
        for (self.items.items) |item| {
            if (item.severity == .err) return true;
        }
        return false;
    }

    pub fn addError(self: *BuildDiagnostics, allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
        try self.add(allocator, .err, fmt, args);
    }

    pub fn addWarning(self: *BuildDiagnostics, allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
        try self.add(allocator, .warning, fmt, args);
    }

    fn add(self: *BuildDiagnostics, allocator: std.mem.Allocator, severity: DiagnosticSeverity, comptime fmt: []const u8, args: anytype) !void {
        const message = try std.fmt.allocPrint(allocator, fmt, args);
        errdefer allocator.free(message);
        try self.items.append(allocator, .{ .severity = severity, .message = message });
    }

    pub fn print(self: *const BuildDiagnostics) void {
        for (self.items.items) |item| {
            const label = switch (item.severity) {
                .err => "error",
                .warning => "warning",
            };
            std.debug.print("keybindings {s}: {s}\n", .{ label, item.message });
        }
    }
};

pub const UserBindingOverride = struct {
    context: BindingContext,
    sequence: KeySequence,
    command: commands.CommandId,
    source_key: []const u8 = "",
    source_command: []const u8 = "",
    replace_default_sequence: ?KeySequence = null,
};

pub const UserUnbind = struct {
    context: BindingContext,
    sequence: KeySequence,
    source_key: []const u8 = "",
};

pub const BuildError = std.mem.Allocator.Error || error{InvalidKeybindingConfig};

pub const Registry = struct {
    bindings: []const Binding,
    owned: bool = false,

    pub fn defaults() Registry {
        return .{ .bindings = defaultBindings() };
    }

    pub fn deinit(self: *Registry, allocator: std.mem.Allocator) void {
        if (self.owned) allocator.free(self.bindings);
        self.* = Registry.defaults();
    }

    pub fn resolve(self: *const Registry, context: BindingContext, pending: KeySequence) ResolveResult {
        if (pending.len == 0) return .none;

        var exact_command: ?commands.CommandId = null;
        var has_longer_prefix_match = false;
        for (self.bindings) |binding| {
            if (binding.context != context) continue;
            if (!binding.sequence.startsWith(pending)) continue;

            if (binding.sequence.len == pending.len) {
                exact_command = binding.command;
            } else {
                has_longer_prefix_match = true;
            }
        }

        if (exact_command) |command| return .{ .command = command };
        if (has_longer_prefix_match) return .prefix;
        return .none;
    }

    pub fn countBindingsForCommand(self: *const Registry, id: commands.CommandId) usize {
        var count: usize = 0;
        for (self.bindings) |binding| {
            if (binding.command == id) count += 1;
        }
        return count;
    }

    pub fn bindingForCommandAt(self: *const Registry, id: commands.CommandId, index: usize) ?Binding {
        var seen: usize = 0;
        for (self.bindings) |binding| {
            if (binding.command != id) continue;
            if (seen == index) return binding;
            seen += 1;
        }
        return null;
    }

    pub fn fromDefaultsAndConfig(
        allocator: std.mem.Allocator,
        overrides: []const UserBindingOverride,
        unbinds: []const UserUnbind,
        diagnostics: *BuildDiagnostics,
    ) BuildError!Registry {
        var resolved = std.ArrayListUnmanaged(Binding).empty;
        errdefer resolved.deinit(allocator);

        try resolved.appendSlice(allocator, defaultBindings());

        for (unbinds) |unbind| {
            var removed = false;
            var index: usize = 0;
            while (index < resolved.items.len) {
                const binding = resolved.items[index];
                if (binding.context == unbind.context and binding.sequence.eql(unbind.sequence)) {
                    _ = resolved.orderedRemove(index);
                    removed = true;
                    continue;
                }
                index += 1;
            }
            if (!removed) {
                try diagnostics.addWarning(
                    allocator,
                    "unbind for [{s}] \"{s}\" did not match a default binding",
                    .{ @tagName(unbind.context), unbind.source_key },
                );
            }
        }

        for (overrides, 0..) |override, override_index| {
            if (!commands.isContextAllowed(override.command, override.context)) {
                try diagnostics.addError(
                    allocator,
                    "[{s}] \"{s}\" maps to command \"{s}\", which is not valid in that context",
                    .{ @tagName(override.context), override.source_key, override.source_command },
                );
                continue;
            }

            if (override.replace_default_sequence) |default_sequence| {
                var remove_index: usize = 0;
                while (remove_index < resolved.items.len) {
                    const binding = resolved.items[remove_index];
                    if (binding.source == .default and binding.context == override.context and binding.sequence.eql(default_sequence)) {
                        _ = resolved.orderedRemove(remove_index);
                        continue;
                    }
                    remove_index += 1;
                }
            }

            for (overrides[override_index + 1 ..]) |other| {
                if (override.context == other.context and override.sequence.eql(other.sequence)) {
                    try diagnostics.addError(
                        allocator,
                        "duplicate user binding for [{s}] \"{s}\"",
                        .{ @tagName(override.context), override.source_key },
                    );
                    break;
                }
            }

            var replaced = false;
            for (resolved.items) |*binding| {
                if (binding.context == override.context and binding.sequence.eql(override.sequence)) {
                    binding.* = .{
                        .context = override.context,
                        .sequence = override.sequence,
                        .command = override.command,
                        .source = .user_config,
                    };
                    replaced = true;
                    break;
                }
            }
            if (!replaced) {
                try resolved.append(allocator, .{
                    .context = override.context,
                    .sequence = override.sequence,
                    .command = override.command,
                    .source = .user_config,
                });
            }
        }

        validateBindings(resolved.items) catch |err| {
            switch (err) {
                error.DuplicateBinding => try diagnostics.addError(allocator, "duplicate keybinding in resolved registry", .{}),
                error.InvalidCommandContext => try diagnostics.addError(allocator, "resolved keybinding uses a command in an invalid context", .{}),
                error.PrefixConflict => try diagnostics.addError(allocator, "prefix conflict in resolved keybindings under the no-timeout resolver", .{}),
            }
        };

        if (diagnostics.hasErrors()) return error.InvalidKeybindingConfig;

        return .{
            .bindings = try resolved.toOwnedSlice(allocator),
            .owned = true,
        };
    }
};

pub const ValidationError = error{
    DuplicateBinding,
    InvalidCommandContext,
    PrefixConflict,
};

pub fn defaultRegistry() Registry {
    return Registry.defaults();
}

pub fn defaultBindings() []const Binding {
    return &default_bindings;
}

pub fn contextByName(name: []const u8) ?BindingContext {
    inline for (std.meta.fields(BindingContext)) |field| {
        if (std.mem.eql(u8, field.name, name)) return @enumFromInt(field.value);
    }
    return null;
}

pub fn countDefaultBindingsForContext(context: BindingContext) usize {
    var count: usize = 0;
    for (default_bindings) |binding| {
        if (binding.context == context) count += 1;
    }
    return count;
}

pub fn validateDefaultBindings() ValidationError!void {
    try validateBindings(defaultBindings());
}

pub fn validateBindings(bindings: []const Binding) ValidationError!void {
    for (bindings, 0..) |left, left_index| {
        _ = commands.metadata(left.command);
        if (!commands.isContextAllowed(left.command, left.context)) return error.InvalidCommandContext;

        for (bindings[left_index + 1 ..]) |right| {
            if (left.context != right.context) continue;
            if (left.sequence.eql(right.sequence)) return error.DuplicateBinding;
            if (left.sequence.startsWith(right.sequence) or right.sequence.startsWith(left.sequence)) {
                return error.PrefixConflict;
            }
        }
    }
}

pub fn hasDefaultBinding(context: BindingContext, sequence: KeySequence, command: commands.CommandId) bool {
    for (default_bindings) |binding| {
        if (binding.context == context and binding.command == command and binding.sequence.eql(sequence)) return true;
    }
    return false;
}

pub fn charSeq(comptime chars: []const u8) KeySequence {
    comptime {
        if (chars.len > KeySequence.max_len) @compileError("key sequence is too long");
    }

    var sequence = KeySequence{};
    inline for (chars) |ch| {
        sequence.chords[sequence.len] = .{ .key = .Char, .char = ch };
        sequence.len += 1;
    }
    return sequence;
}

pub fn keyChar(ch: u8) KeySequence {
    return KeySequence.fromChord(.{ .key = .Char, .char = ch });
}

pub fn keySpecial(key: terminal.Key) KeySequence {
    return KeySequence.fromChord(.{ .key = key });
}

pub fn ctrlChar(ch: u8) KeySequence {
    return KeySequence.fromChord(.{ .key = .Char, .char = ch, .ctrl = true });
}

pub fn ctrlShiftChar(ch: u8) KeySequence {
    return KeySequence.fromChord(.{ .key = .Char, .char = ch, .ctrl = true, .shift = true });
}

pub fn altChar(ch: u8) KeySequence {
    return KeySequence.fromChord(.{ .key = .Char, .char = ch, .alt = true });
}

pub fn altKey(key: terminal.Key) KeySequence {
    return KeySequence.fromChord(.{ .key = key, .alt = true });
}

pub fn shiftKey(key: terminal.Key) KeySequence {
    return KeySequence.fromChord(.{ .key = key, .shift = true });
}

pub fn shiftAltKey(key: terminal.Key) KeySequence {
    return KeySequence.fromChord(.{ .key = key, .alt = true, .shift = true });
}

pub fn ctrlAltKey(key: terminal.Key) KeySequence {
    return KeySequence.fromChord(.{ .key = key, .ctrl = true, .alt = true });
}

fn isWhitespace(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r';
}

fn hasWhitespace(text: []const u8) bool {
    for (text) |ch| {
        if (isWhitespace(ch)) return true;
    }
    return false;
}

fn hasModifierSeparator(text: []const u8) bool {
    return std.mem.indexOfScalar(u8, text, '+') != null or std.mem.indexOfScalar(u8, text, '-') != null;
}

fn lowerEquals(text: []const u8, expected: []const u8) bool {
    return std.ascii.eqlIgnoreCase(text, expected);
}

fn specialKeyByName(name: []const u8) ?KeyChord {
    if (lowerEquals(name, "enter") or lowerEquals(name, "return")) return .{ .key = .Enter };
    if (lowerEquals(name, "esc") or lowerEquals(name, "escape")) return .{ .key = .Esc };
    if (lowerEquals(name, "tab")) return .{ .key = .Char, .char = '\t' };
    if (lowerEquals(name, "backspace")) return .{ .key = .Backspace };
    if (lowerEquals(name, "delete") or lowerEquals(name, "del")) return .{ .key = .Delete };
    if (lowerEquals(name, "up")) return .{ .key = .Up };
    if (lowerEquals(name, "down")) return .{ .key = .Down };
    if (lowerEquals(name, "left")) return .{ .key = .Left };
    if (lowerEquals(name, "right")) return .{ .key = .Right };
    if (lowerEquals(name, "pageup") or lowerEquals(name, "pgup")) return .{ .key = .PageUp };
    if (lowerEquals(name, "pagedown") or lowerEquals(name, "pgdn")) return .{ .key = .PageDown };
    if (lowerEquals(name, "home")) return .{ .key = .Home };
    if (lowerEquals(name, "end")) return .{ .key = .End };
    if (lowerEquals(name, "space")) return .{ .key = .Char, .char = ' ' };
    return null;
}

fn parseModifierName(name: []const u8, chord: *KeyChord) KeyParseError!void {
    if (lowerEquals(name, "ctrl") or lowerEquals(name, "control") or lowerEquals(name, "c")) {
        chord.ctrl = true;
    } else if (lowerEquals(name, "alt") or lowerEquals(name, "option") or lowerEquals(name, "meta") or lowerEquals(name, "m")) {
        chord.alt = true;
    } else if (lowerEquals(name, "shift") or lowerEquals(name, "s")) {
        chord.shift = true;
    } else {
        return error.InvalidModifier;
    }
}

fn parseSingleChordToken(token: []const u8) KeyParseError!KeyChord {
    if (token.len == 0) return error.EmptyKey;

    if (!hasModifierSeparator(token)) {
        if (specialKeyByName(token)) |special| return special;
        if (token.len == 1) return .{ .key = .Char, .char = token[0] };
        return error.UnknownKey;
    }

    var chord = KeyChord{};
    var final_part: ?[]const u8 = null;

    var start: usize = 0;
    while (start <= token.len) {
        var end = start;
        while (end < token.len and token[end] != '+' and token[end] != '-') : (end += 1) {}
        const part = token[start..end];
        if (part.len == 0) return error.InvalidChord;

        if (end == token.len) {
            final_part = part;
            break;
        }

        try parseModifierName(part, &chord);
        start = end + 1;
    }

    const key_part = final_part orelse return error.InvalidChord;
    var key_chord = specialKeyByName(key_part) orelse blk: {
        if (key_part.len != 1) return error.UnknownKey;
        var ch = key_part[0];
        if (chord.ctrl and std.ascii.isAlphabetic(ch)) ch = std.ascii.toLower(ch);
        break :blk KeyChord{ .key = .Char, .char = ch };
    };

    key_chord.ctrl = chord.ctrl;
    key_chord.alt = chord.alt;
    key_chord.shift = chord.shift;
    return key_chord;
}

pub fn parseKeySequence(text: []const u8) KeyParseError!KeySequence {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return error.EmptyKey;

    var sequence = KeySequence{};
    if (hasWhitespace(trimmed)) {
        var it = std.mem.tokenizeAny(u8, trimmed, " \t\r\n");
        while (it.next()) |token| {
            if (!sequence.appendChord(try parseSingleChordToken(token))) return error.SequenceTooLong;
        }
        return sequence;
    }

    if (hasModifierSeparator(trimmed)) {
        sequence.chords[0] = try parseSingleChordToken(trimmed);
        sequence.len = 1;
        return sequence;
    }

    if (specialKeyByName(trimmed)) |special| {
        sequence.chords[0] = special;
        sequence.len = 1;
        return sequence;
    }

    if (trimmed.len > KeySequence.max_len) return error.SequenceTooLong;
    for (trimmed) |ch| {
        _ = sequence.appendChord(.{ .key = .Char, .char = ch });
    }
    return sequence;
}

fn appendFormatText(buf: []u8, index: *usize, text: []const u8) void {
    if (index.* >= buf.len) return;
    const len = @min(text.len, buf.len - index.*);
    @memcpy(buf[index.* .. index.* + len], text[0..len]);
    index.* += len;
}

fn keyName(chord: KeyChord) []const u8 {
    return switch (chord.key) {
        .None => "none",
        .Backspace => "backspace",
        .Enter => "enter",
        .Esc => "esc",
        .Up => "up",
        .Down => "down",
        .Right => "right",
        .Left => "left",
        .Delete => "delete",
        .Home => "home",
        .End => "end",
        .PageUp => "pageup",
        .PageDown => "pagedown",
        .Char => switch (chord.char) {
            '\t' => "tab",
            ' ' => "space",
            else => "",
        },
    };
}

pub fn formatKeySequence(sequence: KeySequence, buf: []u8) []const u8 {
    var index: usize = 0;
    for (0..sequence.len) |i| {
        const chord = sequence.chords[i];
        if (i > 0) {
            const previous = sequence.chords[i - 1];
            const join_plain_chars = previous.key == .Char and previous.char != '\t' and previous.char != ' ' and !previous.ctrl and !previous.alt and !previous.shift and
                chord.key == .Char and chord.char != '\t' and chord.char != ' ' and !chord.ctrl and !chord.alt and !chord.shift;
            if (!join_plain_chars) appendFormatText(buf, &index, " ");
        }
        if (chord.ctrl) appendFormatText(buf, &index, "ctrl+");
        if (chord.alt) appendFormatText(buf, &index, "alt+");
        if (chord.shift) appendFormatText(buf, &index, "shift+");
        const name = keyName(chord);
        if (name.len > 0) {
            appendFormatText(buf, &index, name);
        } else if (chord.key == .Char) {
            if (index < buf.len) {
                buf[index] = chord.char;
                index += 1;
            }
        }
    }
    return buf[0..index];
}

const default_bindings = [_]Binding{
    // Global controls handled before most mode-specific dispatch.
    .{ .context = .global, .sequence = ctrlChar('q'), .command = .app_quit_flamingo },
    .{ .context = .global, .sequence = ctrlChar('b'), .command = .explorer_toggle },
    .{ .context = .global, .sequence = ctrlChar('t'), .command = .terminal_toggle },
    .{ .context = .global, .sequence = ctrlChar('e'), .command = .app_cycle_panel_focus },
    .{ .context = .global, .sequence = ctrlChar('w'), .command = .app_close_tab },
    .{ .context = .global, .sequence = altChar(']'), .command = .app_next_tab },
    .{ .context = .global, .sequence = altChar('['), .command = .app_previous_tab },

    // Normal mode.
    .{ .context = .normal, .sequence = keyChar('i'), .command = .mode_insert },
    .{ .context = .normal, .sequence = keyChar(':'), .command = .mode_command },
    .{ .context = .normal, .sequence = keyChar('/'), .command = .mode_search },
    .{ .context = .normal, .sequence = keySpecial(.Esc), .command = .mode_normal },
    .{ .context = .normal, .sequence = altChar('o'), .command = .navigation_jump_back },
    .{ .context = .normal, .sequence = altChar('p'), .command = .navigation_jump_forward },
    .{ .context = .normal, .sequence = charSeq("gg"), .command = .navigation_goto_file_start },
    .{ .context = .normal, .sequence = keyChar('G'), .command = .navigation_goto_file_end },
    .{ .context = .normal, .sequence = keyChar('%'), .command = .navigation_matching_bracket },
    .{ .context = .normal, .sequence = keyChar('f'), .command = .navigation_goto_definition },
    .{ .context = .normal, .sequence = charSeq("zh"), .command = .navigation_scroll_left },
    .{ .context = .normal, .sequence = charSeq("zl"), .command = .navigation_scroll_right },
    .{ .context = .normal, .sequence = charSeq("zH"), .command = .navigation_scroll_left_half_page },
    .{ .context = .normal, .sequence = charSeq("zL"), .command = .navigation_scroll_right_half_page },
    .{ .context = .normal, .sequence = charSeq("zs"), .command = .navigation_scroll_cursor_start },
    .{ .context = .normal, .sequence = charSeq("ze"), .command = .navigation_scroll_cursor_end },
    .{ .context = .normal, .sequence = charSeq("zc"), .command = .fold_close },
    .{ .context = .normal, .sequence = charSeq("zo"), .command = .fold_open },
    .{ .context = .normal, .sequence = charSeq("za"), .command = .fold_toggle },
    .{ .context = .normal, .sequence = charSeq("zM"), .command = .fold_close_all },
    .{ .context = .normal, .sequence = charSeq("zR"), .command = .fold_open_all },
    .{ .context = .normal, .sequence = charSeq("zA"), .command = .fold_toggle_all },
    .{ .context = .normal, .sequence = charSeq("]c"), .command = .navigation_next_comment },
    .{ .context = .normal, .sequence = charSeq("[c"), .command = .navigation_previous_comment },
    .{ .context = .normal, .sequence = keySpecial(.Up), .command = .navigation_move_up },
    .{ .context = .normal, .sequence = keySpecial(.Down), .command = .navigation_move_down },
    .{ .context = .normal, .sequence = keySpecial(.Left), .command = .navigation_move_left },
    .{ .context = .normal, .sequence = keySpecial(.Right), .command = .navigation_move_right },
    .{ .context = .normal, .sequence = keySpecial(.PageUp), .command = .navigation_page_up },
    .{ .context = .normal, .sequence = keySpecial(.PageDown), .command = .navigation_page_down },
    .{ .context = .normal, .sequence = altKey(.Down), .command = .navigation_line_start },
    .{ .context = .normal, .sequence = altKey(.Up), .command = .navigation_line_end },
    .{ .context = .normal, .sequence = altKey(.Left), .command = .navigation_word_left },
    .{ .context = .normal, .sequence = altKey(.Right), .command = .navigation_word_right },
    .{ .context = .normal, .sequence = shiftKey(.Up), .command = .navigation_move_up },
    .{ .context = .normal, .sequence = shiftKey(.Down), .command = .navigation_move_down },
    .{ .context = .normal, .sequence = shiftKey(.Left), .command = .navigation_move_left },
    .{ .context = .normal, .sequence = shiftKey(.Right), .command = .navigation_move_right },
    .{ .context = .normal, .sequence = shiftKey(.PageUp), .command = .navigation_page_up },
    .{ .context = .normal, .sequence = shiftKey(.PageDown), .command = .navigation_page_down },
    .{ .context = .normal, .sequence = shiftAltKey(.Down), .command = .navigation_line_start },
    .{ .context = .normal, .sequence = shiftAltKey(.Up), .command = .navigation_line_end },
    .{ .context = .normal, .sequence = shiftAltKey(.Left), .command = .navigation_word_left },
    .{ .context = .normal, .sequence = shiftAltKey(.Right), .command = .navigation_word_right },
    .{ .context = .normal, .sequence = ctrlChar('s'), .command = .file_write },
    .{ .context = .normal, .sequence = ctrlChar('z'), .command = .editing_undo },
    .{ .context = .normal, .sequence = ctrlChar('y'), .command = .editing_redo },
    .{ .context = .normal, .sequence = ctrlChar('a'), .command = .editing_select_all },
    .{ .context = .normal, .sequence = ctrlChar('c'), .command = .editing_copy },
    .{ .context = .normal, .sequence = ctrlChar('x'), .command = .editing_cut },
    .{ .context = .normal, .sequence = ctrlChar('v'), .command = .editing_paste },
    .{ .context = .normal, .sequence = altKey(.Delete), .command = .editing_delete_word_back },
    .{ .context = .normal, .sequence = altKey(.Backspace), .command = .editing_delete_word_back },
    .{ .context = .normal, .sequence = ctrlChar('d'), .command = .editing_duplicate_line },
    .{ .context = .normal, .sequence = ctrlShiftChar('k'), .command = .editing_delete_line },
    .{ .context = .normal, .sequence = ctrlChar('k'), .command = .editing_delete_line },
    .{ .context = .normal, .sequence = ctrlAltKey(.Up), .command = .editing_add_cursor_above },
    .{ .context = .normal, .sequence = ctrlAltKey(.Down), .command = .editing_add_cursor_below },
    .{ .context = .normal, .sequence = altChar('d'), .command = .editing_select_next_occurrence },
    .{ .context = .normal, .sequence = keyChar('.'), .command = .completion_auto_trigger },
    .{ .context = .normal, .sequence = ctrlChar(' '), .command = .completion_trigger },

    // Insert mode.
    .{ .context = .insert, .sequence = keySpecial(.Esc), .command = .mode_normal },
    .{ .context = .insert, .sequence = keySpecial(.Enter), .command = .editing_insert_newline },
    .{ .context = .insert, .sequence = keySpecial(.Backspace), .command = .editing_delete_back },
    .{ .context = .insert, .sequence = keyChar('\t'), .command = .editing_indent },
    .{ .context = .insert, .sequence = keySpecial(.Up), .command = .navigation_move_up },
    .{ .context = .insert, .sequence = keySpecial(.Down), .command = .navigation_move_down },
    .{ .context = .insert, .sequence = keySpecial(.Left), .command = .navigation_move_left },
    .{ .context = .insert, .sequence = keySpecial(.Right), .command = .navigation_move_right },
    .{ .context = .insert, .sequence = keySpecial(.PageUp), .command = .navigation_page_up },
    .{ .context = .insert, .sequence = keySpecial(.PageDown), .command = .navigation_page_down },
    .{ .context = .insert, .sequence = altKey(.Down), .command = .navigation_line_start },
    .{ .context = .insert, .sequence = altKey(.Up), .command = .navigation_line_end },
    .{ .context = .insert, .sequence = altKey(.Left), .command = .navigation_word_left },
    .{ .context = .insert, .sequence = altKey(.Right), .command = .navigation_word_right },
    .{ .context = .insert, .sequence = shiftKey(.Up), .command = .navigation_move_up },
    .{ .context = .insert, .sequence = shiftKey(.Down), .command = .navigation_move_down },
    .{ .context = .insert, .sequence = shiftKey(.Left), .command = .navigation_move_left },
    .{ .context = .insert, .sequence = shiftKey(.Right), .command = .navigation_move_right },
    .{ .context = .insert, .sequence = shiftKey(.PageUp), .command = .navigation_page_up },
    .{ .context = .insert, .sequence = shiftKey(.PageDown), .command = .navigation_page_down },
    .{ .context = .insert, .sequence = shiftAltKey(.Down), .command = .navigation_line_start },
    .{ .context = .insert, .sequence = shiftAltKey(.Up), .command = .navigation_line_end },
    .{ .context = .insert, .sequence = shiftAltKey(.Left), .command = .navigation_word_left },
    .{ .context = .insert, .sequence = shiftAltKey(.Right), .command = .navigation_word_right },
    .{ .context = .insert, .sequence = ctrlChar('s'), .command = .file_write },
    .{ .context = .insert, .sequence = ctrlChar('z'), .command = .editing_undo },
    .{ .context = .insert, .sequence = ctrlChar('y'), .command = .editing_redo },
    .{ .context = .insert, .sequence = ctrlChar('a'), .command = .editing_select_all },
    .{ .context = .insert, .sequence = ctrlChar('c'), .command = .editing_copy },
    .{ .context = .insert, .sequence = ctrlChar('x'), .command = .editing_cut },
    .{ .context = .insert, .sequence = ctrlChar('v'), .command = .editing_paste },
    .{ .context = .insert, .sequence = altKey(.Delete), .command = .editing_delete_word_back },
    .{ .context = .insert, .sequence = altKey(.Backspace), .command = .editing_delete_word_back },
    .{ .context = .insert, .sequence = ctrlChar('d'), .command = .editing_duplicate_line },
    .{ .context = .insert, .sequence = ctrlShiftChar('k'), .command = .editing_delete_line },
    .{ .context = .insert, .sequence = ctrlChar('k'), .command = .editing_delete_line },
    .{ .context = .insert, .sequence = ctrlAltKey(.Up), .command = .editing_add_cursor_above },
    .{ .context = .insert, .sequence = ctrlAltKey(.Down), .command = .editing_add_cursor_below },
    .{ .context = .insert, .sequence = keyChar('.'), .command = .completion_auto_trigger },
    .{ .context = .insert, .sequence = ctrlChar(' '), .command = .completion_trigger },

    // Command prompt.
    .{ .context = .command_line, .sequence = keySpecial(.Esc), .command = .command_cancel },
    .{ .context = .command_line, .sequence = keySpecial(.Backspace), .command = .command_backspace },
    .{ .context = .command_line, .sequence = keyChar('\t'), .command = .command_suggestion_next },
    .{ .context = .command_line, .sequence = keySpecial(.Down), .command = .command_suggestion_next },
    .{ .context = .command_line, .sequence = keySpecial(.Up), .command = .command_suggestion_previous },
    .{ .context = .command_line, .sequence = keySpecial(.Enter), .command = .command_execute },

    // Dashboard.
    .{ .context = .dashboard, .sequence = ctrlChar('n'), .command = .dashboard_new_file },
    .{ .context = .dashboard, .sequence = ctrlChar('o'), .command = .dashboard_open_file },
    .{ .context = .dashboard, .sequence = ctrlChar('f'), .command = .dashboard_open_folder },
    .{ .context = .dashboard, .sequence = ctrlChar('w'), .command = .dashboard_create_workspace },
    .{ .context = .dashboard, .sequence = ctrlChar('p'), .command = .dashboard_settings },
    .{ .context = .dashboard, .sequence = ctrlChar('q'), .command = .app_quit_flamingo },
    .{ .context = .dashboard, .sequence = keyChar(':'), .command = .mode_command },
    .{ .context = .dashboard, .sequence = keySpecial(.Up), .command = .dashboard_move_up },
    .{ .context = .dashboard, .sequence = keySpecial(.Down), .command = .dashboard_move_down },
    .{ .context = .dashboard, .sequence = keySpecial(.Enter), .command = .dashboard_select },

    // Explorer.
    .{ .context = .explorer, .sequence = keySpecial(.Up), .command = .explorer_move_up },
    .{ .context = .explorer, .sequence = keySpecial(.Down), .command = .explorer_move_down },
    .{ .context = .explorer, .sequence = keySpecial(.Enter), .command = .explorer_open_selected },
    .{ .context = .explorer, .sequence = keyChar('/'), .command = .explorer_search_open },
    .{ .context = .explorer, .sequence = altChar('n'), .command = .explorer_new_file },
    .{ .context = .explorer, .sequence = altChar('r'), .command = .explorer_rename },
    .{ .context = .explorer, .sequence = altKey(.Delete), .command = .explorer_delete },
    .{ .context = .explorer, .sequence = altKey(.Backspace), .command = .explorer_delete },
    .{ .context = .explorer_search, .sequence = keySpecial(.Esc), .command = .explorer_search_cancel },
    .{ .context = .explorer_search, .sequence = keySpecial(.Backspace), .command = .explorer_search_backspace },
    .{ .context = .explorer_search, .sequence = keySpecial(.Up), .command = .explorer_move_up },
    .{ .context = .explorer_search, .sequence = keySpecial(.Down), .command = .explorer_move_down },
    .{ .context = .explorer_search, .sequence = keySpecial(.Enter), .command = .explorer_open_selected },

    // Buffer search and project search.
    .{ .context = .search, .sequence = keySpecial(.Esc), .command = .search_cancel },
    .{ .context = .search, .sequence = keySpecial(.Backspace), .command = .search_backspace },
    .{ .context = .search, .sequence = keySpecial(.Enter), .command = .search_accept },
    .{ .context = .search, .sequence = keySpecial(.Down), .command = .search_next_match },
    .{ .context = .search, .sequence = keySpecial(.Up), .command = .search_previous_match },
    .{ .context = .global_search, .sequence = keySpecial(.Esc), .command = .global_search_cancel },
    .{ .context = .global_search, .sequence = keySpecial(.Backspace), .command = .global_search_backspace },
    .{ .context = .global_search, .sequence = keyChar('\t'), .command = .global_search_select_next },
    .{ .context = .global_search, .sequence = keySpecial(.Down), .command = .global_search_select_next },
    .{ .context = .global_search, .sequence = keySpecial(.Up), .command = .global_search_select_previous },
    .{ .context = .global_search, .sequence = keySpecial(.Enter), .command = .global_search_accept },

    // TODO panel.
    .{ .context = .todo_panel, .sequence = keySpecial(.Esc), .command = .todo_panel_close },
    .{ .context = .todo_panel, .sequence = keyChar('q'), .command = .todo_panel_close },
    .{ .context = .todo_panel, .sequence = keySpecial(.Up), .command = .todo_panel_move_up },
    .{ .context = .todo_panel, .sequence = keySpecial(.Down), .command = .todo_panel_move_down },
    .{ .context = .todo_panel, .sequence = keyChar('r'), .command = .todo_panel_refresh },
    .{ .context = .todo_panel, .sequence = keyChar('n'), .command = .todo_panel_new },
    .{ .context = .todo_panel, .sequence = keyChar('e'), .command = .todo_panel_edit },
    .{ .context = .todo_panel, .sequence = keyChar('d'), .command = .todo_panel_delete },
    .{ .context = .todo_panel, .sequence = keyChar('x'), .command = .todo_panel_toggle },
    .{ .context = .todo_panel, .sequence = keyChar('o'), .command = .todo_panel_open_selected },
    .{ .context = .todo_panel, .sequence = keySpecial(.Enter), .command = .todo_panel_open_selected },

    // Comments panel.
    .{ .context = .comments_panel, .sequence = keySpecial(.Esc), .command = .comments_panel_close },
    .{ .context = .comments_panel, .sequence = keyChar('q'), .command = .comments_panel_close },
    .{ .context = .comments_panel, .sequence = keySpecial(.Up), .command = .comments_panel_move_up },
    .{ .context = .comments_panel, .sequence = keySpecial(.Down), .command = .comments_panel_move_down },
    .{ .context = .comments_panel, .sequence = keyChar('R'), .command = .comments_panel_refresh },
    .{ .context = .comments_panel, .sequence = keyChar('r'), .command = .comments_panel_reply },
    .{ .context = .comments_panel, .sequence = keyChar('e'), .command = .comments_panel_edit },
    .{ .context = .comments_panel, .sequence = keyChar('d'), .command = .comments_panel_delete },
    .{ .context = .comments_panel, .sequence = keyChar('n'), .command = .comments_panel_new },
    .{ .context = .comments_panel, .sequence = keySpecial(.Enter), .command = .comments_panel_open_selected },

    // Git Diff.
    .{ .context = .git_diff, .sequence = keySpecial(.Esc), .command = .git_diff_close },
    .{ .context = .git_diff, .sequence = keyChar('q'), .command = .git_diff_close },
    .{ .context = .git_diff, .sequence = keySpecial(.Up), .command = .git_diff_move_up },
    .{ .context = .git_diff, .sequence = keyChar('k'), .command = .git_diff_move_up },
    .{ .context = .git_diff, .sequence = keySpecial(.Down), .command = .git_diff_move_down },
    .{ .context = .git_diff, .sequence = keyChar('j'), .command = .git_diff_move_down },
    .{ .context = .git_diff, .sequence = keySpecial(.PageUp), .command = .git_diff_page_up },
    .{ .context = .git_diff, .sequence = ctrlChar('u'), .command = .git_diff_page_up },
    .{ .context = .git_diff, .sequence = keySpecial(.PageDown), .command = .git_diff_page_down },
    .{ .context = .git_diff, .sequence = ctrlChar('d'), .command = .git_diff_page_down },
    .{ .context = .git_diff, .sequence = keyChar('r'), .command = .git_diff_refresh_panel },
    .{ .context = .git_diff, .sequence = keySpecial(.Enter), .command = .git_diff_open_selected },

    // Git Graph.
    .{ .context = .git_graph, .sequence = keySpecial(.Esc), .command = .git_graph_close },
    .{ .context = .git_graph, .sequence = keyChar('q'), .command = .git_graph_close },
    .{ .context = .git_graph, .sequence = keySpecial(.Up), .command = .git_graph_move_up },
    .{ .context = .git_graph, .sequence = keyChar('k'), .command = .git_graph_move_up },
    .{ .context = .git_graph, .sequence = keySpecial(.Down), .command = .git_graph_move_down },
    .{ .context = .git_graph, .sequence = keyChar('j'), .command = .git_graph_move_down },
    .{ .context = .git_graph, .sequence = keySpecial(.PageUp), .command = .git_graph_page_up },
    .{ .context = .git_graph, .sequence = keySpecial(.PageDown), .command = .git_graph_page_down },
    .{ .context = .git_graph, .sequence = charSeq("gg"), .command = .git_graph_first },
    .{ .context = .git_graph, .sequence = keyChar('G'), .command = .git_graph_last },
    .{ .context = .git_graph, .sequence = keyChar('r'), .command = .git_graph_refresh },
    .{ .context = .git_graph, .sequence = keySpecial(.Enter), .command = .git_graph_toggle_details },

    // Help.
    .{ .context = .help, .sequence = keySpecial(.Esc), .command = .help_close },
    .{ .context = .help, .sequence = keyChar('q'), .command = .help_close },
    .{ .context = .help, .sequence = keySpecial(.Up), .command = .help_scroll_up },
    .{ .context = .help, .sequence = keySpecial(.Down), .command = .help_scroll_down },
    .{ .context = .help, .sequence = keySpecial(.PageUp), .command = .help_page_up },
    .{ .context = .help, .sequence = keySpecial(.PageDown), .command = .help_page_down },

    // Terminal panel controls. PTY pass-through is intentionally not modeled.
    .{ .context = .terminal, .sequence = keySpecial(.Esc), .command = .terminal_unfocus },
    .{ .context = .terminal, .sequence = keySpecial(.PageUp), .command = .terminal_scroll_page_up },
    .{ .context = .terminal, .sequence = keySpecial(.PageDown), .command = .terminal_scroll_page_down },
    .{ .context = .terminal, .sequence = shiftKey(.End), .command = .terminal_scroll_bottom },

    // Filesystem picker and prompts.
    .{ .context = .picker, .sequence = keySpecial(.Esc), .command = .picker_cancel },
    .{ .context = .picker, .sequence = keySpecial(.Backspace), .command = .picker_back },
    .{ .context = .picker, .sequence = keySpecial(.Up), .command = .picker_move_up },
    .{ .context = .picker, .sequence = keySpecial(.Down), .command = .picker_move_down },
    .{ .context = .picker, .sequence = keySpecial(.Enter), .command = .picker_accept },
    .{ .context = .picker_new_file, .sequence = keyChar(' '), .command = .picker_begin_name_input },
    .{ .context = .picker_open_folder, .sequence = keyChar(' '), .command = .picker_select_folder },
    .{ .context = .picker_open_folder, .sequence = keyChar('.'), .command = .picker_select_current_folder },
    .{ .context = .prompt, .sequence = keySpecial(.Esc), .command = .prompt_cancel },
    .{ .context = .prompt, .sequence = keyChar('n'), .command = .prompt_cancel },
    .{ .context = .prompt, .sequence = keyChar('N'), .command = .prompt_cancel },
    .{ .context = .prompt, .sequence = keyChar('y'), .command = .prompt_confirm },
    .{ .context = .prompt, .sequence = keyChar('Y'), .command = .prompt_confirm },
    .{ .context = .prompt, .sequence = keySpecial(.Enter), .command = .prompt_submit },
    .{ .context = .prompt, .sequence = keySpecial(.Backspace), .command = .prompt_backspace },
    .{ .context = .open_file_prompt, .sequence = keySpecial(.Esc), .command = .open_file_prompt_cancel },
    .{ .context = .open_file_prompt, .sequence = keySpecial(.Backspace), .command = .open_file_prompt_backspace },
    .{ .context = .open_file_prompt, .sequence = keySpecial(.Enter), .command = .open_file_prompt_submit },

    // LSP completion popup.
    .{ .context = .completion, .sequence = keySpecial(.Down), .command = .completion_next },
    .{ .context = .completion, .sequence = keySpecial(.Up), .command = .completion_previous },
    .{ .context = .completion, .sequence = keySpecial(.Enter), .command = .completion_accept },
    .{ .context = .completion, .sequence = keySpecial(.Esc), .command = .completion_cancel },

    // Save confirmation.
    .{ .context = .save_confirmation, .sequence = keyChar('s'), .command = .save_confirmation_save },
    .{ .context = .save_confirmation, .sequence = keyChar('S'), .command = .save_confirmation_save },
    .{ .context = .save_confirmation, .sequence = keyChar('d'), .command = .save_confirmation_discard },
    .{ .context = .save_confirmation, .sequence = keyChar('D'), .command = .save_confirmation_discard },
    .{ .context = .save_confirmation, .sequence = keySpecial(.Enter), .command = .save_confirmation_discard },
    .{ .context = .save_confirmation, .sequence = keySpecial(.Esc), .command = .save_confirmation_cancel },
    .{ .context = .save_confirmation, .sequence = keyChar('n'), .command = .save_confirmation_cancel },
    .{ .context = .save_confirmation, .sequence = keyChar('N'), .command = .save_confirmation_cancel },
};

test "KeyChord equality compares semantic key fields" {
    const a = KeyChord{ .key = .Char, .char = 'a', .ctrl = true };
    const b = KeyChord{ .key = .Char, .char = 'a', .ctrl = true };
    const c = KeyChord{ .key = .Char, .char = 'a', .ctrl = false };

    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(c));
}

test "KeySequence equality and prefix checks" {
    const gg = charSeq("gg");
    const same = KeySequence.fromChords(&.{ .{ .key = .Char, .char = 'g' }, .{ .key = .Char, .char = 'g' } });
    const z = keyChar('z');

    try std.testing.expect(gg.eql(same));
    try std.testing.expect(!gg.eql(z));
    try std.testing.expect(gg.startsWith(keyChar('g')));
    try std.testing.expect(!z.startsWith(gg));
}

test "KeySequence append builds pending sequences from key events" {
    var sequence = KeySequence{};
    try std.testing.expect(sequence.append(.{ .key = .Char, .char = 'g' }));
    try std.testing.expect(sequence.append(.{ .key = .Char, .char = 'g' }));
    try std.testing.expect(sequence.eql(charSeq("gg")));

    sequence.clear();
    for (0..KeySequence.max_len) |_| {
        try std.testing.expect(sequence.append(.{ .key = .Char, .char = 'x' }));
    }
    try std.testing.expect(!sequence.append(.{ .key = .Char, .char = 'x' }));
}

test "parseKeySequence supports plain modifier and special key forms" {
    const cases = [_]struct {
        text: []const u8,
        expected: KeySequence,
    }{
        .{ .text = "gg", .expected = charSeq("gg") },
        .{ .text = "G", .expected = keyChar('G') },
        .{ .text = "zM", .expected = charSeq("zM") },
        .{ .text = "ctrl+s", .expected = ctrlChar('s') },
        .{ .text = "Ctrl-S", .expected = ctrlChar('s') },
        .{ .text = "C-s", .expected = ctrlChar('s') },
        .{ .text = "ctrl+shift+k", .expected = ctrlShiftChar('k') },
        .{ .text = "C-S-k", .expected = ctrlShiftChar('k') },
        .{ .text = "alt+delete", .expected = altKey(.Delete) },
        .{ .text = "option+backspace", .expected = altKey(.Backspace) },
        .{ .text = "ctrl+alt+up", .expected = ctrlAltKey(.Up) },
        .{ .text = "shift+tab", .expected = KeySequence.fromChord(.{ .key = .Char, .char = '\t', .shift = true }) },
        .{ .text = "enter", .expected = keySpecial(.Enter) },
        .{ .text = "return", .expected = keySpecial(.Enter) },
        .{ .text = "esc", .expected = keySpecial(.Esc) },
        .{ .text = "escape", .expected = keySpecial(.Esc) },
        .{ .text = "space", .expected = keyChar(' ') },
    };

    for (cases) |case| {
        try std.testing.expect((try parseKeySequence(case.text)).eql(case.expected));
    }

    try std.testing.expect((try parseKeySequence("ctrl+x ctrl+s")).eql(KeySequence.fromChords(&.{ .{ .key = .Char, .char = 'x', .ctrl = true }, .{ .key = .Char, .char = 's', .ctrl = true } })));
    try std.testing.expectError(error.UnknownKey, parseKeySequence("ctrl+hyperdrive"));
    try std.testing.expectError(error.InvalidModifier, parseKeySequence("super+x"));
}

test "formatKeySequence emits config-style labels" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("gg", formatKeySequence(charSeq("gg"), &buf));
    try std.testing.expectEqualStrings("G", formatKeySequence(keyChar('G'), &buf));
    try std.testing.expectEqualStrings("ctrl+s", formatKeySequence(ctrlChar('s'), &buf));
    try std.testing.expectEqualStrings("ctrl+shift+k", formatKeySequence(ctrlShiftChar('k'), &buf));
    try std.testing.expectEqualStrings("alt+delete", formatKeySequence(altKey(.Delete), &buf));
    try std.testing.expectEqualStrings("ctrl+alt+up", formatKeySequence(ctrlAltKey(.Up), &buf));
    try std.testing.expectEqualStrings("shift+tab", formatKeySequence(KeySequence.fromChord(.{ .key = .Char, .char = '\t', .shift = true }), &buf));
    try std.testing.expectEqualStrings("enter", formatKeySequence(keySpecial(.Enter), &buf));
    try std.testing.expectEqualStrings("space", formatKeySequence(keyChar(' '), &buf));
}

test "parse and format representative key sequences are stable" {
    const cases = [_]struct {
        input: []const u8,
        formatted: []const u8,
    }{
        .{ .input = "gg", .formatted = "gg" },
        .{ .input = "G", .formatted = "G" },
        .{ .input = "zM", .formatted = "zM" },
        .{ .input = "ctrl+s", .formatted = "ctrl+s" },
        .{ .input = "ctrl+shift+k", .formatted = "ctrl+shift+k" },
        .{ .input = "alt+delete", .formatted = "alt+delete" },
        .{ .input = "option+backspace", .formatted = "alt+backspace" },
        .{ .input = "ctrl+alt+up", .formatted = "ctrl+alt+up" },
        .{ .input = "shift+tab", .formatted = "shift+tab" },
        .{ .input = "enter", .formatted = "enter" },
        .{ .input = "esc", .formatted = "esc" },
        .{ .input = "space", .formatted = "space" },
        .{ .input = "ctrl+x ctrl+s", .formatted = "ctrl+x ctrl+s" },
    };

    var buf: [64]u8 = undefined;
    for (cases) |case| {
        try std.testing.expectEqualStrings(case.formatted, formatKeySequence(try parseKeySequence(case.input), &buf));
    }
}

test "default registry resolves exact prefix and no-match results" {
    const registry = defaultRegistry();

    try std.testing.expectEqual(commands.CommandId.navigation_goto_file_start, switch (registry.resolve(.normal, charSeq("gg"))) {
        .command => |command| command,
        else => return error.ExpectedCommand,
    });

    try std.testing.expect(registry.resolve(.normal, keyChar('g')) == .prefix);
    try std.testing.expect(registry.resolve(.normal, keyChar('x')) == .none);
}

test "resolved registry applies overrides and unbinds" {
    var diagnostics = BuildDiagnostics{};
    defer diagnostics.deinit(std.testing.allocator);
    const overrides = [_]UserBindingOverride{
        .{
            .context = .normal,
            .sequence = keyChar('x'),
            .command = .mode_insert,
            .source_key = "x",
            .source_command = "mode.insert",
        },
        .{
            .context = .normal,
            .sequence = keyChar('i'),
            .command = .file_write,
            .source_key = "i",
            .source_command = "file.write",
        },
    };
    const unbinds = [_]UserUnbind{
        .{ .context = .normal, .sequence = ctrlChar('s'), .source_key = "ctrl+s" },
    };

    var registry = try Registry.fromDefaultsAndConfig(std.testing.allocator, &overrides, &unbinds, &diagnostics);
    defer registry.deinit(std.testing.allocator);

    try std.testing.expectEqual(commands.CommandId.mode_insert, switch (registry.resolve(.normal, keyChar('x'))) {
        .command => |command| command,
        else => return error.ExpectedCommand,
    });
    try std.testing.expectEqual(commands.CommandId.file_write, switch (registry.resolve(.normal, keyChar('i'))) {
        .command => |command| command,
        else => return error.ExpectedCommand,
    });
    try std.testing.expect(registry.resolve(.normal, ctrlChar('s')) == .none);
}

test "resolved registry reports duplicate overrides warnings and unbind rebind ordering" {
    {
        var diagnostics = BuildDiagnostics{};
        defer diagnostics.deinit(std.testing.allocator);
        const overrides = [_]UserBindingOverride{
            .{
                .context = .normal,
                .sequence = keyChar('x'),
                .command = .mode_insert,
                .source_key = "x",
                .source_command = "mode.insert",
            },
            .{
                .context = .normal,
                .sequence = keyChar('x'),
                .command = .mode_command,
                .source_key = "x",
                .source_command = "mode.command",
            },
        };
        try std.testing.expectError(
            error.InvalidKeybindingConfig,
            Registry.fromDefaultsAndConfig(std.testing.allocator, &overrides, &.{}, &diagnostics),
        );
        try std.testing.expect(diagnostics.hasErrors());
    }

    {
        var diagnostics = BuildDiagnostics{};
        defer diagnostics.deinit(std.testing.allocator);
        const unbinds = [_]UserUnbind{.{
            .context = .normal,
            .sequence = keyChar('x'),
            .source_key = "x",
        }};
        var registry = try Registry.fromDefaultsAndConfig(std.testing.allocator, &.{}, &unbinds, &diagnostics);
        defer registry.deinit(std.testing.allocator);

        try std.testing.expect(!diagnostics.hasErrors());
        try std.testing.expectEqual(@as(usize, 1), diagnostics.items.items.len);
        try std.testing.expectEqual(DiagnosticSeverity.warning, diagnostics.items.items[0].severity);
    }

    {
        var diagnostics = BuildDiagnostics{};
        defer diagnostics.deinit(std.testing.allocator);
        const unbinds = [_]UserUnbind{.{
            .context = .normal,
            .sequence = keyChar('i'),
            .source_key = "i",
        }};
        const overrides = [_]UserBindingOverride{.{
            .context = .normal,
            .sequence = keyChar('i'),
            .command = .file_write,
            .source_key = "i",
            .source_command = "file.write",
        }};
        var registry = try Registry.fromDefaultsAndConfig(std.testing.allocator, &overrides, &unbinds, &diagnostics);
        defer registry.deinit(std.testing.allocator);

        try std.testing.expect(!diagnostics.hasErrors());
        try std.testing.expectEqual(commands.CommandId.file_write, switch (registry.resolve(.normal, keyChar('i'))) {
            .command => |command| command,
            else => return error.ExpectedCommand,
        });
    }
}

test "resolved registry rejects invalid command contexts and prefix conflicts" {
    {
        var diagnostics = BuildDiagnostics{};
        defer diagnostics.deinit(std.testing.allocator);
        const overrides = [_]UserBindingOverride{.{
            .context = .search,
            .sequence = keyChar('x'),
            .command = .mode_insert,
            .source_key = "x",
            .source_command = "mode.insert",
        }};
        try std.testing.expectError(
            error.InvalidKeybindingConfig,
            Registry.fromDefaultsAndConfig(std.testing.allocator, &overrides, &.{}, &diagnostics),
        );
        try std.testing.expect(diagnostics.hasErrors());
    }
    {
        var diagnostics = BuildDiagnostics{};
        defer diagnostics.deinit(std.testing.allocator);
        const overrides = [_]UserBindingOverride{.{
            .context = .normal,
            .sequence = keyChar('g'),
            .command = .mode_insert,
            .source_key = "g",
            .source_command = "mode.insert",
        }};
        try std.testing.expectError(
            error.InvalidKeybindingConfig,
            Registry.fromDefaultsAndConfig(std.testing.allocator, &overrides, &.{}, &diagnostics),
        );
        try std.testing.expect(diagnostics.hasErrors());
    }
}

test "same key can resolve differently across contexts" {
    const registry = defaultRegistry();

    try std.testing.expectEqual(commands.CommandId.navigation_move_down, switch (registry.resolve(.normal, keySpecial(.Down))) {
        .command => |command| command,
        else => return error.ExpectedCommand,
    });
    try std.testing.expectEqual(commands.CommandId.dashboard_move_down, switch (registry.resolve(.dashboard, keySpecial(.Down))) {
        .command => |command| command,
        else => return error.ExpectedCommand,
    });
    try std.testing.expectEqual(commands.CommandId.command_suggestion_next, switch (registry.resolve(.command_line, keySpecial(.Down))) {
        .command => |command| command,
        else => return error.ExpectedCommand,
    });
}

test "dashboard context resolves action keys" {
    const registry = defaultRegistry();
    const cases = [_]struct {
        keys: KeySequence,
        command: commands.CommandId,
    }{
        .{ .keys = ctrlChar('n'), .command = .dashboard_new_file },
        .{ .keys = ctrlChar('o'), .command = .dashboard_open_file },
        .{ .keys = ctrlChar('f'), .command = .dashboard_open_folder },
        .{ .keys = ctrlChar('w'), .command = .dashboard_create_workspace },
        .{ .keys = ctrlChar('p'), .command = .dashboard_settings },
        .{ .keys = ctrlChar('q'), .command = .app_quit_flamingo },
        .{ .keys = keyChar(':'), .command = .mode_command },
        .{ .keys = keySpecial(.Up), .command = .dashboard_move_up },
        .{ .keys = keySpecial(.Down), .command = .dashboard_move_down },
        .{ .keys = keySpecial(.Enter), .command = .dashboard_select },
    };

    for (cases) |case| {
        try std.testing.expectEqual(case.command, switch (registry.resolve(.dashboard, case.keys)) {
            .command => |command| command,
            else => return error.ExpectedCommand,
        });
    }

    try std.testing.expect(registry.resolve(.dashboard, keyChar('a')) == .none);
    try std.testing.expect(registry.resolve(.dashboard, keySpecial(.Backspace)) == .none);
}

test "picker contexts resolve action keys and leave typed text raw" {
    const registry = defaultRegistry();
    const picker_cases = [_]struct {
        keys: KeySequence,
        command: commands.CommandId,
    }{
        .{ .keys = keySpecial(.Esc), .command = .picker_cancel },
        .{ .keys = keySpecial(.Backspace), .command = .picker_back },
        .{ .keys = keySpecial(.Up), .command = .picker_move_up },
        .{ .keys = keySpecial(.Down), .command = .picker_move_down },
        .{ .keys = keySpecial(.Enter), .command = .picker_accept },
    };

    for (picker_cases) |case| {
        try std.testing.expectEqual(case.command, switch (registry.resolve(.picker, case.keys)) {
            .command => |command| command,
            else => return error.ExpectedCommand,
        });
    }

    try std.testing.expectEqual(commands.CommandId.picker_begin_name_input, switch (registry.resolve(.picker_new_file, keyChar(' '))) {
        .command => |command| command,
        else => return error.ExpectedCommand,
    });
    try std.testing.expectEqual(commands.CommandId.picker_select_folder, switch (registry.resolve(.picker_open_folder, keyChar(' '))) {
        .command => |command| command,
        else => return error.ExpectedCommand,
    });
    try std.testing.expectEqual(commands.CommandId.picker_select_current_folder, switch (registry.resolve(.picker_open_folder, keyChar('.'))) {
        .command => |command| command,
        else => return error.ExpectedCommand,
    });

    try std.testing.expect(registry.resolve(.picker, keyChar('a')) == .none);
    try std.testing.expect(registry.resolve(.picker_new_file, keyChar('a')) == .none);
    try std.testing.expect(registry.resolve(.picker_open_folder, keyChar('a')) == .none);
    try std.testing.expect(registry.resolve(.picker, keyChar(' ')) == .none);
    try std.testing.expect(registry.resolve(.picker_new_file, keySpecial(.Enter)) == .none);
}

test "open-file prompt context resolves action keys and leaves path text raw" {
    const registry = defaultRegistry();
    const cases = [_]struct {
        keys: KeySequence,
        command: commands.CommandId,
    }{
        .{ .keys = keySpecial(.Esc), .command = .open_file_prompt_cancel },
        .{ .keys = keySpecial(.Backspace), .command = .open_file_prompt_backspace },
        .{ .keys = keySpecial(.Enter), .command = .open_file_prompt_submit },
    };

    for (cases) |case| {
        try std.testing.expectEqual(case.command, switch (registry.resolve(.open_file_prompt, case.keys)) {
            .command => |command| command,
            else => return error.ExpectedCommand,
        });
    }

    try std.testing.expect(registry.resolve(.open_file_prompt, keyChar('a')) == .none);
    try std.testing.expect(registry.resolve(.open_file_prompt, keyChar('/')) == .none);
    try std.testing.expectEqual(commands.CommandId.picker_cancel, switch (registry.resolve(.picker, keySpecial(.Esc))) {
        .command => |command| command,
        else => return error.ExpectedCommand,
    });
}

test "insert context resolves command keys and leaves printable text raw" {
    const registry = defaultRegistry();
    const cases = [_]struct {
        keys: KeySequence,
        command: commands.CommandId,
    }{
        .{ .keys = keySpecial(.Esc), .command = .mode_normal },
        .{ .keys = keySpecial(.Enter), .command = .editing_insert_newline },
        .{ .keys = keySpecial(.Backspace), .command = .editing_delete_back },
        .{ .keys = keyChar('\t'), .command = .editing_indent },
        .{ .keys = ctrlChar('s'), .command = .file_write },
        .{ .keys = ctrlChar('z'), .command = .editing_undo },
        .{ .keys = keySpecial(.Down), .command = .navigation_move_down },
        .{ .keys = altKey(.Right), .command = .navigation_word_right },
        .{ .keys = ctrlChar(' '), .command = .completion_trigger },
    };

    for (cases) |case| {
        try std.testing.expectEqual(case.command, switch (registry.resolve(.insert, case.keys)) {
            .command => |command| command,
            else => return error.ExpectedCommand,
        });
    }

    try std.testing.expect(registry.resolve(.insert, keyChar('a')) == .none);
}

test "terminal help prompt completion and save-confirmation contexts resolve controls" {
    const registry = defaultRegistry();
    const cases = [_]struct {
        context: BindingContext,
        keys: KeySequence,
        command: commands.CommandId,
    }{
        .{ .context = .terminal, .keys = keySpecial(.Esc), .command = .terminal_unfocus },
        .{ .context = .terminal, .keys = keySpecial(.PageUp), .command = .terminal_scroll_page_up },
        .{ .context = .terminal, .keys = keySpecial(.PageDown), .command = .terminal_scroll_page_down },
        .{ .context = .terminal, .keys = shiftKey(.End), .command = .terminal_scroll_bottom },
        .{ .context = .help, .keys = keySpecial(.Esc), .command = .help_close },
        .{ .context = .help, .keys = keyChar('q'), .command = .help_close },
        .{ .context = .help, .keys = keySpecial(.Down), .command = .help_scroll_down },
        .{ .context = .help, .keys = keySpecial(.PageUp), .command = .help_page_up },
        .{ .context = .git_graph, .keys = keyChar('q'), .command = .git_graph_close },
        .{ .context = .git_graph, .keys = keySpecial(.Down), .command = .git_graph_move_down },
        .{ .context = .git_graph, .keys = charSeq("gg"), .command = .git_graph_first },
        .{ .context = .completion, .keys = keySpecial(.Down), .command = .completion_next },
        .{ .context = .completion, .keys = keySpecial(.Up), .command = .completion_previous },
        .{ .context = .completion, .keys = keySpecial(.Enter), .command = .completion_accept },
        .{ .context = .completion, .keys = keySpecial(.Esc), .command = .completion_cancel },
        .{ .context = .prompt, .keys = keySpecial(.Esc), .command = .prompt_cancel },
        .{ .context = .prompt, .keys = keyChar('y'), .command = .prompt_confirm },
        .{ .context = .prompt, .keys = keySpecial(.Backspace), .command = .prompt_backspace },
        .{ .context = .save_confirmation, .keys = keyChar('s'), .command = .save_confirmation_save },
        .{ .context = .save_confirmation, .keys = keyChar('D'), .command = .save_confirmation_discard },
        .{ .context = .save_confirmation, .keys = keySpecial(.Esc), .command = .save_confirmation_cancel },
    };

    for (cases) |case| {
        try std.testing.expectEqual(case.command, switch (registry.resolve(case.context, case.keys)) {
            .command => |command| command,
            else => return error.ExpectedCommand,
        });
    }

    try std.testing.expect(registry.resolve(.terminal, keyChar('a')) == .none);
    try std.testing.expect(registry.resolve(.prompt, keyChar('a')) == .none);
    try std.testing.expect(registry.resolve(.completion, keyChar('a')) == .none);
}

test "command-line context resolves action keys and leaves text raw" {
    const registry = defaultRegistry();
    const cases = [_]struct {
        keys: KeySequence,
        command: commands.CommandId,
    }{
        .{ .keys = keySpecial(.Enter), .command = .command_execute },
        .{ .keys = keySpecial(.Esc), .command = .command_cancel },
        .{ .keys = keySpecial(.Backspace), .command = .command_backspace },
        .{ .keys = keyChar('\t'), .command = .command_suggestion_next },
        .{ .keys = keySpecial(.Down), .command = .command_suggestion_next },
        .{ .keys = keySpecial(.Up), .command = .command_suggestion_previous },
    };

    for (cases) |case| {
        try std.testing.expectEqual(case.command, switch (registry.resolve(.command_line, case.keys)) {
            .command => |command| command,
            else => return error.ExpectedCommand,
        });
    }

    try std.testing.expect(registry.resolve(.command_line, keyChar('w')) == .none);
    try std.testing.expect(registry.resolve(.search, keyChar('\t')) == .none);
}

test "search context resolves action keys and leaves query text raw" {
    const registry = defaultRegistry();
    const cases = [_]struct {
        keys: KeySequence,
        command: commands.CommandId,
    }{
        .{ .keys = keySpecial(.Enter), .command = .search_accept },
        .{ .keys = keySpecial(.Esc), .command = .search_cancel },
        .{ .keys = keySpecial(.Backspace), .command = .search_backspace },
        .{ .keys = keySpecial(.Down), .command = .search_next_match },
        .{ .keys = keySpecial(.Up), .command = .search_previous_match },
    };

    for (cases) |case| {
        try std.testing.expectEqual(case.command, switch (registry.resolve(.search, case.keys)) {
            .command => |command| command,
            else => return error.ExpectedCommand,
        });
    }

    try std.testing.expect(registry.resolve(.search, keyChar('f')) == .none);
    try std.testing.expectEqual(commands.CommandId.command_execute, switch (registry.resolve(.command_line, keySpecial(.Enter))) {
        .command => |command| command,
        else => return error.ExpectedCommand,
    });
    try std.testing.expectEqual(commands.CommandId.search_accept, switch (registry.resolve(.search, keySpecial(.Enter))) {
        .command => |command| command,
        else => return error.ExpectedCommand,
    });
}

test "global search context resolves action keys and leaves query text raw" {
    const registry = defaultRegistry();
    const cases = [_]struct {
        keys: KeySequence,
        command: commands.CommandId,
    }{
        .{ .keys = keySpecial(.Enter), .command = .global_search_accept },
        .{ .keys = keySpecial(.Esc), .command = .global_search_cancel },
        .{ .keys = keySpecial(.Backspace), .command = .global_search_backspace },
        .{ .keys = keyChar('\t'), .command = .global_search_select_next },
        .{ .keys = keySpecial(.Down), .command = .global_search_select_next },
        .{ .keys = keySpecial(.Up), .command = .global_search_select_previous },
    };

    for (cases) |case| {
        try std.testing.expectEqual(case.command, switch (registry.resolve(.global_search, case.keys)) {
            .command => |command| command,
            else => return error.ExpectedCommand,
        });
    }

    try std.testing.expect(registry.resolve(.global_search, keyChar('f')) == .none);
    try std.testing.expect(registry.resolve(.search, keyChar('\t')) == .none);
    try std.testing.expectEqual(commands.CommandId.command_suggestion_next, switch (registry.resolve(.command_line, keyChar('\t'))) {
        .command => |command| command,
        else => return error.ExpectedCommand,
    });
    try std.testing.expectEqual(commands.CommandId.global_search_select_next, switch (registry.resolve(.global_search, keyChar('\t'))) {
        .command => |command| command,
        else => return error.ExpectedCommand,
    });
    try std.testing.expectEqual(commands.CommandId.search_next_match, switch (registry.resolve(.search, keySpecial(.Down))) {
        .command => |command| command,
        else => return error.ExpectedCommand,
    });
    try std.testing.expectEqual(commands.CommandId.global_search_select_next, switch (registry.resolve(.global_search, keySpecial(.Down))) {
        .command => |command| command,
        else => return error.ExpectedCommand,
    });
}

test "explorer context resolves action keys" {
    const registry = defaultRegistry();
    const cases = [_]struct {
        keys: KeySequence,
        command: commands.CommandId,
    }{
        .{ .keys = keySpecial(.Up), .command = .explorer_move_up },
        .{ .keys = keySpecial(.Down), .command = .explorer_move_down },
        .{ .keys = keySpecial(.Enter), .command = .explorer_open_selected },
        .{ .keys = keyChar('/'), .command = .explorer_search_open },
        .{ .keys = altChar('n'), .command = .explorer_new_file },
        .{ .keys = altChar('r'), .command = .explorer_rename },
        .{ .keys = altKey(.Delete), .command = .explorer_delete },
        .{ .keys = altKey(.Backspace), .command = .explorer_delete },
    };

    for (cases) |case| {
        try std.testing.expectEqual(case.command, switch (registry.resolve(.explorer, case.keys)) {
            .command => |command| command,
            else => return error.ExpectedCommand,
        });
    }

    try std.testing.expect(registry.resolve(.explorer, keySpecial(.Esc)) == .none);
    try std.testing.expect(registry.resolve(.explorer, keySpecial(.Backspace)) == .none);
}

test "explorer search context resolves action keys and leaves query text raw" {
    const registry = defaultRegistry();
    const cases = [_]struct {
        keys: KeySequence,
        command: commands.CommandId,
    }{
        .{ .keys = keySpecial(.Esc), .command = .explorer_search_cancel },
        .{ .keys = keySpecial(.Backspace), .command = .explorer_search_backspace },
        .{ .keys = keySpecial(.Up), .command = .explorer_move_up },
        .{ .keys = keySpecial(.Down), .command = .explorer_move_down },
        .{ .keys = keySpecial(.Enter), .command = .explorer_open_selected },
    };

    for (cases) |case| {
        try std.testing.expectEqual(case.command, switch (registry.resolve(.explorer_search, case.keys)) {
            .command => |command| command,
            else => return error.ExpectedCommand,
        });
    }

    try std.testing.expect(registry.resolve(.explorer_search, keyChar('a')) == .none);
    try std.testing.expect(registry.resolve(.explorer_search, keyChar('/')) == .none);
    try std.testing.expect(registry.resolve(.explorer_search, altChar('n')) == .none);
}

test "duplicate bindings are detected within one context" {
    const duplicate = [_]Binding{
        .{ .context = .normal, .sequence = keyChar('x'), .command = .mode_insert },
        .{ .context = .normal, .sequence = keyChar('x'), .command = .mode_command },
    };
    try std.testing.expectError(error.DuplicateBinding, validateBindings(&duplicate));

    const allowed = [_]Binding{
        .{ .context = .normal, .sequence = keyChar('x'), .command = .mode_insert },
        .{ .context = .insert, .sequence = keyChar('x'), .command = .editing_insert_newline },
    };
    try validateBindings(&allowed);
}

test "prefix conflicts are detected" {
    const conflict = [_]Binding{
        .{ .context = .normal, .sequence = keyChar('g'), .command = .mode_insert },
        .{ .context = .normal, .sequence = charSeq("gg"), .command = .navigation_goto_file_start },
    };
    try std.testing.expectError(error.PrefixConflict, validateBindings(&conflict));
}

test "default bindings are internally valid" {
    try validateDefaultBindings();
}

test "normal-mode sequence defaults exist" {
    const cases = [_]struct {
        keys: KeySequence,
        command: commands.CommandId,
    }{
        .{ .keys = charSeq("gg"), .command = .navigation_goto_file_start },
        .{ .keys = keyChar('G'), .command = .navigation_goto_file_end },
        .{ .keys = keyChar('%'), .command = .navigation_matching_bracket },
        .{ .keys = keyChar('f'), .command = .navigation_goto_definition },
        .{ .keys = charSeq("zh"), .command = .navigation_scroll_left },
        .{ .keys = charSeq("zl"), .command = .navigation_scroll_right },
        .{ .keys = charSeq("zH"), .command = .navigation_scroll_left_half_page },
        .{ .keys = charSeq("zL"), .command = .navigation_scroll_right_half_page },
        .{ .keys = charSeq("zs"), .command = .navigation_scroll_cursor_start },
        .{ .keys = charSeq("ze"), .command = .navigation_scroll_cursor_end },
        .{ .keys = charSeq("zc"), .command = .fold_close },
        .{ .keys = charSeq("zo"), .command = .fold_open },
        .{ .keys = charSeq("za"), .command = .fold_toggle },
        .{ .keys = charSeq("zM"), .command = .fold_close_all },
        .{ .keys = charSeq("zR"), .command = .fold_open_all },
        .{ .keys = charSeq("zA"), .command = .fold_toggle_all },
    };

    for (cases) |case| {
        try std.testing.expect(hasDefaultBinding(.normal, case.keys, case.command));
    }
}

test "popup help search terminal picker dashboard and explorer defaults exist" {
    const cases = [_]struct {
        context: BindingContext,
        keys: KeySequence,
        command: commands.CommandId,
    }{
        .{ .context = .command_line, .keys = keySpecial(.Enter), .command = .command_execute },
        .{ .context = .command_line, .keys = keyChar('\t'), .command = .command_suggestion_next },
        .{ .context = .help, .keys = keyChar('q'), .command = .help_close },
        .{ .context = .help, .keys = keySpecial(.PageDown), .command = .help_page_down },
        .{ .context = .search, .keys = keySpecial(.Down), .command = .search_next_match },
        .{ .context = .global_search, .keys = keyChar('\t'), .command = .global_search_select_next },
        .{ .context = .git_graph, .keys = keySpecial(.Enter), .command = .git_graph_toggle_details },
        .{ .context = .git_graph, .keys = charSeq("gg"), .command = .git_graph_first },
        .{ .context = .terminal, .keys = keySpecial(.PageUp), .command = .terminal_scroll_page_up },
        .{ .context = .terminal, .keys = shiftKey(.End), .command = .terminal_scroll_bottom },
        .{ .context = .picker, .keys = keySpecial(.Enter), .command = .picker_accept },
        .{ .context = .picker_new_file, .keys = keyChar(' '), .command = .picker_begin_name_input },
        .{ .context = .picker_open_folder, .keys = keyChar(' '), .command = .picker_select_folder },
        .{ .context = .picker_open_folder, .keys = keyChar('.'), .command = .picker_select_current_folder },
        .{ .context = .prompt, .keys = keyChar('y'), .command = .prompt_confirm },
        .{ .context = .dashboard, .keys = ctrlChar('n'), .command = .dashboard_new_file },
        .{ .context = .dashboard, .keys = ctrlChar('w'), .command = .dashboard_create_workspace },
        .{ .context = .dashboard, .keys = keySpecial(.Enter), .command = .dashboard_select },
        .{ .context = .explorer, .keys = altChar('n'), .command = .explorer_new_file },
        .{ .context = .explorer_search, .keys = keySpecial(.Esc), .command = .explorer_search_cancel },
        .{ .context = .completion, .keys = keySpecial(.Enter), .command = .completion_accept },
        .{ .context = .save_confirmation, .keys = keyChar('s'), .command = .save_confirmation_save },
    };

    for (cases) |case| {
        try std.testing.expect(hasDefaultBinding(case.context, case.keys, case.command));
    }
}

test "visible command metadata is bound or command-line reachable" {
    for (commands.all()) |meta| {
        if (!meta.show_in_help) continue;
        if (defaultRegistry().countBindingsForCommand(meta.id) > 0) continue;
        if (meta.command_names.len > 0) continue;
        if (commands.isContextAllowed(meta.id, .command_line)) continue;
        return error.VisibleCommandWithoutBinding;
    }
}
