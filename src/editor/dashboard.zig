const std = @import("std");
const terminal = @import("../terminal.zig");

pub const DashboardAction = enum {
    None,
    NewFile,
    OpenFile,
    OpenFolder,
    Settings,
    Quit,
};

pub const Dashboard = struct {
    selected_index: usize = 0,
    const options = [_][]const u8{ "New File", "Open File", "Open Folder", "Settings", "Quit" };

    const logo =
        \\   ___ _               _                 
        \\  / __\ | __ _ _ __ __(_)_ __   __ _ ___ 
        \\ / _\ | |/ _` | '_ ` _ \ | '_ \ / _` / __|
        \\/ /   | | (_| | | | | | | | | | (_| \__ \
        \\\/    |_|\__,_|_| |_| |_|_|_| |_|\__, |___/
        \\                                 |___/     
    ;

    pub fn moveUp(self: *Dashboard) void {
        if (self.selected_index > 0) {
            self.selected_index -= 1;
        } else {
            self.selected_index = options.len - 1;
        }
    }

    pub fn moveDown(self: *Dashboard) void {
        if (self.selected_index < options.len - 1) {
            self.selected_index += 1;
        } else {
            self.selected_index = 0;
        }
    }

    pub fn selectedAction(self: *const Dashboard) DashboardAction {
        return switch (self.selected_index) {
            0 => .NewFile,
            1 => .OpenFile,
            2 => .OpenFolder,
            3 => .Settings,
            4 => .Quit,
            else => .None,
        };
    }

    pub fn render(self: *const Dashboard, writer: anytype, width: usize, height: usize) !void {
        try terminal.clearScreen(writer);

        var lines = std.mem.splitScalar(u8, logo, '\n');
        var logo_height: usize = 0;
        var logo_width: usize = 0;
        while (lines.next()) |line| {
            logo_height += 1;
            if (line.len > logo_width) {
                logo_width = line.len;
            }
        }

        const start_y = if (height > logo_height + options.len + 4) (height - (logo_height + options.len + 4)) / 2 else 0;

        lines = std.mem.splitScalar(u8, logo, '\n');
        var y = start_y;
        while (lines.next()) |line| {
            const start_x = if (width > line.len) (width - line.len) / 2 else 0;
            try terminal.moveCursor(writer, y + 1, start_x + 1);
            try writer.writeAll("\x1b[38;5;204m"); // Flamingo pink
            try writer.writeAll(line);
            try writer.writeAll("\x1b[0m"); // Reset
            y += 1;
        }

        y += 4; // gap

        for (options, 0..) |opt, i| {
            const start_x = if (width > opt.len) (width - opt.len) / 2 else 0;
            try terminal.moveCursor(writer, y + 1, start_x + 1);

            if (i == self.selected_index) {
                try writer.writeAll("\x1b[7m"); // Invert
                try writer.print("> {s} <", .{opt});
                try writer.writeAll("\x1b[0m"); // Reset
            } else {
                try writer.print("  {s}  ", .{opt});
            }
            y += 2; // double spacing
        }
    }
};
