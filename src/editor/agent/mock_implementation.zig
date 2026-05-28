const std = @import("std");
const proposal = @import("proposal.zig");

pub fn buildMockProposalDraft(
    allocator: std.mem.Allocator,
    session_id: u64,
    prompt: []const u8,
    created_at_ms: i64,
) !proposal.PatchProposalDraft {
    const topic = classifyPrompt(prompt);
    const file_path = try std.fmt.allocPrint(allocator, "docs/agent-proposals/mock-session-{d}.md", .{session_id});
    errdefer allocator.free(file_path);

    const description = try std.fmt.allocPrint(allocator, "Mock implementation proposal: {s}", .{topic});
    errdefer allocator.free(description);

    const content = try std.fmt.allocPrint(allocator,
        \\# Mock Agent Proposal
        \\
        \\Session: #{d}
        \\Topic: {s}
        \\
        \\Prompt:
        \\{s}
        \\
        \\This file was created only after proposal approval.
        \\
    , .{ session_id, topic, prompt });
    errdefer allocator.free(content);

    const unified_diff = try renderCreateFileDiff(allocator, file_path, content);
    errdefer allocator.free(unified_diff);

    return .{
        .session_id = session_id,
        .file_path = file_path,
        .description = description,
        .unified_diff = unified_diff,
        .edit = .{ .create_file = .{ .content = content } },
        .created_at_ms = created_at_ms,
    };
}

fn classifyPrompt(prompt: []const u8) []const u8 {
    if (containsInsensitive(prompt, "help")) return "help panel";
    if (containsInsensitive(prompt, "git")) return "git workflow";
    if (containsInsensitive(prompt, "agent")) return "agent workflow";
    return "workspace change";
}

fn containsInsensitive(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i <= haystack.len - needle.len) : (i += 1) {
        var matched = true;
        for (needle, 0..) |ch, j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(ch)) {
                matched = false;
                break;
            }
        }
        if (matched) return true;
    }
    return false;
}

fn renderCreateFileDiff(allocator: std.mem.Allocator, file_path: []const u8, content: []const u8) ![]u8 {
    var out = std.ArrayListUnmanaged(u8).empty;
    errdefer out.deinit(allocator);

    const header = try std.fmt.allocPrint(allocator,
        \\--- /dev/null
        \\+++ b/{s}
        \\@@ -0,0 +1,{d} @@
        \\
    , .{ file_path, lineCount(content) });
    defer allocator.free(header);
    try out.appendSlice(allocator, header);

    var start: usize = 0;
    while (start < content.len) {
        const end = std.mem.indexOfScalarPos(u8, content, start, '\n') orelse content.len;
        const line = content[start..end];
        try out.append(allocator, '+');
        try out.appendSlice(allocator, line);
        try out.append(allocator, '\n');
        if (end == content.len) break;
        start = end + 1;
    }
    return out.toOwnedSlice(allocator);
}

fn lineCount(content: []const u8) usize {
    if (content.len == 0) return 0;
    var count: usize = 0;
    for (content) |ch| {
        if (ch == '\n') count += 1;
    }
    return if (content[content.len - 1] == '\n') count else count + 1;
}

test "mock implementation creates owned proposal draft" {
    const allocator = std.testing.allocator;
    var draft = try buildMockProposalDraft(allocator, 42, "add help panel", 10);
    defer draft.deinit(allocator);

    try std.testing.expectEqual(@as(u64, 42), draft.session_id);
    try std.testing.expect(std.mem.endsWith(u8, draft.file_path, "mock-session-42.md"));
    try std.testing.expect(std.mem.indexOf(u8, draft.description, "help") != null);
    try std.testing.expect(std.mem.indexOf(u8, draft.unified_diff, "+++ b/docs/agent-proposals/mock-session-42.md") != null);
}
