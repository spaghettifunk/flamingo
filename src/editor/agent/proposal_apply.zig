const std = @import("std");
const editor_mod = @import("../editor.zig");
const buffer_mod = @import("../model/buffer.zig");
const proposal_mod = @import("proposal.zig");
const guard = @import("workspace_guard.zig");

pub const ApplyError = error{
    OutsideWorkspace,
    GitInternalsForbidden,
    BinaryFile,
    PathAlreadyExists,
    FileNotFound,
    ExpectedFile,
    HunkMismatch,
    InvalidLine,
};

const max_apply_file_bytes: usize = 1024 * 1024;

pub fn applyProposalToEditor(ed: anytype, item: *proposal_mod.PatchProposal, workspace_root: []const u8) !void {
    const absolute_path = try guard.resolveWorkspacePath(ed.allocator, ed.io, workspace_root, item.file_path);
    defer ed.allocator.free(absolute_path);

    switch (item.edit) {
        .create_file => |edit| try applyCreateFile(ed, absolute_path, edit.content),
        .insert_at_line => |edit| try applyInsertAtLine(ed, absolute_path, edit),
    }
}

fn applyCreateFile(ed: anytype, absolute_path: []const u8, content: []const u8) !void {
    if (std.Io.Dir.cwd().statFile(ed.io, absolute_path, .{})) |_| return error.PathAlreadyExists else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    if (std.fs.path.dirname(absolute_path)) |parent| {
        try std.Io.Dir.cwd().createDirPath(ed.io, parent);
    }

    var buf = try buffer_mod.Buffer.init(ed.allocator);
    defer buf.deinit();
    try buf.setFilename(absolute_path);
    try buf.saveTextToFile(ed.io, absolute_path, content);
    if (ed.state.tree) |*tree| {
        tree.refresh(absolute_path) catch {};
    }
}

fn applyInsertAtLine(ed: anytype, absolute_path: []const u8, edit: proposal_mod.InsertAtLineEdit) !void {
    const stat = try std.Io.Dir.cwd().statFile(ed.io, absolute_path, .{});
    if (stat.kind != .file) return error.ExpectedFile;
    if (stat.size > max_apply_file_bytes) return error.HunkMismatch;

    const original = try std.Io.Dir.cwd().readFileAlloc(ed.io, absolute_path, ed.allocator, std.Io.Limit.limited(max_apply_file_bytes));
    defer ed.allocator.free(original);
    if (isLikelyBinary(original)) return error.BinaryFile;
    if (edit.expected_before) |expected| {
        if (!std.mem.eql(u8, original, expected)) return error.HunkMismatch;
    }

    const updated = try insertTextAtLine(ed.allocator, original, edit.line, edit.content);
    defer ed.allocator.free(updated);

    for (ed.state.tabs.items) |*tab| {
        const filename = tab.buf.filename orelse continue;
        const matches = blk: {
            if (std.mem.eql(u8, filename, absolute_path)) break :blk true;
            const real_filename = realPathOrNull(ed.allocator, ed.io, filename) orelse break :blk false;
            defer ed.allocator.free(real_filename);
            const real_path = realPathOrNull(ed.allocator, ed.io, absolute_path) orelse break :blk false;
            defer ed.allocator.free(real_path);
            break :blk std.mem.eql(u8, real_filename, real_path);
        };
        if (matches) {
            try replaceBufferText(&tab.buf, updated);
            try tab.buf.saveToFile(ed.io, absolute_path);
            return;
        }
    }

    var buf = try buffer_mod.Buffer.loadFromFile(ed.allocator, ed.io, absolute_path);
    defer buf.deinit();
    try replaceBufferText(&buf, updated);
    try buf.saveToFile(ed.io, absolute_path);
}

fn insertTextAtLine(allocator: std.mem.Allocator, original: []const u8, line: usize, insert: []const u8) ![]u8 {
    const offset = byteOffsetForLine(original, line) orelse return error.InvalidLine;
    var out = std.ArrayListUnmanaged(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, original[0..offset]);
    try out.appendSlice(allocator, insert);
    if (insert.len > 0 and insert[insert.len - 1] != '\n' and offset < original.len) {
        try out.append(allocator, '\n');
    }
    try out.appendSlice(allocator, original[offset..]);
    return out.toOwnedSlice(allocator);
}

fn byteOffsetForLine(text: []const u8, line: usize) ?usize {
    if (line == 0) return 0;
    var current: usize = 0;
    for (text, 0..) |ch, i| {
        if (ch == '\n') {
            current += 1;
            if (current == line) return i + 1;
        }
    }
    return if (current == line) text.len else null;
}

fn replaceBufferText(buf: *buffer_mod.Buffer, text: []const u8) !void {
    buf.beginUndoGroup();
    defer buf.endUndoGroup();

    const last_row = buf.lines.items.len - 1;
    const last_col = buf.lines.items[last_row].len();
    try buf.deleteRange(0, 0, last_row, last_col);

    var row: usize = 0;
    var col: usize = 0;
    for (text) |ch| {
        if (ch == '\n') {
            try buf.insertNewline(row, col);
            row += 1;
            col = 0;
        } else {
            try buf.insertChar(row, col, ch);
            col += 1;
        }
    }
}

fn realPathOrNull(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ?[]u8 {
    const z = std.Io.Dir.cwd().realPathFileAlloc(io, path, allocator) catch return null;
    defer allocator.free(z);
    return allocator.dupe(u8, z) catch null;
}

fn isLikelyBinary(bytes: []const u8) bool {
    for (bytes) |byte| {
        if (byte == 0) return true;
    }
    return false;
}

test "proposal apply inserts text at requested line" {
    const allocator = std.testing.allocator;
    const original = "one\ntwo\n";
    const updated = try insertTextAtLine(allocator, original, 1, "inserted\n");
    defer allocator.free(updated);
    try std.testing.expectEqualStrings("one\ninserted\ntwo\n", updated);
}

test "proposal apply rejects invalid insert line" {
    try std.testing.expectError(error.InvalidLine, insertTextAtLine(std.testing.allocator, "one\n", 8, "x\n"));
}

test "proposal apply creates file only after approval path" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);

    var ed = try editor_mod.Editor.init(allocator, io, .{});
    defer ed.deinit();

    var item = try testProposal(allocator, "docs/demo.md", .{ .create_file = .{
        .content = try allocator.dupe(u8, "hello\n"),
    } });
    defer item.deinit(allocator);

    try applyProposalToEditor(&ed, &item, root);
    const created_path = try std.fs.path.join(allocator, &.{ root, "docs/demo.md" });
    defer allocator.free(created_path);
    const contents = try std.Io.Dir.cwd().readFileAlloc(io, created_path, allocator, std.Io.Limit.limited(1024));
    defer allocator.free(contents);
    try std.testing.expectEqualStrings("hello\n", contents);
}

test "proposal apply rejects git paths" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);

    var ed = try editor_mod.Editor.init(allocator, io, .{});
    defer ed.deinit();

    var item = try testProposal(allocator, ".git/config", .{ .create_file = .{
        .content = try allocator.dupe(u8, "bad\n"),
    } });
    defer item.deinit(allocator);

    try std.testing.expectError(error.GitInternalsForbidden, applyProposalToEditor(&ed, &item, root));
}

test "proposal apply fails on insert mismatch" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "file.txt", .data = "current\n" });

    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);

    var ed = try editor_mod.Editor.init(allocator, io, .{});
    defer ed.deinit();

    var item = try testProposal(allocator, "file.txt", .{ .insert_at_line = .{
        .line = 1,
        .expected_before = try allocator.dupe(u8, "old\n"),
        .content = try allocator.dupe(u8, "insert\n"),
    } });
    defer item.deinit(allocator);

    try std.testing.expectError(error.HunkMismatch, applyProposalToEditor(&ed, &item, root));
}

fn testProposal(allocator: std.mem.Allocator, path: []const u8, edit: proposal_mod.ProposedEdit) !proposal_mod.PatchProposal {
    return .{
        .id = 1,
        .session_id = 1,
        .file_path = try allocator.dupe(u8, path),
        .description = try allocator.dupe(u8, "Test proposal"),
        .unified_diff = try allocator.dupe(u8, ""),
        .edit = edit,
        .status = .pending,
        .created_at_ms = 0,
        .updated_at_ms = 0,
    };
}
