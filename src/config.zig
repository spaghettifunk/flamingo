const std = @import("std");
const toml = @import("toml");

/// Matches [node] role = "..."
/// Comma-separated multi-role is handled at runtime by splitting the string,
/// so the raw string is kept as []const u8 in NodeConfig and parsed separately.
pub const MetaStore = enum {
    sqlite,
    postgres,
    mysql,
};

pub const S3Provider = enum {
    aws,
    gcs,
    azure,
    minio,
};

// ── Sub-tables ───────────────────────────────────────────────────────────────

pub const NodeConfig = struct {
    /// "all" | "router" | "ingester" | "querier" | "compactor" | "alertmanager"
    /// Comma-separated for multi-role nodes, e.g. "ingester,querier".
    /// Parsed into []NodeRole at runtime via parseRoles().
    role: []const u8 = "all",
};

pub const HttpConfig = struct {
    address: []const u8 = "localhost",
    port: u16 = 5080,
};

pub const StorageConfig = struct {
    /// Base directory for WAL files, local Parquet cache, and disk cache.
    data_dir: []const u8 = "./data",
};

pub const MemtableConfig = struct {
    /// Bytes — seal the active MemTable and start a new one when reached (default 256 MB).
    max_size_in_memory: u64 = 268_435_456,

    /// Bytes — seal the active WAL file when reached (default 128 MB).
    max_size_on_disk: u64 = 134_217_728,

    /// Seconds between Immutable → local Parquet flush background runs.
    persist_interval: u32 = 5,

    /// Seconds between local Parquet → S3 upload check runs.
    push_interval: u32 = 10,

    /// Seconds — force-upload a WAL file even if size threshold is not met.
    max_retention_time: u32 = 600,
};

pub const CompactorConfig = struct {
    /// Bytes — maximum size of a single compacted Parquet output file (default 256 MB).
    max_file_size: u64 = 268_435_456,

    /// Number of merge threads. 0 means auto: CPU count × 2.
    thread_num: u32 = 0,
};

pub const S3Config = struct {
    provider: S3Provider = .aws,

    /// Required — validated at startup.
    bucket_name: []const u8 = "",

    region_name: []const u8 = "us-east-1",
};

pub const MetaConfig = struct {
    store: MetaStore = .sqlite,
};

pub const CacheConfig = struct {
    memory_cache_enabled: bool = true,

    /// Bytes. 0 means auto: 50 % of available RAM.
    memory_cache_max_size: u64 = 0,
};

pub const IndexConfig = struct {
    /// Opt-in Tantivy full-text indexing. Off by default — enabling it costs
    /// ingestion throughput in exchange for faster str_match() queries.
    enable_inverted_index: bool = false,
};

pub const PerformanceConfig = struct {
    /// One WAL file per CPU core — eliminates lock contention at high ingest rates.
    /// Enable only when sustained ingestion exceeds ~12 MB/s/core.
    per_thread_lock: bool = false,

    /// Hard cap on the number of fields accepted per log record.
    cols_per_record_limit: u32 = 1000,
};

pub const AuthConfig = struct {
    /// Bootstrap root user created on first start. Validated at startup.
    root_user_email: []const u8 = "",
    root_user_password: []const u8 = "",
};

// ── Root config ──────────────────────────────────────────────────────────────

pub const Config = struct {
    node: NodeConfig = .{},
    http: HttpConfig = .{},
    storage: StorageConfig = .{},
    memtable: MemtableConfig = .{},
    compactor: CompactorConfig = .{},
    s3: S3Config = .{},
    meta: MetaConfig = .{},
    cache: CacheConfig = .{},
    index: IndexConfig = .{},
    performance: PerformanceConfig = .{},
    auth: AuthConfig = .{},
};

// ── Node role parsing ────────────────────────────────────────────────────────

pub const NodeRole = enum {
    all,
    router,
    ingester,
    querier,
    compactor,
    alertmanager,
};

/// Parse config.node.role (a comma-separated string) into a slice of NodeRole.
/// Caller owns the returned slice; use the same allocator passed to the parser.
pub fn parseRoles(allocator: std.mem.Allocator, raw: []const u8) ![]NodeRole {
    var roles = std.ArrayList(NodeRole).init(allocator);
    var it = std.mem.splitScalar(u8, raw, ',');
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        const role = std.meta.stringToEnum(NodeRole, trimmed) orelse
            return error.UnknownNodeRole;
        try roles.append(role);
    }
    return roles.toOwnedSlice();
}

// ── Validation ───────────────────────────────────────────────────────────────

pub const ConfigError = error{
    MissingS3BucketName,
    MissingRootUserEmail,
    MissingRootUserPassword,
};

pub fn validate(cfg: *const Config) ConfigError!void {
    if (cfg.s3.bucket_name.len == 0) return error.MissingS3BucketName;
    if (cfg.auth.root_user_email.len == 0) return error.MissingRootUserEmail;
    if (cfg.auth.root_user_password.len == 0) return error.MissingRootUserPassword;
}

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
