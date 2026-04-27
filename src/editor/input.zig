const std = @import("std");
const logz = @import("logz");
const terminal = @import("../terminal.zig");
const editor = @import("editor.zig");
const buffer = @import("buffer.zig");
const explorer = @import("explorer.zig");

pub fn handleInput(ed: *editor.Editor, event: terminal.KeyEvent) !void {
    if (ed.error_message != null) {
        ed.error_message = null;
    }

    const switch_focus_key = terminal.parseKeyChord(ed.config.keybindings.switch_focus);
    const is_ctrl_e = event.ctrl and event.key == .Char and event.char == 'e';
    const is_ctrl_w = event.ctrl and event.key == .Char and event.char == 'w';
    const is_alt_open_bracket = event.alt and event.key == .Char and event.char == '[';
    const is_alt_close_bracket = event.alt and event.key == .Char and event.char == ']';

    if (is_ctrl_e) {
        if (ed.tree == null) {
            ed.tree = explorer.Explorer.init(ed.allocator, ".") catch null;
        }
        ed.explorer_visible = !ed.explorer_visible;
        if (ed.explorer_visible) {
            ed.explorer_focused = true;
        } else {
            ed.explorer_focused = false;
        }
        return;
    }

    const is_tab = event.key == .Char and event.char == '\t';
    if (event.eql(switch_focus_key) or (is_tab and std.mem.eql(u8, ed.config.keybindings.switch_focus, "ctrl+tab"))) {
        if (ed.explorer_visible) {
            ed.explorer_focused = !ed.explorer_focused;
        }
        return;
    }

    if (is_ctrl_w) {
        if (ed.mode != .Dashboard) {
            ed.closeTab();
        }
        return;
    }

    if (is_alt_open_bracket) {
        ed.nextTab();
        return;
    }

    if (is_alt_close_bracket) {
        ed.prevTab();
        return;
    }

    if (ed.explorer_focused and ed.explorer_visible and ed.tree != null) {
        if (ed.mode == .Normal or ed.mode == .Insert) {
            if (event.key == .Up) {
                ed.tree.?.moveUp();
                return;
            } else if (event.key == .Down) {
                ed.tree.?.moveDown();
                return;
            } else if (event.key == .Enter) {
                if (ed.tree.?.nodes.items.len > 0) {
                    const node = ed.tree.?.nodes.items[ed.tree.?.selected_index];
                    if (node.is_dir) {
                        ed.tree.?.toggleExpand() catch {};
                    } else {
                        if (buffer.Buffer.loadFromFile(ed.allocator, node.absolute_path)) |b| {
                            try ed.addTab(b);
                            ed.explorer_focused = false;
                            ed.mode = .Normal;
                        } else |err| {
                            logz.err().fmt("msg", "failed to open file {s}: {s}", .{ node.absolute_path, @errorName(err) }).log();
                            ed.error_message = "Could not open file";
                        }
                    }
                }
                return;
            }
        }
    }

    switch (ed.mode) {
        .Dashboard => {
            const action = ed.dash.handleInput(event);
            switch (action) {
                .NewFile => {
                    ed.mode = .Normal;
                    try ed.addTab(try buffer.Buffer.init(ed.allocator));
                },
                .OpenFile => {
                    ed.mode = .OpenFilePrompt;
                    ed.command_buffer.clearRetainingCapacity();
                },
                .OpenFolder => {
                    logz.info().string("msg", "action: OpenFolder").log();
                    ed.closeAllTabs();
                    ed.mode = .Normal;
                    if (ed.tree) |*t| {
                        t.deinit();
                    }
                    ed.tree = explorer.Explorer.init(ed.allocator, ".") catch |err| {
                        logz.err().fmt("msg", "failed to init explorer: {s}", .{@errorName(err)}).log();
                        return;
                    };
                    ed.explorer_visible = ed.tree != null;
                    ed.explorer_focused = ed.tree != null;
                },
                .Quit => ed.should_quit = true,
                else => {},
            }
        },
        .Normal => {
            if (try handleMovement(ed, event)) {
                // Handled
            } else if (event.key == .Char and event.char == 'i') {
                ed.mode = .Insert;
            } else if (event.key == .Char and event.char == ':') {
                ed.mode = .Command;
                ed.command_buffer.clearRetainingCapacity();
            } else if (event.key == .Char and event.char == '/') {
                ed.mode = .Search;
                ed.search_buffer.clearRetainingCapacity();
                if (ed.search_system) |*s| s.clear();
            }

            // Keep cursor within line bounds
            if (ed.currentTab()) |tab| {
                if (tab.cursor_row >= tab.buf.lines.items.len) {
                    tab.cursor_row = tab.buf.lines.items.len - 1;
                }
                const line = tab.buf.lines.items[tab.cursor_row];
                const len = line.len();
                if (tab.cursor_col > len) {
                    tab.cursor_col = len;
                }
            }
        },
        .Insert => {
            if (try handleMovement(ed, event)) {
                // Handled
            } else if (event.key == .Esc) {
                ed.mode = .Normal;
            } else if (event.key == .Enter) {
                if (ed.currentTab()) |tab| {
                    try tab.buf.insertNewline(tab.cursor_row, tab.cursor_col);
                    tab.cursor_row += 1;
                    tab.cursor_col = 0;
                }
            } else if (event.key == .Backspace) {
                if (ed.currentTab()) |tab| {
                    const row = tab.cursor_row;
                    var prev_len: usize = 0;
                    if (row > 0) {
                        prev_len = tab.buf.lines.items[row - 1].len();
                    }

                    if (try tab.buf.deleteCharBack(tab.cursor_row, tab.cursor_col)) {
                        tab.cursor_row -= 1;
                        tab.cursor_col = prev_len;
                    } else {
                        if (tab.cursor_col > 0) tab.cursor_col -= 1;
                    }
                }
            } else if (event.key == .Char and !event.ctrl and !event.alt) {
                if (ed.currentTab()) |tab| {
                    if (event.char == '\t') {
                        for (0..4) |_| {
                            try tab.buf.insertChar(tab.cursor_row, tab.cursor_col, ' ');
                            tab.cursor_col += 1;
                        }
                    } else {
                        try tab.buf.insertChar(tab.cursor_row, tab.cursor_col, event.char);
                        tab.cursor_col += 1;
                    }
                }
            }
        },
        .Command => {
            if (event.key == .Esc) {
                ed.mode = .Normal;
            } else if (event.key == .Backspace) {
                if (ed.command_buffer.items.len > 0) {
                    ed.command_buffer.shrinkRetainingCapacity(ed.command_buffer.items.len - 1);
                }
            } else if (event.key == .Enter) {
                const command = @import("command.zig");
                try command.execute(ed);
            } else if (event.key == .Char and !event.ctrl and !event.alt) {
                try ed.command_buffer.append(ed.allocator, event.char);
            }
        },
        .OpenFilePrompt => {
            if (event.key == .Esc) {
                ed.mode = .Dashboard;
            } else if (event.key == .Backspace) {
                if (ed.command_buffer.items.len > 0) {
                    ed.command_buffer.shrinkRetainingCapacity(ed.command_buffer.items.len - 1);
                }
            } else if (event.key == .Enter) {
                if (ed.command_buffer.items.len > 0) {
                    if (buffer.Buffer.loadFromFile(ed.allocator, ed.command_buffer.items)) |b| {
                        try ed.addTab(b);
                        ed.mode = .Normal;
                    } else |_| {
                        ed.error_message = "Could not open file";
                        ed.mode = .Dashboard;
                    }
                } else {
                    ed.mode = .Dashboard;
                }
            } else if (event.key == .Char and !event.ctrl and !event.alt) {
                try ed.command_buffer.append(ed.allocator, event.char);
            }
        },
        .Search => {
            if (event.key == .Esc) {
                ed.mode = .Normal;
                if (ed.search_system) |*s| s.clear();
                ed.search_buffer.clearRetainingCapacity();
            } else if (event.key == .Backspace) {
                if (ed.search_buffer.items.len > 0) {
                    ed.search_buffer.shrinkRetainingCapacity(ed.search_buffer.items.len - 1);
                    if (ed.currentTab()) |tab| {
                        try ed.search_system.?.update(&tab.buf, ed.search_buffer.items);
                        if (ed.search_system.?.getActiveMatch()) |m| {
                            tab.cursor_row = m.row;
                            tab.cursor_col = m.col;
                            ed.clampScroll();
                        }
                    }
                }
            } else if (event.key == .Enter) {
                ed.mode = .Normal;
                if (ed.search_system) |*s| s.clear();
                ed.search_buffer.clearRetainingCapacity();
            } else if (event.key == .Down) {
                if (ed.search_system) |*s| {
                    s.nextMatch();
                    if (s.getActiveMatch()) |m| {
                        if (ed.currentTab()) |tab| {
                            tab.cursor_row = m.row;
                            tab.cursor_col = m.col;
                            ed.clampScroll();
                        }
                    }
                }
            } else if (event.key == .Up) {
                if (ed.search_system) |*s| {
                    s.prevMatch();
                    if (s.getActiveMatch()) |m| {
                        if (ed.currentTab()) |tab| {
                            tab.cursor_row = m.row;
                            tab.cursor_col = m.col;
                            ed.clampScroll();
                        }
                    }
                }
            } else if (event.key == .Char and !event.ctrl and !event.alt) {
                try ed.search_buffer.append(ed.allocator, event.char);
                if (ed.currentTab()) |tab| {
                    try ed.search_system.?.update(&tab.buf, ed.search_buffer.items);
                    if (ed.search_system.?.getActiveMatch()) |m| {
                        tab.cursor_row = m.row;
                        tab.cursor_col = m.col;
                        ed.clampScroll();
                    }
                }
            }
        },
    }
}

pub fn handleMovement(ed: *editor.Editor, event: terminal.KeyEvent) !bool {
    const tab = ed.currentTab() orelse return false;

    if (event.key == .Up) {
        if (event.alt) {
            tab.cursor_col = tab.buf.lines.items[tab.cursor_row].len();
        } else {
            if (tab.cursor_row > 0) tab.cursor_row -= 1;
            // Clamp col to the new line's length after vertical movement
            const new_line_len = tab.buf.lines.items[tab.cursor_row].len();
            if (tab.cursor_col > new_line_len) tab.cursor_col = new_line_len;
        }
        ed.clampScroll();
        return true;
    } else if (event.key == .Down) {
        if (event.alt) {
            tab.cursor_col = 0;
        } else {
            if (tab.cursor_row < tab.buf.lines.items.len - 1) tab.cursor_row += 1;
            // Clamp col to the new line's length after vertical movement
            const new_line_len = tab.buf.lines.items[tab.cursor_row].len();
            if (tab.cursor_col > new_line_len) tab.cursor_col = new_line_len;
        }
        ed.clampScroll();
        return true;
    } else if (event.key == .Left) {
        if (event.alt) {
            try tab.buf.jumpWordLeft(&tab.cursor_row, &tab.cursor_col);
        } else {
            if (tab.cursor_col > 0) tab.cursor_col -= 1;
        }
        return true;
    } else if (event.key == .Right) {
        if (event.alt) {
            try tab.buf.jumpWordRight(&tab.cursor_row, &tab.cursor_col);
        } else {
            const line = tab.buf.lines.items[tab.cursor_row];
            if (tab.cursor_col < line.len()) tab.cursor_col += 1;
        }
        return true;
    }
    return false;
}
