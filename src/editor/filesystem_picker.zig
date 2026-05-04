const std = @import("std");

fn realPathOwned(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    const z = try std.Io.Dir.cwd().realPathFileAlloc(io, path, allocator);
    defer allocator.free(z);
    return allocator.dupe(u8, z);
}

pub const PickerMode = enum {
    open_file,
    open_folder,
    new_file_location,
};

pub const PickerPhase = enum {
    browsing,
    entering_name,
};

pub const EntryKind = enum {
    file,
    directory,
    other,
};

pub const PickerResult = union(enum) {
    open_file: []u8,
    open_folder: []u8,
    create_file: []u8,

    pub fn deinit(self: PickerResult, allocator: std.mem.Allocator) void {
        switch (self) {
            .open_file => |path| allocator.free(path),
            .open_folder => |path| allocator.free(path),
            .create_file => |path| allocator.free(path),
        }
    }
};

pub const PickerEntry = struct {
    name: []u8,
    path: []u8,
    kind: EntryKind,
    is_parent: bool = false,

    pub fn deinit(self: *PickerEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.path);
    }
};

const SortContext = struct {
    pub fn lessThan(ctx: void, a: PickerEntry, b: PickerEntry) bool {
        _ = ctx;
        if (a.is_parent and !b.is_parent) return true;
        if (!a.is_parent and b.is_parent) return false;
        if (a.kind == .directory and b.kind != .directory) return true;
        if (a.kind != .directory and b.kind == .directory) return false;
        var i: usize = 0;
        while (i < a.name.len and i < b.name.len) : (i += 1) {
            const ca = std.ascii.toLower(a.name[i]);
            const cb = std.ascii.toLower(b.name[i]);
            if (ca < cb) return true;
            if (ca > cb) return false;
        }
        return a.name.len < b.name.len;
    }
};

pub const FilesystemPicker = struct {
    visible: bool = false,
    mode: PickerMode = .open_file,
    phase: PickerPhase = .browsing,
    cwd: []u8 = &.{},
    entries: std.ArrayListUnmanaged(PickerEntry) = .empty,
    selected_index: usize = 0,
    scroll_offset: usize = 0,
    input: std.ArrayListUnmanaged(u8) = .empty,
    error_message: ?[]const u8 = null,

    pub fn deinit(self: *FilesystemPicker, allocator: std.mem.Allocator) void {
        self.clearEntries(allocator);
        self.entries.deinit(allocator);
        self.input.deinit(allocator);
        if (self.cwd.len > 0) allocator.free(self.cwd);
        self.* = .{};
    }

    pub fn open(self: *FilesystemPicker, allocator: std.mem.Allocator, io: std.Io, mode: PickerMode, start_dir: []const u8) !void {
        self.close(allocator);
        self.visible = true;
        self.mode = mode;
        self.phase = .browsing;
        errdefer self.close(allocator);
        self.cwd = realPathOwned(allocator, io, start_dir) catch try allocator.dupe(u8, start_dir);
        try self.reload(allocator, io);
    }

    pub fn close(self: *FilesystemPicker, allocator: std.mem.Allocator) void {
        self.visible = false;
        self.phase = .browsing;
        self.mode = .open_file;
        self.clearEntries(allocator);
        self.input.clearRetainingCapacity();
        self.selected_index = 0;
        self.scroll_offset = 0;
        self.error_message = null;
        if (self.cwd.len > 0) {
            allocator.free(self.cwd);
            self.cwd = &.{};
        }
    }

    fn clearEntries(self: *FilesystemPicker, allocator: std.mem.Allocator) void {
        for (self.entries.items) |*entry| entry.deinit(allocator);
        self.entries.clearRetainingCapacity();
    }

    fn shouldSkipEntry(name: []const u8) bool {
        return std.mem.eql(u8, name, ".") or
            std.mem.eql(u8, name, "..") or
            std.mem.eql(u8, name, ".git") or
            std.mem.eql(u8, name, ".zig-cache") or
            std.mem.eql(u8, name, "zig-out");
    }

    pub fn reload(self: *FilesystemPicker, allocator: std.mem.Allocator, io: std.Io) !void {
        self.clearEntries(allocator);
        var dir = try std.Io.Dir.cwd().openDir(io, self.cwd, .{ .iterate = true });
        defer dir.close(io);

        if (std.fs.path.dirname(self.cwd)) |parent| {
            if (!std.mem.eql(u8, parent, self.cwd)) {
                const parent_path = realPathOwned(allocator, io, parent) catch try allocator.dupe(u8, parent);
                errdefer allocator.free(parent_path);
                const parent_name = try allocator.dupe(u8, "../");
                errdefer allocator.free(parent_name);
                try self.entries.append(allocator, .{
                    .name = parent_name,
                    .path = parent_path,
                    .kind = .directory,
                    .is_parent = true,
                });
            }
        }

        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (shouldSkipEntry(entry.name)) continue;
            const path = try std.fs.path.join(allocator, &.{ self.cwd, entry.name });
            errdefer allocator.free(path);
            const name = try allocator.dupe(u8, entry.name);
            errdefer allocator.free(name);
            try self.entries.append(allocator, .{
                .name = name,
                .path = path,
                .kind = switch (entry.kind) {
                    .directory => .directory,
                    .file => .file,
                    else => .other,
                },
            });
        }

        std.mem.sort(PickerEntry, self.entries.items, {}, SortContext.lessThan);
        self.selected_index = 0;
        self.scroll_offset = 0;
    }

    pub fn moveUp(self: *FilesystemPicker) void {
        if (self.phase != .browsing) return;
        if (self.entries.items.len == 0) return;
        self.selected_index = if (self.selected_index == 0) self.entries.items.len - 1 else self.selected_index - 1;
    }

    pub fn moveDown(self: *FilesystemPicker) void {
        if (self.phase != .browsing) return;
        if (self.entries.items.len == 0) return;
        self.selected_index = (self.selected_index + 1) % self.entries.items.len;
    }

    pub fn backspace(self: *FilesystemPicker, allocator: std.mem.Allocator, io: std.Io) !void {
        self.error_message = null;
        if (self.phase == .entering_name) {
            if (self.input.items.len > 0) self.input.shrinkRetainingCapacity(self.input.items.len - 1);
            return;
        }
        const parent = std.fs.path.dirname(self.cwd) orelse return;
        try self.changeDir(allocator, io, parent);
    }

    pub fn appendChar(self: *FilesystemPicker, allocator: std.mem.Allocator, ch: u8) !void {
        if (self.phase != .entering_name) return;
        try self.input.append(allocator, ch);
        self.error_message = null;
    }

    pub fn beginNameInput(self: *FilesystemPicker) void {
        self.phase = .entering_name;
        self.input.clearRetainingCapacity();
        self.error_message = null;
    }

    pub fn changeDir(self: *FilesystemPicker, allocator: std.mem.Allocator, io: std.Io, path: []const u8) !void {
        const owned = realPathOwned(allocator, io, path) catch try allocator.dupe(u8, path);
        if (self.cwd.len > 0) allocator.free(self.cwd);
        self.cwd = owned;
        self.phase = .browsing;
        self.input.clearRetainingCapacity();
        try self.reload(allocator, io);
    }

    pub fn selectedEntry(self: *FilesystemPicker) ?*PickerEntry {
        if (self.entries.items.len == 0) return null;
        if (self.selected_index >= self.entries.items.len) return null;
        return &self.entries.items[self.selected_index];
    }

    pub fn accept(self: *FilesystemPicker, allocator: std.mem.Allocator, io: std.Io) !?PickerResult {
        self.error_message = null;
        if (self.mode == .new_file_location) {
            if (self.phase == .browsing) {
                if (self.selectedEntry()) |entry| {
                    if (entry.kind == .directory) {
                        try self.changeDir(allocator, io, entry.path);
                        return null;
                    }
                }
                self.beginNameInput();
                return null;
            }
            if (self.input.items.len == 0) {
                self.error_message = "Enter a file name";
                return null;
            }
            const path = try std.fs.path.join(allocator, &.{ self.cwd, self.input.items });
            return .{ .create_file = path };
        }

        const entry = self.selectedEntry() orelse {
            if (self.mode == .open_folder) return .{ .open_folder = try allocator.dupe(u8, self.cwd) };
            return null;
        };
        if (entry.kind == .directory) {
            try self.changeDir(allocator, io, entry.path);
            return null;
        }
        if (self.mode == .open_file and entry.kind == .file) {
            return .{ .open_file = try allocator.dupe(u8, entry.path) };
        }
        self.error_message = switch (self.mode) {
            .open_folder => "Select a folder",
            else => "Select a file",
        };
        return null;
    }

    pub fn selectFolder(self: *FilesystemPicker, allocator: std.mem.Allocator) !?PickerResult {
        if (self.mode != .open_folder) return null;
        const entry = self.selectedEntry();
        if (entry) |e| {
            if (e.kind == .directory) return .{ .open_folder = try allocator.dupe(u8, e.path) };
            self.error_message = "Select a folder";
            return null;
        }
        return .{ .open_folder = try allocator.dupe(u8, self.cwd) };
    }
};

test "filesystem picker changes directory and creates result path" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "src");

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = path_buf[0..try tmp.dir.realPath(io, &path_buf)];

    var picker = FilesystemPicker{};
    defer picker.deinit(allocator);
    try picker.open(allocator, io, .new_file_location, root);
    try std.testing.expectEqual(PickerMode.new_file_location, picker.mode);
    try std.testing.expect(picker.entries.items.len >= 1);

    picker.beginNameInput();
    try std.testing.expectEqual(PickerPhase.entering_name, picker.phase);
    for ("main.zig") |ch| try picker.appendChar(allocator, ch);
    const result = (try picker.accept(allocator, io)).?;
    defer result.deinit(allocator);
    switch (result) {
        .create_file => |path| try std.testing.expect(std.mem.endsWith(u8, path, "main.zig")),
        else => return error.UnexpectedResult,
    }
}

test "filesystem picker exposes parent directory entry" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "nested");

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = path_buf[0..try tmp.dir.realPath(io, &path_buf)];
    const nested = try std.fs.path.join(allocator, &.{ root, "nested" });
    defer allocator.free(nested);

    var picker = FilesystemPicker{};
    defer picker.deinit(allocator);
    try picker.open(allocator, io, .open_file, nested);

    const first = picker.selectedEntry() orelse return error.MissingParentEntry;
    try std.testing.expect(first.is_parent);
    try std.testing.expectEqualStrings("../", first.name);

    _ = try picker.accept(allocator, io);
    try std.testing.expectEqualStrings(root, picker.cwd);
}

test "open folder mode reports folder-specific error on file" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "file.txt", .data = "" });

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = path_buf[0..try tmp.dir.realPath(io, &path_buf)];

    var picker = FilesystemPicker{};
    defer picker.deinit(allocator);
    try picker.open(allocator, io, .open_folder, root);

    for (picker.entries.items, 0..) |entry, i| {
        if (std.mem.eql(u8, entry.name, "file.txt")) {
            picker.selected_index = i;
            break;
        }
    }

    try std.testing.expect((try picker.accept(allocator, io)) == null);
    try std.testing.expectEqualStrings("Select a folder", picker.error_message.?);
}
