const std = @import("std");
const logz = @import("logz");
const terminal = @import("../../terminal.zig");
const buffer = @import("../model/buffer.zig");
const commands = @import("../commands.zig");
const command_keybindings = @import("../keybindings.zig");
const jump_history = @import("../state/jump_history.zig");
const lsp_manager = @import("../../lsp/manager.zig");
const syntax_editor = @import("../syntax_editor.zig");
const completion_menu = @import("../renderer/completion_menu.zig");
const perf = @import("../../perf/perf.zig");

pub fn requestDefinitionAtCursor(editor: anytype) !void {
    const tab = editor.currentTab() orelse {
        editor.state.error_message = "No active file for definition lookup";
        editor.pending_definition_request_id = null;
        editor.pending_definition_plugin_name = null;
        editor.pending_definition_source = null;
        return;
    };
    const filename = tab.buf.filename orelse {
        editor.state.error_message = "No active file for definition lookup";
        editor.pending_definition_request_id = null;
        editor.pending_definition_plugin_name = null;
        editor.pending_definition_source = null;
        return;
    };
    const mc = tab.mainCursor();
    const source = jump_history.JumpLocation{
        .buffer_id = tab.syntax_buffer_id,
        .row = mc.row,
        .col = mc.col,
    };

    if (editor.runtime.lsp_mgr) |*mgr| {
        flushPendingLspChanges(editor, true) catch |err| {
            logz.err().fmt("msg", "Failed to flush LSP changes before definition request: {any}", .{err}).log();
        };

        const result = mgr.requestDefinition(filename, mc.row, mc.col) catch |err| {
            logz.err().fmt("msg", "Failed to request definition: {any}", .{err}).log();
            editor.state.error_message = "LSP definition unavailable";
            editor.pending_definition_request_id = null;
            editor.pending_definition_source = null;
            return;
        };

        switch (result) {
            .requested => |requested| {
                editor.pending_definition_request_id = requested.request_id;
                editor.pending_definition_plugin_name = requested.plugin_name;
                editor.pending_definition_source = source;
            },
            .no_plugin, .no_client, .not_ready => {
                editor.state.error_message = "LSP definition unavailable";
                editor.pending_definition_request_id = null;
                editor.pending_definition_plugin_name = null;
                editor.pending_definition_source = null;
            },
        }
    } else {
        editor.state.error_message = "LSP definition unavailable";
        editor.pending_definition_request_id = null;
        editor.pending_definition_plugin_name = null;
        editor.pending_definition_source = null;
    }
}

pub fn handleLspEvent(editor: anytype, plugin_name: []const u8, message: []const u8) !void {
    if (editor.runtime.lsp_mgr) |*mgr| {
        const res = mgr.handleMessage(plugin_name, message) catch |err| blk: {
            logz.err().fmt("msg", "Error handling LSP msg: {any}", .{err}).log();
            break :blk lsp_manager.LspManager.HandleResult.none;
        };

        switch (res) {
            .initialized => {
                for (editor.state.tabs.items) |tab| {
                    if (tab.buf.filename) |fname| {
                        const ext = std.fs.path.extension(fname);
                        if (mgr.plugin_mgr.getPluginForExtension(ext)) |p| {
                            if (std.mem.eql(u8, p.name, plugin_name)) {
                                const content = try tab.buf.toOwnedTextSnapshot(editor.allocator);
                                defer editor.allocator.free(content);
                                mgr.notifyOpen(fname, content) catch {};
                            }
                        }
                    }
                }
            },
            .completion => |items| {
                if (!isValidCompletionValue(items)) {
                    mgr.freeValue(items);
                    return;
                }
                if (completionItemsFromValue(items).?.len == 0) {
                    mgr.freeValue(items);
                    editor.state.lsp_ui.clearCompletion();
                    editor.markDirty(.partial);
                    return;
                }
                editor.state.lsp_ui.replaceCompletion(items);
                editor.markDirty(.partial);
            },
            .definition => |definition| {
                defer mgr.freeValue(definition.result);
                try handleDefinitionResult(editor, plugin_name, definition.request_id, definition.result);
            },
            .diagnostics => |diag_val| {
                var diagnostics_stored = false;
                errdefer if (!diagnostics_stored) mgr.freeValue(diag_val);

                const uri = diagnosticUri(diag_val) orelse return;
                const fname = if (std.mem.startsWith(u8, uri, "file://")) uri[7..] else uri;
                try editor.state.lsp_ui.replaceDiagnostics(fname, diag_val);
                diagnostics_stored = true;
                editor.markDirty(.partial);
            },
            .none => {},
        }
    }
}

pub fn handleDefinitionResult(editor: anytype, plugin_name: []const u8, request_id: usize, result: std.json.Value) !void {
    const pending_id = editor.pending_definition_request_id orelse return;
    const pending_plugin_name = editor.pending_definition_plugin_name orelse return;
    if (pending_id != request_id) return;
    if (!std.mem.eql(u8, pending_plugin_name, plugin_name)) return;

    const source = editor.pending_definition_source;
    editor.pending_definition_request_id = null;
    editor.pending_definition_plugin_name = null;
    editor.pending_definition_source = null;

    const location = lsp_manager.firstDefinitionLocation(result) orelse {
        editor.state.error_message = "No definition found";
        editor.markDirty(.partial);
        return;
    };

    const path = lsp_manager.fileUriToPathAlloc(editor.allocator, location.uri) catch |err| {
        logz.err().fmt("msg", "failed to convert definition URI {s}: {any}", .{ location.uri, err }).log();
        editor.state.error_message = "Could not open definition target";
        editor.markDirty(.partial);
        return;
    };
    defer editor.allocator.free(path);

    _ = jumpToFileLocation(editor, path, location.row, location.col, source) catch |err| {
        logz.err().fmt("msg", "failed to jump to definition target {s}: {any}", .{ path, err }).log();
        editor.state.error_message = "Could not open definition target";
        editor.markDirty(.partial);
        return;
    };
    editor.state.error_message = null;
    editor.markDirty(.full);
}

pub fn jumpToFileLocation(
    editor: anytype,
    path: []const u8,
    row: usize,
    col: usize,
    source: ?jump_history.JumpLocation,
) !bool {
    if (findOpenTabIndexByPath(editor, path)) |idx| {
        editor.state.active_tab_index = idx;
    } else {
        var loaded = try buffer.Buffer.loadFromFile(editor.allocator, editor.io, path);
        var consumed = false;
        errdefer if (!consumed) loaded.deinit();
        try editor.addTab(loaded);
        consumed = true;
    }

    const tab = editor.currentTab() orelse return false;
    const target = clampedLocationForTab(editor, tab, row, col);
    if (source) |from| {
        if (!from.eql(target)) try editor.state.jump_history.recordJump(editor.allocator, from);
    }

    const mc = tab.mainCursor();
    const changed = mc.row != target.row or mc.col != target.col;
    mc.row = target.row;
    mc.col = target.col;
    mc.preferred_col = null;
    editor.clampScroll();
    return changed;
}

pub fn findOpenTabIndexByPath(editor: anytype, path: []const u8) ?usize {
    for (editor.state.tabs.items, 0..) |*tab, i| {
        if (tab.buf.filename) |filename| {
            if (std.mem.eql(u8, filename, path)) return i;
        }
    }

    const target_real = realPathOrNull(editor, path) orelse return null;
    defer editor.allocator.free(target_real);

    for (editor.state.tabs.items, 0..) |*tab, i| {
        const filename = tab.buf.filename orelse continue;
        const filename_real = realPathOrNull(editor, filename) orelse continue;
        defer editor.allocator.free(filename_real);
        if (std.mem.eql(u8, filename_real, target_real)) return i;
    }
    return null;
}

pub fn realPathOrNull(editor: anytype, path: []const u8) ?[]u8 {
    const z = std.Io.Dir.cwd().realPathFileAlloc(editor.io, path, editor.allocator) catch return null;
    defer editor.allocator.free(z);
    return editor.allocator.dupe(u8, z) catch null;
}

pub fn clampedLocationForTab(editor: anytype, tab: anytype, row: usize, col: usize) jump_history.JumpLocation {
    var clamped_row = row;
    var clamped_col = col;
    if (tab.buf.lines.items.len == 0) {
        clamped_row = 0;
        clamped_col = 0;
    } else {
        clamped_row = @min(clamped_row, tab.buf.lines.items.len - 1);
        clamped_row = tab.buf.clampToVisibleLine(clamped_row);
        clamped_col = @min(clamped_col, tab.buf.lines.items[clamped_row].len());
    }
    _ = editor;
    return .{
        .buffer_id = tab.syntax_buffer_id,
        .row = clamped_row,
        .col = clamped_col,
    };
}

pub fn notePendingLspChange(editor: anytype) void {
    const tab = editor.currentTab() orelse return;
    if (!tab.needsLspChangeNotification()) return;
    if (tab.lsp_pending_since_ns == null) {
        tab.lsp_pending_since_ns = perf.nowNs();
    }
}

pub fn flushPendingLspChanges(editor: anytype, force: bool) !void {
    const tab = editor.currentTab() orelse return;
    if (!tab.needsLspChangeNotification()) {
        tab.lsp_pending_since_ns = null;
        return;
    }
    if (tab.lsp_pending_since_ns == null) return;
    if (!force and perf.nowNs() - tab.lsp_pending_since_ns.? < 250 * std.time.ns_per_ms) {
        return;
    }

    if (editor.runtime.lsp_mgr) |*mgr| {
        const snapshot = try syntax_editor.takeTextSnapshot(editor, tab);
        defer editor.allocator.free(snapshot.text);
        if (snapshot.revision != tab.buf.revision) return;
        if (mgr.notifyChange(tab.buf.filename.?, snapshot.text)) {
            tab.markLspChangeNotified();
        } else |err| {
            logz.err().fmt("msg", "Failed to notify change: {any}", .{err}).log();
        }
    }
}

pub fn requestCompletionAtCursor(editor: anytype, force_flush: bool) void {
    const tab = editor.currentTab() orelse return;
    const filename = tab.buf.filename orelse return;

    if (force_flush) {
        flushPendingLspChanges(editor, true) catch |err| {
            logz.err().fmt("msg", "Failed to flush LSP changes before completion request: {any}", .{err}).log();
        };
    }

    if (editor.runtime.lsp_mgr) |*mgr| {
        const mc = tab.mainCursor();
        mgr.requestCompletion(filename, mc.row, mc.col) catch |err| {
            logz.err().fmt("msg", "Failed to request completion: {any}", .{err}).log();
        };
    }
}

pub fn maybeRequestCompletionAfterInput(editor: anytype, event: terminal.KeyEvent) void {
    if (!shouldRequestCompletionAfterInput(editor, event)) return;
    requestCompletionAtCursor(editor, true);
}

pub fn shouldRequestCompletionAfterInput(editor: anytype, event: terminal.KeyEvent) bool {
    if (editor.state.mode != .Insert) return false;
    if (!isPlainIdentifierCharEvent(event)) return false;
    if (editor.runtime.lsp_mgr == null) return false;

    const tab = editor.currentTab() orelse return false;
    if (tab.multi_cursor.active) return false;
    if (tab.buf.filename == null) return false;
    return identifierPrefixLen(tab) >= 2;
}

pub fn modeAllowsCompletion(editor: anytype) bool {
    return editor.state.mode == .Normal or editor.state.mode == .Insert;
}

pub fn identifierPrefixLen(tab: anytype) usize {
    const mc = tab.mainCursor();
    if (mc.row >= tab.buf.lines.items.len) return 0;
    const line = &tab.buf.lines.items[mc.row];
    var col = @min(mc.col, line.len());
    var count: usize = 0;
    while (col > 0) {
        const ch = line.byteAt(col - 1) orelse break;
        if (!isIdentifierChar(ch)) break;
        count += 1;
        col -= 1;
    }
    return count;
}

pub fn matchingCompletionCount(tab: anytype, items: []std.json.Value) usize {
    var count: usize = 0;
    for (items) |value| {
        const item = completion_menu.completionItemObject(value) orelse continue;
        if (completionItemMatchesTabPrefix(tab, item)) count += 1;
    }
    return count;
}

pub fn handleCompletionInput(editor: anytype, event: terminal.KeyEvent) !bool {
    if (!editor.state.lsp_ui.completion_active or editor.state.lsp_ui.completion_items == null) return false;
    const items = editor.state.lsp_ui.completionItems();

    if (completionActionCommandForEvent(editor, event)) |command| {
        switch (command) {
            .completion_previous => {
                const tab = editor.currentTab() orelse return true;
                if (previousMatchingCompletionIndex(tab, items, editor.state.lsp_ui.completion_selected)) |idx| {
                    editor.state.lsp_ui.completion_selected = idx;
                } else {
                    editor.state.lsp_ui.clearCompletion();
                }
                return true;
            },
            .completion_next => {
                const tab = editor.currentTab() orelse return true;
                if (nextMatchingCompletionIndex(tab, items, editor.state.lsp_ui.completion_selected)) |idx| {
                    editor.state.lsp_ui.completion_selected = idx;
                } else {
                    editor.state.lsp_ui.clearCompletion();
                }
                return true;
            },
            .completion_accept => {
                const tab = editor.currentTab() orelse {
                    editor.state.lsp_ui.clearCompletion();
                    return false;
                };
                const selected_idx = selectedMatchingCompletionIndex(tab, items, editor.state.lsp_ui.completion_selected) orelse {
                    editor.state.lsp_ui.clearCompletion();
                    return false;
                };
                editor.state.lsp_ui.completion_selected = selected_idx;
                const item = completion_menu.completionItemObject(items[selected_idx]) orelse {
                    editor.state.lsp_ui.clearCompletion();
                    return false;
                };
                const label = completion_menu.completionItemString(item, "label") orelse {
                    editor.state.lsp_ui.clearCompletion();
                    return false;
                };
                const insertText = completionItemInsertText(item) orelse label;

                const mc = tab.mainCursor();
                var prefix_len = identifierPrefixLen(tab);
                while (prefix_len > 0 and mc.col > 0) : (prefix_len -= 1) {
                    _ = try tab.buf.deleteCharBack(mc.row, mc.col);
                    mc.col -= 1;
                }
                mc.preferred_col = null;

                // Simple insertion for now.
                // TODO: handle overwrite, textEdit ranges, and snippets.
                for (insertText) |c| {
                    try tab.buf.insertChar(mc.row, mc.col, c);
                    mc.col += 1;
                }

                editor.state.lsp_ui.clearCompletion();
                return true;
            },
            .completion_cancel => {
                editor.state.lsp_ui.clearCompletion();
                return true;
            },
            else => unreachable,
        }
    }

    switch (event.key) {
        .Char => {
            if (!isIdentifierChar(event.char)) {
                editor.state.lsp_ui.clearCompletion();
                return false;
            }
            return false;
        },
        else => {
            editor.state.lsp_ui.clearCompletion();
            return false;
        },
    }
}

pub fn diagnosticUri(value: std.json.Value) ?[]const u8 {
    if (value != .object) return null;
    const uri = value.object.get("uri") orelse return null;
    if (uri != .string) return null;
    const diagnostics = value.object.get("diagnostics") orelse return null;
    if (diagnostics != .array) return null;
    return uri.string;
}

pub fn isValidCompletionValue(value: std.json.Value) bool {
    return completionItemsFromValue(value) != null;
}

fn completionItemsFromValue(value: std.json.Value) ?[]std.json.Value {
    if (value == .array) return value.array.items;
    if (value == .object) {
        const items = value.object.get("items") orelse return null;
        if (items == .array) return items.array.items;
    }
    return null;
}

pub fn completionItemObject(value: std.json.Value) ?std.json.ObjectMap {
    return completion_menu.completionItemObject(value);
}

pub fn completionItemString(item: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    return completion_menu.completionItemString(item, key);
}

fn selectedMatchingCompletionIndex(tab: anytype, items: []std.json.Value, selected_idx: usize) ?usize {
    if (items.len == 0) return null;
    if (selected_idx < items.len) {
        if (completion_menu.completionItemObject(items[selected_idx])) |item| {
            if (completionItemMatchesTabPrefix(tab, item)) return selected_idx;
        }
    }
    return firstMatchingCompletionIndex(tab, items);
}

fn firstMatchingCompletionIndex(tab: anytype, items: []std.json.Value) ?usize {
    for (items, 0..) |value, idx| {
        const item = completion_menu.completionItemObject(value) orelse continue;
        if (completionItemMatchesTabPrefix(tab, item)) return idx;
    }
    return null;
}

fn nextMatchingCompletionIndex(tab: anytype, items: []std.json.Value, selected_idx: usize) ?usize {
    if (items.len == 0) return null;
    var offset: usize = 1;
    while (offset <= items.len) : (offset += 1) {
        const idx = (selected_idx + offset) % items.len;
        const item = completion_menu.completionItemObject(items[idx]) orelse continue;
        if (completionItemMatchesTabPrefix(tab, item)) return idx;
    }
    return null;
}

fn previousMatchingCompletionIndex(tab: anytype, items: []std.json.Value, selected_idx: usize) ?usize {
    if (items.len == 0) return null;
    var offset: usize = 1;
    while (offset <= items.len) : (offset += 1) {
        const idx = (selected_idx + items.len - (offset % items.len)) % items.len;
        const item = completion_menu.completionItemObject(items[idx]) orelse continue;
        if (completionItemMatchesTabPrefix(tab, item)) return idx;
    }
    return null;
}

fn completionItemMatchesTabPrefix(tab: anytype, item: std.json.ObjectMap) bool {
    const candidate = completionItemFilterText(item) orelse return false;
    const mc = tab.mainCursor();
    if (mc.row >= tab.buf.lines.items.len) return false;
    const line = &tab.buf.lines.items[mc.row];
    const prefix_len = identifierPrefixLen(tab);
    if (prefix_len == 0) return true;
    if (candidate.len < prefix_len or mc.col < prefix_len) return false;
    const start_col = mc.col - prefix_len;
    for (0..prefix_len) |i| {
        const ch = line.byteAt(start_col + i) orelse return false;
        if (candidate[i] != ch) return false;
    }
    return true;
}

fn completionItemFilterText(item: std.json.ObjectMap) ?[]const u8 {
    return completion_menu.completionItemString(item, "filterText") orelse
        completionItemInsertText(item) orelse
        completion_menu.completionItemString(item, "label");
}

fn completionItemInsertText(item: std.json.ObjectMap) ?[]const u8 {
    return completion_menu.completionItemString(item, "insertText") orelse
        completion_menu.completionItemString(item, "filterText");
}

fn completionActionCommandForEvent(editor: anytype, event: terminal.KeyEvent) ?commands.CommandId {
    const result = editor.keybinding_registry.resolve(.completion, command_keybindings.KeySequence.fromEvent(event));
    const command = switch (result) {
        .command => |command| command,
        else => return null,
    };
    return switch (command) {
        .completion_previous,
        .completion_next,
        .completion_accept,
        .completion_cancel,
        => command,
        else => null,
    };
}

fn isPlainIdentifierCharEvent(event: terminal.KeyEvent) bool {
    return event.key == .Char and !event.ctrl and !event.alt and !event.shift and isIdentifierChar(event.char);
}

fn isIdentifierChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}
