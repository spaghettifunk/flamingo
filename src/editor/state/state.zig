const std = @import("std");
const dashboard = @import("../dashboard.zig");
const explorer = @import("../explorer.zig");
const search = @import("../search.zig");
const syntax = @import("../syntax.zig");
const lsp_state = @import("lsp_ui.zig");
const command_popup = @import("../command_popup.zig");
const global_search = @import("../global_search.zig");
const filesystem_picker = @import("../filesystem_picker.zig");
const help = @import("../help.zig");
const prompt_popup = @import("../prompt_popup.zig");
const save_confirmation = @import("../save_confirmation.zig");
const buffer = @import("../model/buffer.zig");
const tab_mod = @import("../model/tab.zig");
const normal_sequence = @import("../input_router/normal_sequence.zig");
const jump_history_mod = @import("jump_history.zig");
const git_status = @import("../git_status.zig");
const workspace_mod = @import("../workspace.zig");
const todos_mod = @import("../todos.zig");
const comments_mod = @import("../comments.zig");
const git_graph_mod = @import("../git_graph.zig");
const git_diff_mod = @import("../git/diff_service.zig");
const workspace_diff_mod = @import("../git/workspace_diff.zig");
const task_manager_mod = @import("../tasks/task_manager.zig");
const agent_manager_mod = @import("../agent/manager.zig");
const proposal_manager_mod = @import("../agent/proposal_manager.zig");

pub const EditorMode = enum {
    Dashboard,
    Normal,
    Insert,
    Command,
    OpenFilePrompt,
    FilesystemPicker,
    Prompt,
    Search,
    GlobalSearch,
    GitGraph,
    GitDiff,
    TaskPanel,
    Agent,
    Proposals,
    Help,
    Terminal,
    SaveConfirmation,
};

pub const EditorState = struct {
    mode: EditorMode = .Dashboard,
    dash: dashboard.Dashboard = .{},
    tabs: std.ArrayList(tab_mod.Tab),
    active_tab_index: usize = 0,
    tab_bar_scroll_col: usize = 0,
    command_buffer: std.ArrayListUnmanaged(u8) = .empty,
    command_popup: command_popup.CommandPopup = .{},
    filesystem_picker: filesystem_picker.FilesystemPicker = .{},
    prompt_popup: prompt_popup.PromptPopup = .{},
    save_confirmation: save_confirmation.SaveConfirmationPopup = .{},
    error_message: ?[]const u8 = null,
    status_message: ?[]const u8 = null,
    project_root: ?[]u8 = null,
    workspace: workspace_mod.WorkspaceState = .{},
    tree: ?explorer.Explorer = null,
    explorer_visible: bool = false,
    explorer_focused: bool = false,
    search_buffer: std.ArrayListUnmanaged(u8) = .empty,
    search_system: ?search.SearchSystem = null,
    global_search: global_search.GlobalSearch = .{},
    help_popup: help.HelpPopup = .{},
    todo_panel: todos_mod.TodoPanel = .{},
    comments_panel: comments_mod.CommentsPanel = .{},
    git_graph_panel: git_graph_mod.GitGraphPanel,
    git_diff_panel: workspace_diff_mod.GitDiffPanel,
    task_manager: task_manager_mod.TaskManager,
    agent_manager: agent_manager_mod.AgentManager,
    proposal_manager: proposal_manager_mod.ProposalManager,
    clipboard: ?[]u8 = null,
    render_dirty: bool = true,
    force_full_render: bool = true,
    lsp_ui: lsp_state.LspUiState,
    git_snapshot: ?git_status.Snapshot = null,
    git_diff: git_diff_mod.DiffService,
    next_syntax_buffer_id: u64 = 1,
    pending_normal_sequence: normal_sequence.KeySequence = .{},
    jump_history: jump_history_mod.JumpHistory = .{},
    quitting_all: bool = false,

    pub fn init(allocator: std.mem.Allocator) EditorState {
        return .{
            .tabs = std.ArrayList(tab_mod.Tab).empty,
            .search_system = search.SearchSystem.init(allocator),
            .lsp_ui = lsp_state.LspUiState.init(allocator),
            .git_graph_panel = git_graph_mod.GitGraphPanel.init(allocator),
            .git_diff_panel = workspace_diff_mod.GitDiffPanel.init(allocator),
            .task_manager = task_manager_mod.TaskManager.init(allocator),
            .agent_manager = agent_manager_mod.AgentManager.init(allocator),
            .proposal_manager = proposal_manager_mod.ProposalManager.init(allocator),
            .git_diff = git_diff_mod.DiffService.init(allocator),
        };
    }

    pub fn deinit(self: *EditorState, allocator: std.mem.Allocator) void {
        self.lsp_ui.deinit();
        if (self.git_snapshot) |*snapshot| {
            snapshot.deinit();
            self.git_snapshot = null;
        }
        self.git_diff.deinit();
        self.jump_history.deinit(allocator);

        for (self.tabs.items) |*tab| {
            tab.deinit(allocator);
        }
        self.tabs.deinit(allocator);
        self.tabs = std.ArrayList(tab_mod.Tab).empty;

        if (self.tree) |*t| {
            t.deinit();
            self.tree = null;
        }
        if (self.project_root) |root| {
            allocator.free(root);
            self.project_root = null;
        }
        self.workspace.deinit(allocator);
        self.todo_panel.deinit(allocator);
        self.comments_panel.deinit(allocator);
        self.git_graph_panel.deinit();
        self.git_diff_panel.deinit();
        self.task_manager.deinit();
        self.agent_manager.deinit();
        self.proposal_manager.deinit();
        if (self.search_system) |*s| {
            s.deinit();
            self.search_system = null;
        }
        self.command_buffer.deinit(allocator);
        self.command_buffer = .empty;
        self.command_popup.deinit(allocator);
        self.filesystem_picker.deinit(allocator);
        self.prompt_popup.deinit(allocator);
        self.search_buffer.deinit(allocator);
        self.search_buffer = .empty;
        self.global_search.deinit(allocator);
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
        if (self.tabs.items.len == 0) {
            self.mode = .Dashboard;
            return;
        }
        var tab = self.tabs.orderedRemove(self.active_tab_index);
        tab.deinit(allocator);

        if (self.tabs.items.len == 0) {
            self.mode = .Dashboard;
            self.active_tab_index = 0;
            self.tab_bar_scroll_col = 0;
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
        self.tab_bar_scroll_col = 0;
        self.mode = .Dashboard;
        self.explorer_visible = false;
        self.explorer_focused = false;
    }

    pub fn setProjectRoot(self: *EditorState, allocator: std.mem.Allocator, root_path: []const u8) !void {
        const owned = try allocator.dupe(u8, root_path);
        if (self.project_root) |old| allocator.free(old);
        self.project_root = owned;
    }

    pub fn setWorkspaceRoot(self: *EditorState, allocator: std.mem.Allocator, root_path: []const u8) !void {
        try self.workspace.setActive(allocator, root_path);
    }

    pub fn clearWorkspace(self: *EditorState, allocator: std.mem.Allocator) void {
        self.workspace.clear(allocator);
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
