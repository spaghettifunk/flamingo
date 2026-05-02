const std = @import("std");
const buffer = @import("buffer.zig");
const syntax = @import("../syntax.zig");

pub const Pos = struct {
    row: usize,
    col: usize,
};

pub const Cursor = struct {
    row: usize = 0,
    col: usize = 0,
    selection_start: ?Pos = null,
    preferred_col: ?usize = null,
};

pub const Tab = struct {
    buf: buffer.Buffer,
    cursors: std.ArrayListUnmanaged(Cursor),
    syntax_highlighter: syntax.Highlighter,
    syntax_buffer_id: u64,
    syntax_requested_revision: ?u64 = null,
    main_cursor_idx: usize = 0,
    scroll_row: usize = 0,
    lsp_notified_revision: ?u64 = null,
    lsp_pending_since_ns: ?u64 = null,

    pub fn deinit(self: *Tab, allocator: std.mem.Allocator) void {
        self.syntax_highlighter.deinit();
        self.buf.deinit();
        self.cursors.deinit(allocator);
    }

    pub fn mainCursor(self: *Tab) *Cursor {
        return &self.cursors.items[self.main_cursor_idx];
    }

    pub fn needsLspChangeNotification(self: *const Tab) bool {
        return self.buf.is_dirty and self.buf.filename != null and self.lsp_notified_revision != self.buf.revision;
    }

    pub fn markLspChangeNotified(self: *Tab) void {
        self.lsp_notified_revision = self.buf.revision;
        self.lsp_pending_since_ns = null;
    }
};
