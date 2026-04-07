//! Thin @cImport of the Arrow C Data Interface ABI.
//! ArrowSchema, ArrowArray, ArrowArrayStream are all you need
//! for zero-copy exchange with DuckDB and any other Arrow producer.

pub const c = @cImport({
    @cInclude("nanoarrow.h"); // nanoarrow.h re-exports abi.h + adds helpers
});

// Re-export the three canonical ABI types
pub const Schema = c.ArrowSchema;
pub const Array = c.ArrowArray;
pub const ArrayStream = c.ArrowArrayStream;
