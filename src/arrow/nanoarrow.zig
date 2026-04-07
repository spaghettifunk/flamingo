const std = @import("std");
const c = @import("abi.zig").c;

pub const Error = error{
    ArrowError,
    OutOfMemory,
    InvalidType,
};

// ── Schema ──────────────────────────────────────────────────────────────────

pub const Schema = struct {
    inner: c.ArrowSchema,

    pub fn init() Schema {
        var s: c.ArrowSchema = undefined;
        c.ArrowSchemaInit(&s);
        return .{ .inner = s };
    }

    pub fn deinit(self: *Schema) void {
        // nanoarrow's release callback (Arrow spec requirement)
        if (self.inner.release) |release| release(&self.inner);
    }

    pub fn setType(self: *Schema, arrow_type: c_int) Error!void {
        if (c.ArrowSchemaSetType(&self.inner, arrow_type) != c.NANOARROW_OK)
            return Error.InvalidType;
    }

    pub fn setName(self: *Schema, name: [:0]const u8) Error!void {
        if (c.ArrowSchemaSetName(&self.inner, name.ptr) != c.NANOARROW_OK)
            return Error.ArrowError;
    }

    /// Add a child field (for struct/list schemas).
    pub fn addChild(self: *Schema, n_children: i64) Error!void {
        if (c.ArrowSchemaAllocateChildren(&self.inner, n_children) != c.NANOARROW_OK)
            return Error.OutOfMemory;
    }
};

// ── Array (columnar data) ────────────────────────────────────────────────────

pub const Array = struct {
    inner: c.ArrowArray,
    schema: c.ArrowSchema, // kept alive for the array's lifetime

    pub fn init(schema: *const Schema) Error!Array {
        var arr: c.ArrowArray = undefined;
        if (c.ArrowArrayInitFromSchema(&arr, &schema.inner, null) != c.NANOARROW_OK)
            return Error.ArrowError;
        return .{ .inner = arr, .schema = schema.inner };
    }

    pub fn deinit(self: *Array) void {
        if (self.inner.release) |release| release(&self.inner);
    }

    pub fn startBuilding(self: *Array) Error!void {
        if (c.ArrowArrayStartAppending(&self.inner) != c.NANOARROW_OK)
            return Error.ArrowError;
    }

    pub fn appendInt64(self: *Array, value: i64) Error!void {
        if (c.ArrowArrayAppendInt(&self.inner, value) != c.NANOARROW_OK)
            return Error.ArrowError;
    }

    pub fn appendDouble(self: *Array, value: f64) Error!void {
        if (c.ArrowArrayAppendDouble(&self.inner, value) != c.NANOARROW_OK)
            return Error.ArrowError;
    }

    pub fn appendString(self: *Array, value: []const u8) Error!void {
        const sv = c.ArrowStringView{
            .data = value.ptr,
            .size_bytes = @intCast(value.len),
        };
        if (c.ArrowArrayAppendString(&self.inner, sv) != c.NANOARROW_OK)
            return Error.ArrowError;
    }

    pub fn appendNull(self: *Array) Error!void {
        if (c.ArrowArrayAppendNull(&self.inner, 1) != c.NANOARROW_OK)
            return Error.ArrowError;
    }

    pub fn finish(self: *Array, length: i64) Error!void {
        if (c.ArrowArrayFinishBuilding(&self.inner, null) != c.NANOARROW_OK)
            return Error.ArrowError;
        self.inner.length = length;
    }
};

// ── RecordBatch ──────────────────────────────────────────────────────────────
// A record batch = schema + parallel arrays, one per column.

pub const RecordBatch = struct {
    schema: c.ArrowSchema,
    columns: c.ArrowArray, // nanoarrow struct array holds all columns

    pub fn init(
        alloc: std.mem.Allocator,
        field_names: []const [:0]const u8,
        field_types: []const c_int,
    ) Error!RecordBatch {
        _ = alloc;
        std.debug.assert(field_names.len == field_types.len);

        var schema: c.ArrowSchema = undefined;
        c.ArrowSchemaInit(&schema);
        if (c.ArrowSchemaSetTypeStruct(&schema, @intCast(field_names.len)) != c.NANOARROW_OK) return Error.ArrowError;

        for (field_names, field_types, 0..) |name, ftype, i| {
            const child = &schema.children[i];
            c.ArrowSchemaInit(child);
            if (c.ArrowSchemaSetType(child, ftype) != c.NANOARROW_OK)
                return Error.InvalidType;
            if (c.ArrowSchemaSetName(child, name.ptr) != c.NANOARROW_OK)
                return Error.ArrowError;
        }

        var columns: c.ArrowArray = undefined;
        if (c.ArrowArrayInitFromSchema(&columns, &schema, null) != c.NANOARROW_OK)
            return Error.ArrowError;
        if (c.ArrowArrayStartAppending(&columns) != c.NANOARROW_OK)
            return Error.ArrowError;

        return .{ .schema = schema, .columns = columns };
    }

    /// Returns a pointer to the i-th column's ArrowArray for appending.
    pub fn column(self: *RecordBatch, i: usize) *c.ArrowArray {
        return self.columns.children[i];
    }

    pub fn finish(self: *RecordBatch, n_rows: i64) Error!void {
        if (c.ArrowArrayFinishBuilding(&self.columns, null) != c.NANOARROW_OK)
            return Error.ArrowError;
        self.columns.length = n_rows;
    }

    pub fn deinit(self: *RecordBatch) void {
        if (self.columns.release) |r| r(&self.columns);
        if (self.schema.release) |r| r(&self.schema);
    }

    /// Expose raw pointers for hand-off to DuckDB's duckdb_arrow_scan.
    pub fn rawPtrs(self: *RecordBatch) struct {
        schema: *c.ArrowSchema,
        array: *c.ArrowArray,
    } {
        return .{ .schema = &self.schema, .array = &self.columns };
    }
};
