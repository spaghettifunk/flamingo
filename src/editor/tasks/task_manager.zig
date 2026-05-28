const std = @import("std");
const task_mod = @import("task.zig");
const command_parser = @import("command_parser.zig");

pub const TaskManager = struct {
    allocator: std.mem.Allocator,
    tasks: std.ArrayListUnmanaged(task_mod.Task) = .empty,
    next_id: u64 = 1,
    selected_index: usize = 0,
    output_scroll: usize = 0,
    visible: bool = false,
    running_task_id: ?u64 = null,

    pub fn init(allocator: std.mem.Allocator) TaskManager {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *TaskManager) void {
        for (self.tasks.items) |*task| task.deinit(self.allocator);
        self.tasks.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn open(self: *TaskManager) void {
        self.visible = true;
        self.selectLatest();
    }

    pub fn close(self: *TaskManager) void {
        self.visible = false;
    }

    pub fn addQueuedTask(self: *TaskManager, parsed: command_parser.ParsedCommand, cwd: []const u8, now_ms: i64) !u64 {
        const id = self.next_id;
        self.next_id +%= 1;
        const name = try self.allocator.dupe(u8, std.fs.path.basename(parsed.argv[0]));
        errdefer self.allocator.free(name);
        const cwd_owned = try self.allocator.dupe(u8, cwd);
        errdefer self.allocator.free(cwd_owned);

        try self.tasks.append(self.allocator, .{
            .id = id,
            .name = name,
            .command_display = parsed.display,
            .argv = parsed.argv,
            .cwd = cwd_owned,
            .started_at_ms = now_ms,
        });
        self.selected_index = self.tasks.items.len - 1;
        self.output_scroll = 0;
        return id;
    }

    pub fn markStarted(self: *TaskManager, id: u64, now_ms: i64) void {
        const task = self.findTask(id) orelse return;
        task.status = .running;
        task.started_at_ms = now_ms;
        self.running_task_id = id;
    }

    pub fn appendOutput(self: *TaskManager, id: u64, kind: task_mod.TaskOutputKind, bytes: []const u8) !void {
        const task = self.findTask(id) orelse return;
        try task.appendOutputChunk(self.allocator, kind, bytes);
    }

    pub fn finish(self: *TaskManager, id: u64, status: task_mod.TaskStatus, exit_code: ?i32, now_ms: i64) !void {
        const task = self.findTask(id) orelse return;
        try task.flushPartialOutput(self.allocator);
        task.status = status;
        task.exit_code = exit_code;
        task.finished_at_ms = now_ms;
        if (self.running_task_id == id) self.running_task_id = null;
    }

    pub fn failToStart(self: *TaskManager, id: u64, message: []const u8, now_ms: i64) !void {
        const task = self.findTask(id) orelse return;
        task.status = .failed;
        task.finished_at_ms = now_ms;
        try task.appendSystemLine(self.allocator, message);
        if (self.running_task_id == id) self.running_task_id = null;
    }

    pub fn appendSystemToSelected(self: *TaskManager, text: []const u8) !void {
        const task = self.selectedTask() orelse return;
        try task.appendSystemLine(self.allocator, text);
    }

    pub fn selectedTask(self: *TaskManager) ?*task_mod.Task {
        if (self.tasks.items.len == 0) return null;
        self.clampSelection();
        return &self.tasks.items[self.selected_index];
    }

    pub fn selectedTaskConst(self: *const TaskManager) ?*const task_mod.Task {
        if (self.tasks.items.len == 0) return null;
        const index = @min(self.selected_index, self.tasks.items.len - 1);
        return &self.tasks.items[index];
    }

    pub fn findTask(self: *TaskManager, id: u64) ?*task_mod.Task {
        for (self.tasks.items) |*task| {
            if (task.id == id) return task;
        }
        return null;
    }

    pub fn selectLatest(self: *TaskManager) void {
        if (self.tasks.items.len == 0) {
            self.selected_index = 0;
        } else {
            self.selected_index = self.tasks.items.len - 1;
        }
        self.output_scroll = 0;
    }

    pub fn selectPrevious(self: *TaskManager) void {
        if (self.tasks.items.len == 0) return;
        if (self.selected_index > 0) self.selected_index -= 1;
        self.output_scroll = 0;
    }

    pub fn selectNext(self: *TaskManager) void {
        if (self.tasks.items.len == 0) return;
        if (self.selected_index + 1 < self.tasks.items.len) self.selected_index += 1;
        self.output_scroll = 0;
    }

    pub fn scrollUp(self: *TaskManager, amount: usize) void {
        self.output_scroll = self.output_scroll -| amount;
    }

    pub fn scrollDown(self: *TaskManager, amount: usize, visible_rows: usize) void {
        const task = self.selectedTaskConst() orelse return;
        const max_scroll = task.output.items.len -| visible_rows;
        self.output_scroll = @min(self.output_scroll + amount, max_scroll);
    }

    pub fn clampScroll(self: *TaskManager, visible_rows: usize) void {
        const task = self.selectedTaskConst() orelse {
            self.output_scroll = 0;
            return;
        };
        self.output_scroll = @min(self.output_scroll, task.output.items.len -| visible_rows);
    }

    fn clampSelection(self: *TaskManager) void {
        if (self.tasks.items.len == 0) {
            self.selected_index = 0;
        } else if (self.selected_index >= self.tasks.items.len) {
            self.selected_index = self.tasks.items.len - 1;
        }
    }
};

test "task manager selects latest task" {
    const allocator = std.testing.allocator;
    var manager = TaskManager.init(allocator);
    defer manager.deinit();

    const first = try command_parser.parse(allocator, "zig build");
    _ = try manager.addQueuedTask(first, ".", 0);
    const second = try command_parser.parse(allocator, "zig build test");
    _ = try manager.addQueuedTask(second, ".", 0);

    try std.testing.expectEqual(@as(usize, 1), manager.selected_index);
    try std.testing.expectEqualStrings("zig build test", manager.selectedTaskConst().?.command_display);
}

test "task manager lifecycle transitions" {
    const allocator = std.testing.allocator;
    var manager = TaskManager.init(allocator);
    defer manager.deinit();

    const parsed = try command_parser.parse(allocator, "zig build");
    const id = try manager.addQueuedTask(parsed, ".", 0);
    try std.testing.expectEqual(task_mod.TaskStatus.queued, manager.selectedTaskConst().?.status);

    manager.markStarted(id, 10);
    try std.testing.expectEqual(task_mod.TaskStatus.running, manager.selectedTaskConst().?.status);

    try manager.appendOutput(id, .stdout, "hello\n");
    try manager.finish(id, .success, 0, 20);
    try std.testing.expectEqual(task_mod.TaskStatus.success, manager.selectedTaskConst().?.status);
    try std.testing.expectEqual(@as(i32, 0), manager.selectedTaskConst().?.exit_code.?);
    try std.testing.expectEqualStrings("hello", manager.selectedTaskConst().?.output.items[0].text);
}
