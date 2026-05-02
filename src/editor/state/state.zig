const std = @import("std");
const dashboard = @import("../dashboard.zig");
const explorer = @import("../explorer.zig");
const search = @import("../search.zig");
const syntax = @import("../syntax.zig");
const lsp_state = @import("lsp_ui.zig");
const command_popup = @import("../command_popup.zig");
const buffer = @import("../model/buffer.zig");
const tab_mod = @import("../model/tab.zig");

pub const EditorMode = enum {
    Dashboard,
    Normal,
    Insert,
    Command,
    OpenFilePrompt,
    Search,
};

pub const EditorState = struct {
    mode: EditorMode = .Dashboard,
    dash: dashboard.Dashboard = .{},
    tabs: std.ArrayList(tab_mod.Tab),
    active_tab_index: usize = 0,
    command_buffer: std.ArrayListUnmanaged(u8) = .empty,
    command_popup: command_popup.CommandPopup = .{},
    error_message: ?[]const u8 = null,
    tree: ?explorer.Explorer = null,
    explorer_visible: bool = false,
    explorer_focused: bool = false,
    search_buffer: std.ArrayListUnmanaged(u8) = .empty,
    search_system: ?search.SearchSystem = null,
    clipboard: ?[]u8 = null,
    render_dirty: bool = true,
    force_full_render: bool = true,
    lsp_ui: lsp_state.LspUiState,
    next_syntax_buffer_id: u64 = 1,

    pub fn init(allocator: std.mem.Allocator) EditorState {
        return .{
            .tabs = std.ArrayList(tab_mod.Tab).empty,
            .search_system = search.SearchSystem.init(allocator),
            .lsp_ui = lsp_state.LspUiState.init(allocator),
        };
    }

    pub fn deinit(self: *EditorState, allocator: std.mem.Allocator) void {
        self.lsp_ui.deinit();

        for (self.tabs.items) |*tab| {
            tab.deinit(allocator);
        }
        self.tabs.deinit(allocator);
        self.tabs = std.ArrayList(tab_mod.Tab).empty;

        if (self.tree) |*t| {
            t.deinit();
            self.tree = null;
        }
        if (self.search_system) |*s| {
            s.deinit();
            self.search_system = null;
        }
        self.command_buffer.deinit(allocator);
        self.command_buffer = .empty;
        self.command_popup.deinit(allocator);
        self.search_buffer.deinit(allocator);
        self.search_buffer = .empty;
        if (self.clipboard) |c| {
            allocator.free(c);
            self.clipboard = null;
        }
    }

    pub fn currentTab(self: *EditorState) ?*tab_mod.Tab {
        if (self.tabs.items.len == 0) return null;
        return &self.tabs.items[self.active_tab_index];
    }

    pub fn findTabBySyntaxBufferId(self: *EditorState, buffer_id: u64) ?*tab_mod.Tab {
        for (self.tabs.items) |*tab| {
            if (tab.syntax_buffer_id == buffer_id) return tab;
        }
        return null;
    }

    pub fn addTab(self: *EditorState, allocator: std.mem.Allocator, buf: buffer.Buffer) !bool {
        if (buf.filename) |new_filename| {
            for (self.tabs.items, 0..) |*tab, i| {
                if (tab.buf.filename) |existing_filename| {
                    if (std.mem.eql(u8, existing_filename, new_filename)) {
                        var duplicate = buf;
                        duplicate.deinit();
                        self.active_tab_index = i;
                        return false;
                    }
                }
            }
        }

        var cursors = std.ArrayListUnmanaged(tab_mod.Cursor).empty;
        try cursors.append(allocator, .{});
        const syntax_buffer_id = self.next_syntax_buffer_id;
        self.next_syntax_buffer_id +%= 1;
        try self.tabs.append(allocator, .{
            .buf = buf,
            .cursors = cursors,
            .syntax_highlighter = syntax.Highlighter.init(allocator),
            .syntax_buffer_id = syntax_buffer_id,
            .lsp_notified_revision = if (buf.filename != null) buf.revision else null,
        });
        self.active_tab_index = self.tabs.items.len - 1;
        return true;
    }

    pub fn closeTab(self: *EditorState, allocator: std.mem.Allocator) void {
        if (self.tabs.items.len == 0) return;
        var tab = self.tabs.orderedRemove(self.active_tab_index);
        tab.deinit(allocator);

        if (self.tabs.items.len == 0) {
            self.mode = .Dashboard;
            self.active_tab_index = 0;
            self.explorer_visible = false;
            self.explorer_focused = false;
        } else if (self.active_tab_index >= self.tabs.items.len) {
            self.active_tab_index = self.tabs.items.len - 1;
        }
    }

    pub fn nextTab(self: *EditorState) void {
        if (self.tabs.items.len <= 1) return;
        self.active_tab_index = (self.active_tab_index + 1) % self.tabs.items.len;
    }

    pub fn prevTab(self: *EditorState) void {
        if (self.tabs.items.len <= 1) return;
        if (self.active_tab_index == 0) {
            self.active_tab_index = self.tabs.items.len - 1;
        } else {
            self.active_tab_index -= 1;
        }
    }

    pub fn closeAllTabs(self: *EditorState, allocator: std.mem.Allocator) void {
        for (self.tabs.items) |*tab| {
            tab.deinit(allocator);
        }
        self.tabs.clearRetainingCapacity();
        self.active_tab_index = 0;
        self.mode = .Dashboard;
        self.explorer_visible = false;
        self.explorer_focused = false;
    }
};

test "EditorState add duplicate and close tab" {
    const allocator = std.testing.allocator;
    var state = EditorState.init(allocator);
    defer state.deinit(allocator);

    var first = try buffer.Buffer.init(allocator);
    errdefer first.deinit();
    try first.setFilename("main.zig");
    try std.testing.expect(try state.addTab(allocator, first));

    var duplicate = try buffer.Buffer.init(allocator);
    errdefer duplicate.deinit();
    try duplicate.setFilename("main.zig");
    try std.testing.expect(!try state.addTab(allocator, duplicate));
    try std.testing.expectEqual(@as(usize, 1), state.tabs.items.len);

    state.closeTab(allocator);
    try std.testing.expectEqual(EditorMode.Dashboard, state.mode);
    try std.testing.expectEqual(@as(usize, 0), state.tabs.items.len);
}
