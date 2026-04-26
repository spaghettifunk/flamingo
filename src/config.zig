const std = @import("std");
const toml = @import("toml");

pub const KeybindingsConfig = struct {
    new_file: []const u8 = "ctrl+n",
    open_file: []const u8 = "ctrl+o",
    settings: []const u8 = "ctrl+p",
};

// ── Root config ──────────────────────────────────────────────────────────────

pub const Config = struct {
    keybindings: KeybindingsConfig = .{},
};

// ── Validation ───────────────────────────────────────────────────────────────

pub const ConfigError = error{};

// TODO: fill validation function
pub fn validate(_: *const Config) ConfigError!void {}

// ── Loading ──────────────────────────────────────────────────────────────────

pub fn loadFile(
    allocator: std.mem.Allocator,
    path: []const u8,
) !toml.Parsed(Config) {
    // Read the whole file into a slice — caller's allocator owns it.
    const source = try std.fs.cwd().readFileAlloc(allocator, path, 4 * 1024 * 1024);
    defer allocator.free(source);

    var parser = toml.Parser(Config).init(allocator);
    defer parser.deinit();

    return parser.parseString(source);
}
