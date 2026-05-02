const std = @import("std");
const editor = @import("editor.zig");

pub fn execute(ed: *editor.Editor) !void {
    if (ed.state.command_buffer.items.len == 0) {
        ed.state.mode = .Normal;
        return;
    }

    var it = std.mem.splitScalar(u8, ed.state.command_buffer.items, ' ');
    const cmd = it.next() orelse return;

    if (std.mem.eql(u8, cmd, "q")) {
        if (ed.currentTab()) |tab| {
            if (tab.buf.is_dirty) {
                ed.state.error_message = "No write since last change (add ! to override)";
                ed.state.mode = .Normal;
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
                    ed.state.error_message = "Failed to save file";
                };
            } else {
                ed.state.error_message = "No file name";
            }
        }
        ed.state.mode = .Normal;
    } else if (std.mem.eql(u8, cmd, "wq")) {
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
    } else {
        ed.state.error_message = "Not an editor command";
        ed.state.mode = .Normal;
    }
}
