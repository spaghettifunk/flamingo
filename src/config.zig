const std = @import("std");
const toml = @import("toml");

pub const StorageConfig = struct {
    /// Base directory for WAL files, local Parquet cache, and disk cache.
    data_dir: []const u8 = "./data",
};

// ── Root config ──────────────────────────────────────────────────────────────

pub const Config = struct {
    storage: StorageConfig = .{},
};

// ── Validation ───────────────────────────────────────────────────────────────

pub const ConfigError = error{
    MissingS3BucketName,
    MissingRootUserEmail,
    MissingRootUserPassword,
};

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
