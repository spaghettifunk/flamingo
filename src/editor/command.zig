const std = @import("std");
const editor = @import("editor.zig");

pub fn execute(ed: *editor.Editor) !void {
    if (ed.command_buffer.items.len == 0) {
        ed.mode = .Normal;
        return;
    }

    var it = std.mem.splitScalar(u8, ed.command_buffer.items, ' ');
    const cmd = it.next() orelse return;

    if (std.mem.eql(u8, cmd, "q")) {
        if (ed.currentTab()) |tab| {
            if (tab.buf.is_dirty) {
                ed.error_message = "No write since last change (add ! to override)";
                ed.mode = .Normal;
                return;
            }
        }
        ed.closeTab();
    } else if (std.mem.eql(u8, cmd, "q!")) {
        ed.closeTab();
    } else if (std.mem.eql(u8, cmd, "w")) {
        const filename = it.next();
        if (ed.currentTab()) |tab| {
            if (filename) |f| {
                try tab.buf.setFilename(f);
            }
            if (tab.buf.filename) |f| {
                tab.buf.saveToFile(ed.io, f) catch {
                    ed.error_message = "Failed to save file";
                };
            } else {
                ed.error_message = "No file name";
            }
        }
        ed.mode = .Normal;
    } else if (std.mem.eql(u8, cmd, "wq")) {
        const filename = it.next();
        if (ed.currentTab()) |tab| {
            if (filename) |f| {
                try tab.buf.setFilename(f);
            }
            if (tab.buf.filename) |f| {
                tab.buf.saveToFile(ed.io, f) catch {
                    ed.error_message = "Failed to save file";
                    ed.mode = .Normal;
                    return;
                };
                ed.closeTab();
            } else {
                ed.error_message = "No file name";
                ed.mode = .Normal;
            }
        } else {
            ed.closeTab();
        }
    } else {
        ed.error_message = "Not an editor command";
        ed.mode = .Normal;
    }
}
