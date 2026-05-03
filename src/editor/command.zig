const std = @import("std");
const editor = @import("editor.zig");
const navigation = @import("navigation.zig");

pub const Command = enum {
    quit,
    force_quit,
    write,
    write_quit,

    pub fn name(self: Command) []const u8 {
        return switch (self) {
            .quit => "q",
            .force_quit => "q!",
            .write => "w",
            .write_quit => "wq",
        };
    }

    pub fn fromString(value: []const u8) ?Command {
        for (all) |command| {
            if (std.mem.eql(u8, command.name(), value)) return command;
        }
        return null;
    }
};

pub const all = [_]Command{
    .quit,
    .force_quit,
    .write,
    .write_quit,
};

fn parseLineJump(input: []const u8) ?usize {
    if (input.len == 0) return null;
    if (std.ascii.isDigit(input[0])) {
        return std.fmt.parseInt(usize, input, 10) catch null;
    }

    var it = std.mem.splitScalar(u8, input, ' ');
    const name = it.next() orelse return null;
    if (!std.mem.eql(u8, name, "goto") and !std.mem.eql(u8, name, "line")) return null;

    const line_text = it.next() orelse return null;
    if (it.next() != null) return null;
    return std.fmt.parseInt(usize, line_text, 10) catch null;
}

pub fn execute(ed: *editor.Editor) !void {
    const command_input = if (ed.state.command_popup.visible)
        ed.state.command_popup.input.items
    else
        ed.state.command_buffer.items;
    defer if (ed.state.command_popup.visible) ed.state.command_popup.close();

    if (command_input.len == 0) {
        ed.state.mode = .Normal;
        return;
    }

    if (parseLineJump(command_input)) |line_number| {
        const row = line_number -| 1;
        const col = if (ed.currentTab()) |tab| tab.mainCursor().col else 0;
        _ = try navigation.jumpTo(ed, row, col, .{ .record_history = true });
        ed.state.mode = .Normal;
        return;
    }

    var it = std.mem.splitScalar(u8, command_input, ' ');
    const cmd = it.next() orelse return;
    const command = Command.fromString(cmd) orelse {
        ed.state.error_message = "Not an editor command";
        ed.state.mode = .Normal;
        return;
    };

    switch (command) {
        .quit => {
            if (ed.currentTab()) |tab| {
                if (tab.buf.is_dirty) {
                    ed.state.error_message = "No write since last change (add ! to override)";
                    ed.state.mode = .Normal;
                    return;
                }
            }
            ed.closeTab();
        },
        .force_quit => {
            ed.closeTab();
        },
        .write => {
            const filename = it.next();
            if (ed.currentTab()) |tab| {
                if (filename) |f| {
                    try tab.buf.setFilename(f);
                }
                if (tab.buf.filename) |f| {
                    tab.buf.saveToFile(ed.io, f) catch {
                        ed.state.error_message = "Failed to save file";
                    };
                } else {
                    ed.state.error_message = "No file name";
                }
            }
            ed.state.mode = .Normal;
        },
        .write_quit => {
            const filename = it.next();
            if (ed.currentTab()) |tab| {
                if (filename) |f| {
                    try tab.buf.setFilename(f);
                }
                if (tab.buf.filename) |f| {
                    tab.buf.saveToFile(ed.io, f) catch {
                        ed.state.error_message = "Failed to save file";
                        ed.state.mode = .Normal;
                        return;
                    };
                    ed.closeTab();
                } else {
                    ed.state.error_message = "No file name";
                    ed.state.mode = .Normal;
                }
            } else {
                ed.closeTab();
            }
        },
    }
}

test "Command registry parses command names" {
    try std.testing.expectEqual(Command.quit, Command.fromString("q").?);
    try std.testing.expectEqual(Command.force_quit, Command.fromString("q!").?);
    try std.testing.expectEqual(Command.write, Command.fromString("w").?);
    try std.testing.expectEqual(Command.write_quit, Command.fromString("wq").?);
    try std.testing.expect(Command.fromString("nope") == null);
}
