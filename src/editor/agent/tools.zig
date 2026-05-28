const std = @import("std");
const git_status = @import("../git_status.zig");
const workspace_diff = @import("../git/workspace_diff.zig");

pub const max_file_read_bytes: usize = 256 * 1024;
pub const max_file_read_lines: usize = 2_000;
pub const max_search_file_bytes: usize = 1024 * 1024;
pub const max_line_preview_bytes: usize = 160;

pub const AgentToolName = enum {
    list_files,
    read_file,
    search_text,
    get_git_status,
    get_git_diff_summary,

    pub fn label(self: AgentToolName) []const u8 {
        return switch (self) {
            .list_files => "list_files",
            .read_file => "read_file",
            .search_text => "search_text",
            .get_git_status => "get_git_status",
            .get_git_diff_summary => "get_git_diff_summary",
        };
    }
};

pub fn expectedTools() []const AgentToolName {
    return &.{
        .list_files,
        .read_file,
        .search_text,
        .get_git_status,
        .get_git_diff_summary,
    };
}

pub const ListFilesInput = struct {
    root_relative_path: ?[]const u8 = null,
    max_results: usize = 200,
};

pub const ReadFileInput = struct {
    path: []const u8,
    start_line: ?usize = null,
    max_lines: ?usize = null,
};

pub const SearchTextInput = struct {
    query: []const u8,
    max_results: usize = 50,
};

pub const GetGitStatusInput = struct {};
pub const GetGitDiffSummaryInput = struct {};

pub const AgentToolInput = union(AgentToolName) {
    list_files: ListFilesInput,
    read_file: ReadFileInput,
    search_text: SearchTextInput,
    get_git_status: GetGitStatusInput,
    get_git_diff_summary: GetGitDiffSummaryInput,
};

pub const AgentToolCall = struct {
    id: u64,
    session_id: u64,
    input: AgentToolInput,

    pub fn name(self: AgentToolCall) AgentToolName {
        return std.meta.activeTag(self.input);
    }
};

pub const FileKind = enum {
    file,
    directory,

    pub fn label(self: FileKind) []const u8 {
        return switch (self) {
            .file => "file",
            .directory => "directory",
        };
    }
};

pub const ListFileEntry = struct {
    path: []u8,
    kind: FileKind,
    size: ?u64 = null,

    pub fn deinit(self: *ListFileEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.* = undefined;
    }
};

pub const ListFilesOutput = struct {
    entries: []ListFileEntry,
    truncated: bool = false,

    pub fn deinit(self: *ListFilesOutput, allocator: std.mem.Allocator) void {
        for (self.entries) |*entry| entry.deinit(allocator);
        allocator.free(self.entries);
        self.* = undefined;
    }
};

pub const ReadFileOutput = struct {
    path: []u8,
    content: []u8,
    start_line: usize,
    line_count: usize,
    truncated_bytes: bool = false,
    truncated_lines: bool = false,
    binary: bool = false,

    pub fn deinit(self: *ReadFileOutput, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.content);
        self.* = undefined;
    }
};

pub const SearchMatch = struct {
    path: []u8,
    line: usize,
    preview: []u8,

    pub fn deinit(self: *SearchMatch, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.preview);
        self.* = undefined;
    }
};

pub const SearchTextOutput = struct {
    matches: []SearchMatch,
    truncated: bool = false,

    pub fn deinit(self: *SearchTextOutput, allocator: std.mem.Allocator) void {
        for (self.matches) |*match| match.deinit(allocator);
        allocator.free(self.matches);
        self.* = undefined;
    }
};

pub const GitStatusEntry = struct {
    path: []u8,
    state: git_status.FileState,

    pub fn deinit(self: *GitStatusEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.* = undefined;
    }
};

pub const GitStatusOutput = struct {
    branch: ?[]u8 = null,
    entries: []GitStatusEntry,
    non_git: bool = false,

    pub fn deinit(self: *GitStatusOutput, allocator: std.mem.Allocator) void {
        if (self.branch) |branch| allocator.free(branch);
        for (self.entries) |*entry| entry.deinit(allocator);
        allocator.free(self.entries);
        self.* = undefined;
    }
};

pub const GitDiffSummaryEntry = struct {
    path: []u8,
    kind: workspace_diff.GitChangeKind,
    hunks: usize = 0,
    added: usize = 0,
    removed: usize = 0,
    binary: bool = false,

    pub fn deinit(self: *GitDiffSummaryEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.* = undefined;
    }
};

pub const GitDiffSummaryOutput = struct {
    entries: []GitDiffSummaryEntry,
    truncated: bool = false,
    non_git: bool = false,

    pub fn deinit(self: *GitDiffSummaryOutput, allocator: std.mem.Allocator) void {
        for (self.entries) |*entry| entry.deinit(allocator);
        allocator.free(self.entries);
        self.* = undefined;
    }
};

pub const AgentToolOutput = union(AgentToolName) {
    list_files: ListFilesOutput,
    read_file: ReadFileOutput,
    search_text: SearchTextOutput,
    get_git_status: GitStatusOutput,
    get_git_diff_summary: GitDiffSummaryOutput,

    pub fn deinit(self: *AgentToolOutput, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .list_files => |*output| output.deinit(allocator),
            .read_file => |*output| output.deinit(allocator),
            .search_text => |*output| output.deinit(allocator),
            .get_git_status => |*output| output.deinit(allocator),
            .get_git_diff_summary => |*output| output.deinit(allocator),
        }
        self.* = undefined;
    }
};

pub const AgentToolResult = struct {
    call_id: u64,
    ok: bool,
    output: ?AgentToolOutput = null,
    error_message: ?[]u8 = null,

    pub fn deinit(self: *AgentToolResult, allocator: std.mem.Allocator) void {
        if (self.output) |*output| output.deinit(allocator);
        if (self.error_message) |message| allocator.free(message);
        self.* = undefined;
    }
};

pub fn formatToolCall(allocator: std.mem.Allocator, call: AgentToolCall) ![]u8 {
    return switch (call.input) {
        .list_files => |input| std.fmt.allocPrint(allocator, "list_files {s}", .{input.root_relative_path orelse "."}),
        .read_file => |input| std.fmt.allocPrint(allocator, "read_file {s}", .{input.path}),
        .search_text => |input| std.fmt.allocPrint(allocator, "search_text \"{s}\"", .{input.query}),
        .get_git_status => std.fmt.allocPrint(allocator, "get_git_status", .{}),
        .get_git_diff_summary => std.fmt.allocPrint(allocator, "get_git_diff_summary", .{}),
    };
}

pub fn formatToolResult(allocator: std.mem.Allocator, result: AgentToolResult) ![]u8 {
    if (!result.ok) {
        return std.fmt.allocPrint(allocator, "error: {s}", .{result.error_message orelse "tool failed"});
    }
    const output = result.output orelse return allocator.dupe(u8, "no output");
    return switch (output) {
        .list_files => |out| std.fmt.allocPrint(allocator, "{d} entries{s}", .{
            out.entries.len,
            if (out.truncated) " (truncated)" else "",
        }),
        .read_file => |out| std.fmt.allocPrint(allocator, "{s}: {d} lines{s}{s}", .{
            out.path,
            out.line_count,
            if (out.truncated_lines) " (line cap)" else "",
            if (out.truncated_bytes) " (byte cap)" else "",
        }),
        .search_text => |out| std.fmt.allocPrint(allocator, "{d} matches{s}", .{
            out.matches.len,
            if (out.truncated) " (truncated)" else "",
        }),
        .get_git_status => |out| if (out.non_git)
            allocator.dupe(u8, "not a Git repository")
        else
            std.fmt.allocPrint(allocator, "{d} changed files", .{out.entries.len}),
        .get_git_diff_summary => |out| if (out.non_git)
            allocator.dupe(u8, "not a Git repository")
        else
            std.fmt.allocPrint(allocator, "{d} changed files{s}", .{
                out.entries.len,
                if (out.truncated) " (truncated)" else "",
            }),
    };
}

test "agent tool registry contains expected read-only tools" {
    const expected = expectedTools();
    try std.testing.expectEqual(@as(usize, 5), expected.len);
    try std.testing.expectEqual(AgentToolName.list_files, expected[0]);
    try std.testing.expectEqual(AgentToolName.read_file, expected[1]);
    try std.testing.expectEqual(AgentToolName.search_text, expected[2]);
    try std.testing.expectEqual(AgentToolName.get_git_status, expected[3]);
    try std.testing.expectEqual(AgentToolName.get_git_diff_summary, expected[4]);
}
