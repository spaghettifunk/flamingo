const std = @import("std");
const logz = @import("logz");
const terminal = @import("../terminal.zig");
const editor = @import("editor.zig");
const buffer = @import("buffer.zig");
const explorer = @import("explorer.zig");
const actions = @import("actions.zig");

fn binding(chord: []const u8) terminal.KeyEvent {
    return terminal.parseKeyChord(chord);
}

fn matches(event: terminal.KeyEvent, chord: []const u8) bool {
    return event.eql(binding(chord));
}

fn matchesMovement(event: terminal.KeyEvent, chord: []const u8) bool {
    if (matches(event, chord)) return true;

    // Shift extends a selection while preserving the underlying movement key.
    var without_shift = event;
    without_shift.shift = false;
    return event.shift and without_shift.eql(binding(chord));
}

pub fn handleInput(ed: *editor.Editor, event: terminal.KeyEvent) !void {
    if (ed.error_message != null) {
        ed.error_message = null;
    }

    const keys = ed.config.keybindings;

    if (matches(event, keys.toggle_explorer)) {
        if (ed.tree == null) {
            ed.tree = explorer.Explorer.init(ed.allocator, ed.io, ".") catch null;
        }
        ed.explorer_visible = !ed.explorer_visible;
        if (ed.explorer_visible) {
            ed.explorer_focused = true;
        } else {
            ed.explorer_focused = false;
        }
        return;
    }

    if (matches(event, keys.close_tab)) {
        if (ed.mode != .Dashboard) {
            ed.closeTab();
        }
        return;
    }

    if (matches(event, keys.switch_focus)) {
        if (ed.explorer_visible) {
            ed.explorer_focused = !ed.explorer_focused;
        }
        return;
    }

    if (matches(event, keys.next_tab)) {
        ed.nextTab();
        return;
    }

    if (matches(event, keys.previous_tab)) {
        ed.prevTab();
        return;
    }

    // --- Global Actions (Normal & Insert) ---
    if (ed.mode == .Normal or ed.mode == .Insert) {
        if (matches(event, keys.select_all)) {
            actions.selectAll(ed);
            return;
        }
        if (matches(event, keys.copy)) {
            try actions.copy(ed);
            return;
        }
        if (matches(event, keys.cut)) {
            try actions.cut(ed);
            return;
        }
        if (matches(event, keys.paste)) {
            try actions.paste(ed);
            return;
        }
        if (matches(event, keys.save)) {
            if (ed.currentTab()) |tab| {
                if (tab.buf.filename) |f| {
                    try tab.buf.saveToFile(ed.io, f);
                }
            }
            return;
        }
        if (matches(event, keys.duplicate_line)) {
            try actions.duplicateLine(ed);
            return;
        }
        if (matches(event, keys.delete_line)) {
            try actions.deleteLine(ed);
            return;
        }
        if (matches(event, keys.add_cursor_above)) {
            try actions.addCursorAbove(ed);
            return;
        }
        if (matches(event, keys.add_cursor_below)) {
            try actions.addCursorBelow(ed);
            return;
        }
        if (matches(event, keys.normal_mode)) {
            actions.clearSelections(ed);
            if (ed.mode == .Insert) ed.mode = .Normal;
            return;
        }
    }

    if (ed.explorer_focused and ed.explorer_visible and ed.tree != null) {
        if (ed.mode == .Normal or ed.mode == .Insert) {
            if (matches(event, keys.explorer_up)) {
                ed.tree.?.moveUp();
                return;
            } else if (matches(event, keys.explorer_down)) {
                ed.tree.?.moveDown();
                return;
            } else if (matches(event, keys.explorer_open)) {
                if (ed.tree.?.nodes.items.len > 0) {
                    const node = ed.tree.?.nodes.items[ed.tree.?.selected_index];
                    if (node.is_dir) {
                        ed.tree.?.toggleExpand() catch {};
                    } else {
                        if (buffer.Buffer.loadFromFile(ed.allocator, ed.io, node.absolute_path)) |b| {
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
            const action =
                if (matches(event, keys.new_file))
                    .NewFile
                else if (matches(event, keys.open_file))
                    .OpenFile
                else if (matches(event, keys.open_folder))
                    .OpenFolder
                else if (matches(event, keys.settings))
                    .Settings
                else if (matches(event, keys.quit))
                    .Quit
                else if (matches(event, keys.dashboard_up)) blk: {
                    ed.dash.moveUp();
                    break :blk .None;
                } else if (matches(event, keys.dashboard_down)) blk: {
                    ed.dash.moveDown();
                    break :blk .None;
                } else if (matches(event, keys.dashboard_select))
                    ed.dash.selectedAction()
                else
                    .None;

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
                    ed.tree = explorer.Explorer.init(ed.allocator, ed.io, ".") catch |err| {
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
            } else if (matches(event, keys.insert_mode)) {
                ed.mode = .Insert;
            } else if (matches(event, keys.command_mode)) {
                ed.mode = .Command;
                ed.command_buffer.clearRetainingCapacity();
            } else if (matches(event, keys.search_mode)) {
                ed.mode = .Search;
                ed.search_buffer.clearRetainingCapacity();
                if (ed.search_system) |*s| s.clear();
            }

            // Keep cursor within line bounds
            if (ed.currentTab()) |tab| {
                const mc = tab.mainCursor();
                if (mc.row >= tab.buf.lines.items.len) {
                    mc.row = tab.buf.lines.items.len - 1;
                }
                const line = tab.buf.lines.items[mc.row];
                const len = line.len();
                if (mc.col > len) {
                    mc.col = len;
                }
            }
        },
        .Insert => {
            if (try handleMovement(ed, event)) {
                // Handled
            } else if (matches(event, keys.normal_mode)) {
                ed.mode = .Normal;
            } else if (matches(event, keys.insert_newline)) {
                if (ed.currentTab()) |tab| {
                    const mc = tab.mainCursor();
                    try tab.buf.insertNewline(mc.row, mc.col);
                    mc.row += 1;
                    mc.col = 0;
                }
            } else if (matches(event, keys.delete_back)) {
                if (ed.currentTab()) |tab| {
                    const mc = tab.mainCursor();
                    const row = mc.row;
                    var prev_len: usize = 0;
                    if (row > 0) {
                        prev_len = tab.buf.lines.items[row - 1].len();
                    }

                    if (try tab.buf.deleteCharBack(mc.row, mc.col)) {
                        mc.row -= 1;
                        mc.col = prev_len;
                    } else {
                        if (mc.col > 0) mc.col -= 1;
                    }
                }
            } else if (event.key == .Char and !event.ctrl and !event.alt) {
                if (ed.currentTab()) |tab| {
                    const mc = tab.mainCursor();
                    if (matches(event, keys.indent)) {
                        for (0..4) |_| {
                            try tab.buf.insertChar(mc.row, mc.col, ' ');
                            mc.col += 1;
                        }
                    } else {
                        try tab.buf.insertChar(mc.row, mc.col, event.char);
                        mc.col += 1;
                    }
                }
            }
        },
        .Command => {
            if (matches(event, keys.normal_mode)) {
                ed.mode = .Normal;
            } else if (matches(event, keys.prompt_backspace)) {
                if (ed.command_buffer.items.len > 0) {
                    ed.command_buffer.shrinkRetainingCapacity(ed.command_buffer.items.len - 1);
                }
            } else if (matches(event, keys.prompt_submit)) {
                const command = @import("command.zig");
                try command.execute(ed);
            } else if (event.key == .Char and !event.ctrl and !event.alt) {
                try ed.command_buffer.append(ed.allocator, event.char);
            }
        },
        .OpenFilePrompt => {
            if (matches(event, keys.normal_mode)) {
                ed.mode = .Dashboard;
            } else if (matches(event, keys.prompt_backspace)) {
                if (ed.command_buffer.items.len > 0) {
                    ed.command_buffer.shrinkRetainingCapacity(ed.command_buffer.items.len - 1);
                }
            } else if (matches(event, keys.prompt_submit)) {
                if (ed.command_buffer.items.len > 0) {
                    if (buffer.Buffer.loadFromFile(ed.allocator, ed.io, ed.command_buffer.items)) |b| {
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
            if (matches(event, keys.normal_mode)) {
                ed.mode = .Normal;
                if (ed.search_system) |*s| s.clear();
                ed.search_buffer.clearRetainingCapacity();
            } else if (matches(event, keys.prompt_backspace)) {
                if (ed.search_buffer.items.len > 0) {
                    ed.search_buffer.shrinkRetainingCapacity(ed.search_buffer.items.len - 1);
                    if (ed.currentTab()) |tab| {
                        try ed.search_system.?.update(&tab.buf, ed.search_buffer.items);
                        if (ed.search_system.?.getActiveMatch()) |m| {
                            const mc = tab.mainCursor();
                            mc.row = m.row;
                            mc.col = m.col;
                            ed.clampScroll();
                        }
                    }
                }
            } else if (matches(event, keys.prompt_submit)) {
                ed.mode = .Normal;
                if (ed.search_system) |*s| s.clear();
                ed.search_buffer.clearRetainingCapacity();
            } else if (matches(event, keys.search_next)) {
                if (ed.search_system) |*s| {
                    s.nextMatch();
                    if (s.getActiveMatch()) |m| {
                        if (ed.currentTab()) |tab| {
                            const mc = tab.mainCursor();
                            mc.row = m.row;
                            mc.col = m.col;
                            ed.clampScroll();
                        }
                    }
                }
            } else if (matches(event, keys.search_previous)) {
                if (ed.search_system) |*s| {
                    s.prevMatch();
                    if (s.getActiveMatch()) |m| {
                        if (ed.currentTab()) |tab| {
                            const mc = tab.mainCursor();
                            mc.row = m.row;
                            mc.col = m.col;
                            ed.clampScroll();
                        }
                    }
                }
            } else if (event.key == .Char and !event.ctrl and !event.alt) {
                try ed.search_buffer.append(ed.allocator, event.char);
                if (ed.currentTab()) |tab| {
                    try ed.search_system.?.update(&tab.buf, ed.search_buffer.items);
                    if (ed.search_system.?.getActiveMatch()) |m| {
                        const mc = tab.mainCursor();
                        mc.row = m.row;
                        mc.col = m.col;
                        ed.clampScroll();
                    }
                }
            }
        },
    }
}

pub fn handleMovement(ed: *editor.Editor, event: terminal.KeyEvent) !bool {
    const tab = ed.currentTab() orelse return false;
    const keys = ed.config.keybindings;

    // Multi-cursor support: apply movement to all cursors
    var handled = false;
    for (tab.cursors.items) |*cursor| {
        if (event.shift) {
            if (cursor.selection_start == null) {
                cursor.selection_start = .{ .row = cursor.row, .col = cursor.col };
            }
        } else if (!event.ctrl and !event.alt) {
            // Only clear selection on plain arrows (no modifiers, except shift which extends)
            cursor.selection_start = null;
        }

        if (matchesMovement(event, keys.line_end)) {
            cursor.col = tab.buf.lines.items[cursor.row].len();
            handled = true;
        } else if (matchesMovement(event, keys.line_start)) {
            cursor.col = 0;
            handled = true;
        } else if (matchesMovement(event, keys.word_left)) {
            try tab.buf.jumpWordLeft(&cursor.row, &cursor.col);
            handled = true;
        } else if (matchesMovement(event, keys.word_right)) {
            try tab.buf.jumpWordRight(&cursor.row, &cursor.col);
            handled = true;
        } else if (matchesMovement(event, keys.move_up)) {
            if (cursor.row > 0) cursor.row -= 1;
            const new_line_len = tab.buf.lines.items[cursor.row].len();
            if (cursor.col > new_line_len) cursor.col = new_line_len;
            handled = true;
        } else if (matchesMovement(event, keys.move_down)) {
            if (cursor.row < tab.buf.lines.items.len - 1) cursor.row += 1;
            const new_line_len = tab.buf.lines.items[cursor.row].len();
            if (cursor.col > new_line_len) cursor.col = new_line_len;
            handled = true;
        } else if (matchesMovement(event, keys.move_left)) {
            if (cursor.col > 0) cursor.col -= 1;
            handled = true;
        } else if (matchesMovement(event, keys.move_right)) {
            const line = tab.buf.lines.items[cursor.row];
            if (cursor.col < line.len()) cursor.col += 1;
            handled = true;
        }
    }

    if (handled) ed.clampScroll();
    return handled;
}
