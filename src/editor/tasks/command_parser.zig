const std = @import("std");

pub const ParseError = error{
    EmptyCommand,
    UnterminatedQuote,
    TrailingEscape,
} || std.mem.Allocator.Error;

pub const ParsedCommand = struct {
    display: []u8,
    argv: [][]u8,

    pub fn deinit(self: *ParsedCommand, allocator: std.mem.Allocator) void {
        allocator.free(self.display);
        for (self.argv) |arg| allocator.free(arg);
        allocator.free(self.argv);
        self.* = undefined;
    }
};

pub fn parse(allocator: std.mem.Allocator, input: []const u8) ParseError!ParsedCommand {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (trimmed.len == 0) return error.EmptyCommand;

    var tokens = std.ArrayListUnmanaged([]u8).empty;
    errdefer {
        for (tokens.items) |token| allocator.free(token);
        tokens.deinit(allocator);
    }

    var current = std.ArrayListUnmanaged(u8).empty;
    defer current.deinit(allocator);

    var quote: ?u8 = null;
    var escaping = false;
    var token_started = false;

    for (trimmed) |byte| {
        if (escaping) {
            try current.append(allocator, byte);
            token_started = true;
            escaping = false;
            continue;
        }

        if (byte == '\\') {
            escaping = true;
            token_started = true;
            continue;
        }

        if (quote) |q| {
            if (byte == q) {
                quote = null;
            } else {
                try current.append(allocator, byte);
            }
            token_started = true;
            continue;
        }

        switch (byte) {
            '"', '\'' => {
                quote = byte;
                token_started = true;
            },
            ' ', '\t', '\r', '\n' => {
                if (token_started) {
                    const token = try current.toOwnedSlice(allocator);
                    var token_owned = true;
                    errdefer if (token_owned) allocator.free(token);
                    try tokens.append(allocator, token);
                    token_owned = false;
                    current = .empty;
                    token_started = false;
                }
            },
            else => {
                try current.append(allocator, byte);
                token_started = true;
            },
        }
    }

    if (escaping) return error.TrailingEscape;
    if (quote != null) return error.UnterminatedQuote;
    if (token_started) {
        const token = try current.toOwnedSlice(allocator);
        var token_owned = true;
        errdefer if (token_owned) allocator.free(token);
        try tokens.append(allocator, token);
        token_owned = false;
        current = .empty;
    }
    if (tokens.items.len == 0) return error.EmptyCommand;

    const argv = try tokens.toOwnedSlice(allocator);
    errdefer {
        for (argv) |arg| allocator.free(arg);
        allocator.free(argv);
    }
    return .{
        .display = try allocator.dupe(u8, trimmed),
        .argv = argv,
    };
}

test "parse whitespace separated command" {
    const allocator = std.testing.allocator;
    var parsed = try parse(allocator, "zig build test");
    defer parsed.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), parsed.argv.len);
    try std.testing.expectEqualStrings("zig", parsed.argv[0]);
    try std.testing.expectEqualStrings("build", parsed.argv[1]);
    try std.testing.expectEqualStrings("test", parsed.argv[2]);
    try std.testing.expectEqualStrings("zig build test", parsed.display);
}

test "parse quoted arguments and escapes" {
    const allocator = std.testing.allocator;
    var parsed = try parse(allocator, "git commit -m \"hello world\" 'src/a file.zig' path\\ with\\ spaces");
    defer parsed.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 6), parsed.argv.len);
    try std.testing.expectEqualStrings("hello world", parsed.argv[3]);
    try std.testing.expectEqualStrings("src/a file.zig", parsed.argv[4]);
    try std.testing.expectEqualStrings("path with spaces", parsed.argv[5]);
}

test "parse rejects unterminated input" {
    try std.testing.expectError(error.UnterminatedQuote, parse(std.testing.allocator, "zig \"build"));
    try std.testing.expectError(error.TrailingEscape, parse(std.testing.allocator, "zig build\\"));
    try std.testing.expectError(error.EmptyCommand, parse(std.testing.allocator, "   "));
}
