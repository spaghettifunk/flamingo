//! Zig-native Arrow type aliases and helpers.
//! Wraps the nanoarrow C constants into idiomatic Zig enums and helpers
//! so the rest of the codebase never has to touch raw C integers.

const c = @cImport({
    @cInclude("nanoarrow.h");
});

// ── Arrow physical types ─────────────────────────────────────────────────────

pub const DataType = enum(c_int) {
    uninitialized = c.NANOARROW_TYPE_UNINITIALIZED,
    null = c.NANOARROW_TYPE_NA,
    bool = c.NANOARROW_TYPE_BOOL,
    uint8 = c.NANOARROW_TYPE_UINT8,
    int8 = c.NANOARROW_TYPE_INT8,
    uint16 = c.NANOARROW_TYPE_UINT16,
    int16 = c.NANOARROW_TYPE_INT16,
    uint32 = c.NANOARROW_TYPE_UINT32,
    int32 = c.NANOARROW_TYPE_INT32,
    uint64 = c.NANOARROW_TYPE_UINT64,
    int64 = c.NANOARROW_TYPE_INT64,
    float16 = c.NANOARROW_TYPE_HALF_FLOAT,
    float32 = c.NANOARROW_TYPE_FLOAT,
    float64 = c.NANOARROW_TYPE_DOUBLE,
    utf8 = c.NANOARROW_TYPE_STRING,
    large_utf8 = c.NANOARROW_TYPE_LARGE_STRING,
    binary = c.NANOARROW_TYPE_BINARY,
    large_binary = c.NANOARROW_TYPE_LARGE_BINARY,
    timestamp_ns = c.NANOARROW_TYPE_TIMESTAMP,
    duration_ns = c.NANOARROW_TYPE_DURATION,
    list = c.NANOARROW_TYPE_LIST,
    struct_ = c.NANOARROW_TYPE_STRUCT,
    map = c.NANOARROW_TYPE_MAP,
    dict = c.NANOARROW_TYPE_DICTIONARY,

    /// Return the raw C integer for passing into nanoarrow functions.
    pub fn cInt(self: DataType) c_int {
        return @intFromEnum(self);
    }

    /// Map a Zig type to the corresponding Arrow DataType at comptime.
    pub fn fromZigType(comptime T: type) DataType {
        return switch (T) {
            bool => .bool,
            u8 => .uint8,
            i8 => .int8,
            u16 => .uint16,
            i16 => .int16,
            u32 => .uint32,
            i32 => .int32,
            u64 => .uint64,
            i64 => .int64,
            f32 => .float32,
            f64 => .float64,
            []u8, []const u8 => .binary,
            [:0]u8, [:0]const u8 => .utf8,
            else => @compileError("No Arrow DataType mapping for " ++ @typeName(T)),
        };
    }
};

// ── Time units (for timestamp / duration columns) ────────────────────────────

pub const TimeUnit = enum(c_int) {
    seconds = c.NANOARROW_TIME_UNIT_SECOND,
    milliseconds = c.NANOARROW_TIME_UNIT_MILLI,
    microseconds = c.NANOARROW_TIME_UNIT_MICRO,
    nanoseconds = c.NANOARROW_TIME_UNIT_NANO,
};

// ── Null / validity helpers ───────────────────────────────────────────────────

/// Mirrors NANOARROW_OK (0). All nanoarrow C functions return this on success.
pub const ok: c_int = c.NANOARROW_OK;

pub inline fn isOk(rc: c_int) bool {
    return rc == ok;
}

pub const ArrowError = error{
    ArrowError,
    InvalidType,
    OutOfMemory,
    NotImplemented,
};

pub inline fn check(rc: c_int) ArrowError!void {
    if (rc != ok) return ArrowError.ArrowError;
}

// ── Schema format strings (Arrow C Data Interface) ───────────────────────────
// These are the raw format strings the Arrow spec defines.
// Useful when you need to inspect or construct schemas manually.

pub const fmt = struct {
    pub const null_type = "n";
    pub const bool_type = "b";
    pub const int8 = "c";
    pub const uint8 = "C";
    pub const int16 = "s";
    pub const uint16 = "S";
    pub const int32 = "i";
    pub const uint32 = "I";
    pub const int64 = "l";
    pub const uint64 = "L";
    pub const float16 = "e";
    pub const float32 = "f";
    pub const float64 = "g";
    pub const utf8 = "u";
    pub const large_utf8 = "U";
    pub const binary = "z";
    pub const ts_ns_utc = "tsn:UTC"; // timestamp nanoseconds UTC — most common for logs/traces
};

// ── Observability-specific column type helpers ───────────────────────────────
// Convenience aliases for the column types you'll use constantly in
// the log/trace/metric ingestion pipeline.

pub const log_schema = struct {
    pub const timestamp = DataType.int64; // Unix epoch nanoseconds
    pub const level = DataType.int8; // 0=trace 1=debug 2=info 3=warn 4=error
    pub const message = DataType.utf8;
    pub const service = DataType.utf8;
    pub const trace_id = DataType.binary; // 16-byte UUID raw bytes
    pub const span_id = DataType.binary; // 8-byte span id raw bytes
    pub const attrs = DataType.utf8; // JSON-encoded attributes blob
};

pub const metric_schema = struct {
    pub const timestamp = DataType.int64;
    pub const name = DataType.utf8;
    pub const value = DataType.float64;
    pub const labels = DataType.utf8; // JSON-encoded label set
};
