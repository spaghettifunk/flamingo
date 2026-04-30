const std = @import("std");
const toml = @import("toml");

pub const KeybindingsConfig = struct {
    new_file: []const u8 = "ctrl+n",
    open_file: []const u8 = "ctrl+o",
    settings: []const u8 = "ctrl+p",
    toggle_explorer: []const u8 = "ctrl+e",
    switch_focus: []const u8 = "ctrl+w",
};

pub const ExplorerConfig = struct {
    width_percentage: u8 = 20,
};

// ── Root config ──────────────────────────────────────────────────────────────

pub const Config = struct {
    keybindings: KeybindingsConfig = .{},
    explorer: ExplorerConfig = .{},
};

// ── Validation ───────────────────────────────────────────────────────────────

pub const ConfigError = error{};

// TODO: fill validation function
pub fn validate(_: *const Config) ConfigError!void {}

// ── Loading ──────────────────────────────────────────────────────────────────

pub fn loadFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
) !toml.Parsed(Config) {
    // Read the whole file into a slice — caller's allocator owns it.
    const source = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, std.Io.Limit.limited(4 * 1024 * 1024));
    defer allocator.free(source);

    var parser = toml.Parser(Config).init(allocator);
    defer parser.deinit();

    return parser.parseString(source);
}
