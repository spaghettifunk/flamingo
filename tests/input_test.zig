//! input_test.zig — behavioral / integration tests for input.zig
//!
//! Feeds KeyEvents directly into handleInput() and asserts editor state.
//! No real TTY is required. All Option-key bindings use alt=true as that
//! is how the macOS Option key is represented after terminal decoding.

const std = @import("std");
const input_mod = @import("../src/editor/input_router/dispatch.zig");
const editor_mod = @import("../src/editor/editor.zig");
const buffer_mod = @import("../src/editor/model/buffer.zig");
const explorer_mod = @import("../src/editor/explorer.zig");
const prompt_mod = @import("../src/editor/prompt_popup.zig");
const navigation = @import("../src/editor/navigation.zig");
const commands = @import("../src/editor/commands.zig");
const keybindings = @import("../src/editor/keybindings.zig");
const Buffer = buffer_mod.Buffer;
const Line = buffer_mod.Line;
const terminal = @import("../src/terminal.zig");
const th = @import("test_helpers.zig");

// ── Helpers ───────────────────────────────────────────────────────────────────

fn feed(ed: *editor_mod.Editor, events: []const terminal.KeyEvent) !void {
    for (events) |ev| try input_mod.handleInput(ed, ev);
}

fn expectLine(a: std.mem.Allocator, ed: *editor_mod.Editor, row: usize, expected: []const u8) !void {
    const s = try th.lineText(a, ed, row);
    defer a.free(s);
    try std.testing.expectEqualStrings(expected, s);
}

fn appendGlobalSearchPathResult(a: std.mem.Allocator, ed: *editor_mod.Editor, path: []const u8) !void {
    const open_path = try a.dupe(u8, path);
    errdefer a.free(open_path);
    const display_path = try a.dupe(u8, path);
    errdefer a.free(display_path);
    try ed.state.global_search.results.append(a, .{ .path = .{
        .open_path = open_path,
        .display_path = display_path,
    } });
}

fn attachFocusedExplorer(a: std.mem.Allocator, io: std.Io, ed: *editor_mod.Editor, root_path: []const u8) !void {
    ed.state.tree = try explorer_mod.Explorer.init(a, io, root_path);
    ed.state.explorer_visible = true;
    ed.state.explorer_focused = true;
}

fn feedText(ed: *editor_mod.Editor, text: []const u8) !void {
    for (text) |ch| try feed(ed, &[_]terminal.KeyEvent{th.keyChar(ch)});
}

fn pickerEntryIndex(ed: *editor_mod.Editor, name: []const u8) ?usize {
    for (ed.state.filesystem_picker.entries.items, 0..) |entry, index| {
        if (std.mem.eql(u8, entry.name, name)) return index;
    }
    return null;
}

fn installKeybindingOverrides(ed: *editor_mod.Editor, overrides: []const keybindings.UserBindingOverride) !void {
    var diagnostics = keybindings.BuildDiagnostics{};
    defer diagnostics.deinit(ed.allocator);
    var registry = try keybindings.Registry.fromDefaultsAndConfig(ed.allocator, overrides, &.{}, &diagnostics);
    errdefer registry.deinit(ed.allocator);
    try std.testing.expect(!diagnostics.hasErrors());
    ed.keybinding_registry.deinit(ed.allocator);
    ed.keybinding_registry = registry;
}

fn replaceBinding(
    ed: *editor_mod.Editor,
    context: commands.CommandContext,
    sequence: keybindings.KeySequence,
    command: commands.CommandId,
    default_sequence: keybindings.KeySequence,
) !void {
    try installKeybindingOverrides(ed, &.{
        .{
            .context = context,
            .sequence = sequence,
            .command = command,
            .replace_default_sequence = default_sequence,
        },
    });
}

// ── Mode transitions ──────────────────────────────────────────────────────────

test "Dashboard → filesystem picker via Enter on 'New File'" {
    const a = std.testing.allocator;
    var ed = try th.makeEmptyEditor(a);
    defer ed.deinit();

    try std.testing.expectEqual(editor_mod.EditorMode.Dashboard, ed.state.mode);
    // Dashboard: selected_index starts at 0 ("New File"), press Enter to confirm.
    try feed(&ed, &[_]terminal.KeyEvent{th.keySpecial(.Enter)});
    try std.testing.expectEqual(editor_mod.EditorMode.FilesystemPicker, ed.state.mode);
    try std.testing.expect(ed.state.filesystem_picker.visible);
    try std.testing.expectEqual(@as(usize, 0), ed.state.tabs.items.len);
}

test "Dashboard: Create Workspace opens folder picker with workspace purpose" {
    const a = std.testing.allocator;
    var ed = try th.makeEmptyEditor(a);
    defer ed.deinit();

    try feed(&ed, &[_]terminal.KeyEvent{th.keyCtrl('w')});

    try std.testing.expectEqual(editor_mod.EditorMode.FilesystemPicker, ed.state.mode);
    try std.testing.expect(ed.state.filesystem_picker.visible);
    try std.testing.expectEqual(.open_folder, ed.state.filesystem_picker.mode);
    try std.testing.expectEqual(.create_workspace, ed.state.filesystem_picker.folder_purpose);
}

test "Dashboard: Up Down and configured movement key change selection" {
    const a = std.testing.allocator;
    var ed = try th.makeEmptyEditor(a);
    defer ed.deinit();

    try feed(&ed, &[_]terminal.KeyEvent{th.keySpecial(.Up)});
    try std.testing.expectEqual(@as(usize, 5), ed.state.dash.selected_index);

    try feed(&ed, &[_]terminal.KeyEvent{th.keySpecial(.Down)});
    try std.testing.expectEqual(@as(usize, 0), ed.state.dash.selected_index);

    try replaceBinding(&ed, .dashboard, keybindings.ctrlChar('j'), .dashboard_move_down, keybindings.keySpecial(.Down));

    try feed(&ed, &[_]terminal.KeyEvent{th.keySpecial(.Down)});
    try std.testing.expectEqual(@as(usize, 0), ed.state.dash.selected_index);

    try feed(&ed, &[_]terminal.KeyEvent{th.keyCtrl('j')});
    try std.testing.expectEqual(@as(usize, 1), ed.state.dash.selected_index);
}

test "Dashboard: Ctrl+O opens filesystem picker in open-file mode" {
    const a = std.testing.allocator;
    var ed = try th.makeEmptyEditor(a);
    defer ed.deinit();

    try feed(&ed, &[_]terminal.KeyEvent{th.keyCtrl('o')});

    try std.testing.expectEqual(editor_mod.EditorMode.FilesystemPicker, ed.state.mode);
    try std.testing.expect(ed.state.filesystem_picker.visible);
    try std.testing.expectEqual(.open_file, ed.state.filesystem_picker.mode);
}

test "FilesystemPicker: Up Down and configured submit key are routed through picker actions" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const log = try th.setupLogger(a);
    defer log.deinit();

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "alpha.txt", .data = "opened\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "beta.txt", .data = "" });
    const root_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(root_path);

    var ed = try th.makeEmptyEditor(a);
    defer ed.deinit();
    try replaceBinding(&ed, .picker, keybindings.ctrlChar('j'), .picker_accept, keybindings.keySpecial(.Enter));
    try ed.state.filesystem_picker.open(a, io, .open_file, root_path);
    ed.state.mode = .FilesystemPicker;

    try std.testing.expect(ed.state.filesystem_picker.entries.items.len >= 2);
    try feed(&ed, &[_]terminal.KeyEvent{th.keySpecial(.Down)});
    try std.testing.expectEqual(@as(usize, 1), ed.state.filesystem_picker.selected_index);

    try feed(&ed, &[_]terminal.KeyEvent{th.keySpecial(.Up)});
    try std.testing.expectEqual(@as(usize, 0), ed.state.filesystem_picker.selected_index);

    ed.state.filesystem_picker.selected_index = pickerEntryIndex(&ed, "alpha.txt") orelse return error.MissingPickerEntry;
    try feed(&ed, &[_]terminal.KeyEvent{th.keySpecial(.Enter)});
    try std.testing.expectEqual(editor_mod.EditorMode.FilesystemPicker, ed.state.mode);
    try std.testing.expectEqual(@as(usize, 0), ed.state.tabs.items.len);

    try feed(&ed, &[_]terminal.KeyEvent{th.keyCtrl('j')});
    try std.testing.expectEqual(editor_mod.EditorMode.Normal, ed.state.mode);
    try std.testing.expectEqual(@as(usize, 1), ed.state.tabs.items.len);
    try std.testing.expect(std.mem.endsWith(u8, ed.currentTab().?.buf.filename.?, "alpha.txt"));
}

test "FilesystemPicker: new-file picker keeps filename text raw after space action" {
    const a = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(root_path);

    var ed = try th.makeEmptyEditor(a);
    defer ed.deinit();
    try ed.state.filesystem_picker.open(a, io, .new_file_location, root_path);
    ed.state.mode = .FilesystemPicker;

    try feed(&ed, &[_]terminal.KeyEvent{th.keyChar(' ')});
    try std.testing.expectEqual(.entering_name, ed.state.filesystem_picker.phase);

    try feedText(&ed, "a b");
    try std.testing.expectEqualStrings("a b", ed.state.filesystem_picker.input.items);
}

test "FilesystemPicker: open-folder dot selects current folder" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const log = try th.setupLogger(a);
    defer log.deinit();

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(root_path);

    var ed = try th.makeEmptyEditor(a);
    defer ed.deinit();
    try ed.state.filesystem_picker.open(a, io, .open_folder, root_path);
    ed.state.mode = .FilesystemPicker;

    try feed(&ed, &[_]terminal.KeyEvent{th.keyChar('.')});

    try std.testing.expectEqual(editor_mod.EditorMode.Normal, ed.state.mode);
    try std.testing.expect(ed.state.explorer_visible);
    try std.testing.expect(ed.state.explorer_focused);
    try std.testing.expect(ed.state.project_root != null);
}

test "FilesystemPicker: open-folder detects workspace marker" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const log = try th.setupLogger(a);
    defer log.deinit();

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, ".flamingo");

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_path = path_buf[0..try tmp.dir.realPath(io, &path_buf)];

    var ed = try th.makeEmptyEditor(a);
    defer ed.deinit();
    try ed.state.filesystem_picker.open(a, io, .open_folder, root_path);
    ed.state.mode = .FilesystemPicker;

    try feed(&ed, &[_]terminal.KeyEvent{th.keyChar('.')});

    try std.testing.expect(ed.state.workspace.active);
    try std.testing.expect(ed.state.workspace.root_path != null);
    try std.testing.expectEqualStrings(ed.state.project_root.?, ed.state.workspace.root_path.?);
}

test "OpenFilePrompt: typed path backspace submit and cancel use prompt actions" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const log = try th.setupLogger(a);
    defer log.deinit();

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "alpha.txt", .data = "opened\n" });
    const root_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(root_path);
    const file_path = try std.fs.path.join(a, &.{ root_path, "alpha.txt" });
    defer a.free(file_path);

    var ed = try th.makeEmptyEditor(a);
    defer ed.deinit();

    ed.state.mode = .OpenFilePrompt;
    try feedText(&ed, file_path);
    try feed(&ed, &[_]terminal.KeyEvent{th.keySpecial(.Backspace)});
    try std.testing.expectEqualStrings(file_path[0 .. file_path.len - 1], ed.state.command_buffer.items);
    try feed(&ed, &[_]terminal.KeyEvent{th.keyChar('t')});
    try std.testing.expectEqualStrings(file_path, ed.state.command_buffer.items);

    try feed(&ed, &[_]terminal.KeyEvent{th.keySpecial(.Enter)});
    try std.testing.expectEqual(editor_mod.EditorMode.Normal, ed.state.mode);
    try std.testing.expectEqual(@as(usize, 1), ed.state.tabs.items.len);
    try std.testing.expect(std.mem.endsWith(u8, ed.currentTab().?.buf.filename.?, "alpha.txt"));

    ed.state.mode = .OpenFilePrompt;
    ed.state.command_buffer.clearRetainingCapacity();
    try feedText(&ed, "ignored");
    try feed(&ed, &[_]terminal.KeyEvent{th.keySpecial(.Esc)});
    try std.testing.expectEqual(editor_mod.EditorMode.Dashboard, ed.state.mode);
}

test "Normal → Insert via 'i'" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{""});
    defer ed.deinit();

    try feed(&ed, &[_]terminal.KeyEvent{th.keyChar('i')});
    try std.testing.expectEqual(editor_mod.EditorMode.Insert, ed.state.mode);
}

test "Insert → Normal via Esc" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{""});
    defer ed.deinit();

    ed.state.mode = .Insert;
    try feed(&ed, &[_]terminal.KeyEvent{th.keySpecial(.Esc)});
    try std.testing.expectEqual(editor_mod.EditorMode.Normal, ed.state.mode);
}

test "Normal → Command via ':'" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{""});
    defer ed.deinit();

    try feed(&ed, &[_]terminal.KeyEvent{th.keyChar(':')});
    try std.testing.expectEqual(editor_mod.EditorMode.Command, ed.state.mode);
    try std.testing.expect(ed.state.command_popup.visible);
    try std.testing.expectEqual(@as(usize, 0), ed.state.command_buffer.items.len);
    try std.testing.expectEqual(@as(usize, 0), ed.state.command_popup.input.items.len);
}

test "Command → Normal via Esc" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{""});
    defer ed.deinit();

    ed.state.mode = .Command;
    try ed.state.command_popup.open(a);
    try feed(&ed, &[_]terminal.KeyEvent{th.keySpecial(.Esc)});
    try std.testing.expectEqual(editor_mod.EditorMode.Normal, ed.state.mode);
    try std.testing.expect(!ed.state.command_popup.visible);
}

test "Normal → Search via '/'" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{"hello world"});
    defer ed.deinit();

    try feed(&ed, &[_]terminal.KeyEvent{th.keyChar('/')});
    try std.testing.expectEqual(editor_mod.EditorMode.Search, ed.state.mode);
    try std.testing.expectEqual(@as(usize, 0), ed.state.search_buffer.items.len);
}

test "Search → Normal via Esc clears search" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{"hello world"});
    defer ed.deinit();

    ed.state.mode = .Search;
    try ed.state.search_buffer.append(a, 'h');
    try feed(&ed, &[_]terminal.KeyEvent{th.keySpecial(.Esc)});
    try std.testing.expectEqual(editor_mod.EditorMode.Normal, ed.state.mode);
    try std.testing.expectEqual(@as(usize, 0), ed.state.search_buffer.items.len);
}

test "Search → Normal via Enter" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{"hello world"});
    defer ed.deinit();

    ed.state.mode = .Search;
    try feed(&ed, &[_]terminal.KeyEvent{th.keySpecial(.Enter)});
    try std.testing.expectEqual(editor_mod.EditorMode.Normal, ed.state.mode);
}

// ── Normal-mode key sequences ────────────────────────────────────────────────

test "Normal: gg jumps to top of current file" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{ "top", "middle", "bottom" });
    defer ed.deinit();

    const tab = ed.currentTab().?;
    tab.mainCursor().row = 2;
    tab.mainCursor().col = 4;
    tab.mainCursor().preferred_col = 4;
    tab.scroll_row = 2;

    try feed(&ed, &[_]terminal.KeyEvent{ th.keyChar('g'), th.keyChar('g') });

    try std.testing.expectEqual(@as(usize, 0), tab.mainCursor().row);
    try std.testing.expectEqual(@as(usize, 0), tab.mainCursor().col);
    try std.testing.expectEqual(@as(?usize, null), tab.mainCursor().preferred_col);
    try std.testing.expectEqual(@as(usize, 0), tab.scroll_row);
    try std.testing.expectEqual(@as(usize, 0), ed.state.pending_normal_sequence.len);
}

test "Normal: unknown gx sequence clears pending state and consumes x" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{ "top", "middle" });
    defer ed.deinit();

    const tab = ed.currentTab().?;
    tab.mainCursor().row = 1;
    tab.mainCursor().col = 2;

    try feed(&ed, &[_]terminal.KeyEvent{th.keyChar('g')});
    try std.testing.expectEqual(@as(usize, 1), ed.state.pending_normal_sequence.len);

    try feed(&ed, &[_]terminal.KeyEvent{th.keyChar('x')});
    try std.testing.expectEqual(@as(usize, 0), ed.state.pending_normal_sequence.len);
    try std.testing.expectEqual(@as(usize, 1), tab.mainCursor().row);
    try std.testing.expectEqual(@as(usize, 2), tab.mainCursor().col);
}

test "Normal: Esc clears pending sequence" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{"top"});
    defer ed.deinit();

    try feed(&ed, &[_]terminal.KeyEvent{th.keyChar('g')});
    try std.testing.expectEqual(@as(usize, 1), ed.state.pending_normal_sequence.len);

    try feed(&ed, &[_]terminal.KeyEvent{th.keySpecial(.Esc)});
    try std.testing.expectEqual(@as(usize, 0), ed.state.pending_normal_sequence.len);
    try std.testing.expectEqual(editor_mod.EditorMode.Normal, ed.state.mode);
}

test "Insert: gg inserts text and does not affect Normal pending sequence" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{""});
    defer ed.deinit();

    ed.state.mode = .Insert;
    try feed(&ed, &[_]terminal.KeyEvent{ th.keyChar('g'), th.keyChar('g') });

    try expectLine(a, &ed, 0, "gg");
    try std.testing.expectEqual(@as(usize, 0), ed.state.pending_normal_sequence.len);
}

test "Insert: f inserts text and does not trigger definition lookup" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{""});
    defer ed.deinit();

    ed.state.mode = .Insert;
    try feed(&ed, &[_]terminal.KeyEvent{th.keyChar('f')});

    try expectLine(a, &ed, 0, "f");
    try std.testing.expect(ed.state.error_message == null);
    try std.testing.expectEqual(@as(?usize, null), ed.pending_definition_request_id);
}

test "Normal: f without file-backed buffer reports no active file and does not move" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{"plain"});
    defer ed.deinit();

    const tab = ed.currentTab().?;
    tab.mainCursor().row = 0;
    tab.mainCursor().col = 2;

    try feed(&ed, &[_]terminal.KeyEvent{th.keyChar('f')});

    try std.testing.expectEqualStrings("No active file for definition lookup", ed.state.error_message.?);
    try std.testing.expectEqual(@as(usize, 0), tab.mainCursor().row);
    try std.testing.expectEqual(@as(usize, 2), tab.mainCursor().col);
    try std.testing.expectEqual(@as(?usize, null), ed.pending_definition_request_id);
}

test "Normal: repeated gggg resolves as two gg commands and leaves no pending state" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{ "top", "middle", "bottom" });
    defer ed.deinit();

    const tab = ed.currentTab().?;
    tab.mainCursor().row = 2;
    tab.mainCursor().col = 3;
    tab.scroll_row = 2;

    try feed(&ed, &[_]terminal.KeyEvent{
        th.keyChar('g'),
        th.keyChar('g'),
        th.keyChar('g'),
        th.keyChar('g'),
        th.keySpecial(.Down),
    });

    try std.testing.expectEqual(@as(usize, 1), tab.mainCursor().row);
    try std.testing.expectEqual(@as(usize, 0), tab.mainCursor().col);
    try std.testing.expectEqual(@as(usize, 0), ed.state.pending_normal_sequence.len);
}

test "Normal: G jumps to bottom and records jump history" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{ "top", "middle", "bottom" });
    defer ed.deinit();

    const tab = ed.currentTab().?;
    tab.mainCursor().row = 0;
    tab.mainCursor().col = 10;

    try feed(&ed, &[_]terminal.KeyEvent{th.keyChar('G')});

    try std.testing.expectEqual(@as(usize, 2), tab.mainCursor().row);
    try std.testing.expectEqual(@as(usize, 6), tab.mainCursor().col);
    try std.testing.expectEqual(@as(?usize, null), tab.mainCursor().preferred_col);
    try std.testing.expectEqual(@as(usize, 1), ed.state.jump_history.back_stack.items.len);
}

test "Normal: G on empty buffer stays at row zero col zero" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{""});
    defer ed.deinit();

    try feed(&ed, &[_]terminal.KeyEvent{th.keyChar('G')});

    const tab = ed.currentTab().?;
    try std.testing.expectEqual(@as(usize, 0), tab.mainCursor().row);
    try std.testing.expectEqual(@as(usize, 0), tab.mainCursor().col);
    try std.testing.expectEqual(@as(usize, 0), ed.state.jump_history.back_stack.items.len);
}

test "Normal: percent bracket jump handles empty buffers" {
    const a = std.testing.allocator;
    var buf = try Buffer.init(a);
    defer buf.deinit();

    var first = buf.lines.orderedRemove(0);
    first.deinit();

    try std.testing.expectEqual(@as(?buffer_mod.TextPoint, null), navigation.findMatchingBracket(&buf, .{ .row = 0, .col = 0 }));
}

test "Normal: percent jumps between same-line parentheses" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{"call(arg)"});
    defer ed.deinit();

    const tab = ed.currentTab().?;
    tab.mainCursor().col = 4;

    try feed(&ed, &[_]terminal.KeyEvent{th.keyChar('%')});

    try std.testing.expectEqual(@as(usize, 0), tab.mainCursor().row);
    try std.testing.expectEqual(@as(usize, 8), tab.mainCursor().col);
    try std.testing.expectEqual(@as(usize, 1), ed.state.jump_history.back_stack.items.len);
}

test "Normal: percent jumps between same-line braces and brackets" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{"{a[b]}"});
    defer ed.deinit();

    const tab = ed.currentTab().?;
    tab.mainCursor().col = 0;
    try feed(&ed, &[_]terminal.KeyEvent{th.keyChar('%')});
    try std.testing.expectEqual(@as(usize, 5), tab.mainCursor().col);

    tab.mainCursor().col = 2;
    try feed(&ed, &[_]terminal.KeyEvent{th.keyChar('%')});
    try std.testing.expectEqual(@as(usize, 4), tab.mainCursor().col);
}

test "Normal: percent respects nested brackets" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{"(a[b{c}])"});
    defer ed.deinit();

    const tab = ed.currentTab().?;
    tab.mainCursor().col = 0;
    try feed(&ed, &[_]terminal.KeyEvent{th.keyChar('%')});
    try std.testing.expectEqual(@as(usize, 8), tab.mainCursor().col);

    tab.mainCursor().col = 2;
    try feed(&ed, &[_]terminal.KeyEvent{th.keyChar('%')});
    try std.testing.expectEqual(@as(usize, 7), tab.mainCursor().col);
}

test "Normal: percent supports multi-line bracket matches" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{ "fn main() {", "    call();", "}" });
    defer ed.deinit();

    const tab = ed.currentTab().?;
    tab.mainCursor().row = 0;
    tab.mainCursor().col = 10;

    try feed(&ed, &[_]terminal.KeyEvent{th.keyChar('%')});

    try std.testing.expectEqual(@as(usize, 2), tab.mainCursor().row);
    try std.testing.expectEqual(@as(usize, 0), tab.mainCursor().col);
}

test "Normal: percent scans forward on current line when cursor is not on bracket" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{"abc [x]"});
    defer ed.deinit();

    const tab = ed.currentTab().?;
    tab.mainCursor().col = 1;

    try feed(&ed, &[_]terminal.KeyEvent{th.keyChar('%')});

    try std.testing.expectEqual(@as(usize, 6), tab.mainCursor().col);
}

test "Normal: percent at line end is a no-op" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{"abc()"});
    defer ed.deinit();

    const tab = ed.currentTab().?;
    tab.mainCursor().col = 5;

    try feed(&ed, &[_]terminal.KeyEvent{th.keyChar('%')});

    try std.testing.expectEqual(@as(usize, 5), tab.mainCursor().col);
    try std.testing.expectEqual(@as(usize, 0), ed.state.jump_history.back_stack.items.len);
}

test "Normal: percent without matching bracket is a no-op and does not record history" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{"abc ("});
    defer ed.deinit();

    const tab = ed.currentTab().?;
    tab.mainCursor().col = 4;

    try feed(&ed, &[_]terminal.KeyEvent{th.keyChar('%')});

    try std.testing.expectEqual(@as(usize, 4), tab.mainCursor().col);
    try std.testing.expectEqual(@as(usize, 0), ed.state.jump_history.back_stack.items.len);
}

test "Normal: Ctrl+O can return from a successful percent jump" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{"(value)"});
    defer ed.deinit();

    try replaceBinding(&ed, .normal, keybindings.ctrlChar('o'), .navigation_jump_back, keybindings.altChar('o'));

    const tab = ed.currentTab().?;
    tab.mainCursor().col = 0;

    try feed(&ed, &[_]terminal.KeyEvent{th.keyChar('%')});
    try std.testing.expectEqual(@as(usize, 6), tab.mainCursor().col);

    try feed(&ed, &[_]terminal.KeyEvent{th.keyCtrl('o')});
    try std.testing.expectEqual(@as(usize, 0), tab.mainCursor().col);
}

test "Command: numeric line jump uses one-based line numbers" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{ "one", "two", "three" });
    defer ed.deinit();

    try feed(&ed, &[_]terminal.KeyEvent{
        th.keyChar(':'),
        th.keyChar('1'),
        th.keySpecial(.Enter),
    });

    try std.testing.expectEqual(@as(usize, 0), ed.currentTab().?.mainCursor().row);
    try std.testing.expectEqual(editor_mod.EditorMode.Normal, ed.state.mode);
}

test "Command: line jump past EOF clamps to last line" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{ "one", "two", "three" });
    defer ed.deinit();

    try feed(&ed, &[_]terminal.KeyEvent{
        th.keyChar(':'),
        th.keyChar('9'),
        th.keyChar('9'),
        th.keyChar('9'),
        th.keyChar('9'),
        th.keySpecial(.Enter),
    });

    try std.testing.expectEqual(@as(usize, 2), ed.currentTab().?.mainCursor().row);
}

test "Command: goto and line jump commands move to requested line" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{ "one", "two", "three", "four" });
    defer ed.deinit();

    try feed(&ed, &[_]terminal.KeyEvent{
        th.keyChar(':'),
        th.keyChar('g'),
        th.keyChar('o'),
        th.keyChar('t'),
        th.keyChar('o'),
        th.keyChar(' '),
        th.keyChar('3'),
        th.keySpecial(.Enter),
    });
    try std.testing.expectEqual(@as(usize, 2), ed.currentTab().?.mainCursor().row);

    try feed(&ed, &[_]terminal.KeyEvent{
        th.keyChar(':'),
        th.keyChar('l'),
        th.keyChar('i'),
        th.keyChar('n'),
        th.keyChar('e'),
        th.keyChar(' '),
        th.keyChar('2'),
        th.keySpecial(.Enter),
    });
    try std.testing.expectEqual(@as(usize, 1), ed.currentTab().?.mainCursor().row);
}

test "Normal: Alt+O and Alt+P navigate jump history" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{ "one", "two", "three", "four" });
    defer ed.deinit();

    try feed(&ed, &[_]terminal.KeyEvent{th.keyChar('G')});
    try feed(&ed, &[_]terminal.KeyEvent{ th.keyChar('g'), th.keyChar('g') });

    const tab = ed.currentTab().?;
    try std.testing.expectEqual(@as(usize, 0), tab.mainCursor().row);

    try feed(&ed, &[_]terminal.KeyEvent{th.keyOptionChar('o')});
    try std.testing.expectEqual(@as(usize, 3), tab.mainCursor().row);

    try feed(&ed, &[_]terminal.KeyEvent{th.keyOptionChar('o')});
    try std.testing.expectEqual(@as(usize, 0), tab.mainCursor().row);

    try feed(&ed, &[_]terminal.KeyEvent{th.keyOptionChar('p')});
    try std.testing.expectEqual(@as(usize, 3), tab.mainCursor().row);
}

test "Normal: new jump after back clears forward history" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{ "one", "two", "three", "four" });
    defer ed.deinit();

    try feed(&ed, &[_]terminal.KeyEvent{th.keyChar('G')});
    try feed(&ed, &[_]terminal.KeyEvent{th.keyOptionChar('o')});
    try std.testing.expectEqual(@as(usize, 1), ed.state.jump_history.forward_stack.items.len);

    try feed(&ed, &[_]terminal.KeyEvent{
        th.keyChar(':'),
        th.keyChar('3'),
        th.keySpecial(.Enter),
    });

    try std.testing.expectEqual(@as(usize, 0), ed.state.jump_history.forward_stack.items.len);
    try std.testing.expectEqual(@as(usize, 2), ed.currentTab().?.mainCursor().row);
}

test "Normal: plain Tab is not Alt+P forward history" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{ "one", "two" });
    defer ed.deinit();

    try feed(&ed, &[_]terminal.KeyEvent{th.keyChar('G')});
    try feed(&ed, &[_]terminal.KeyEvent{th.keyOptionChar('o')});
    try std.testing.expectEqual(@as(usize, 0), ed.currentTab().?.mainCursor().row);

    try feed(&ed, &[_]terminal.KeyEvent{th.keyChar('\t')});
    try std.testing.expectEqual(@as(usize, 0), ed.currentTab().?.mainCursor().row);
}

test "Normal: jump history keys are configurable" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{ "one", "two" });
    defer ed.deinit();

    try installKeybindingOverrides(&ed, &.{
        .{
            .context = .normal,
            .sequence = keybindings.altChar('u'),
            .command = .navigation_jump_back,
            .replace_default_sequence = keybindings.altChar('o'),
        },
        .{
            .context = .normal,
            .sequence = keybindings.altChar('j'),
            .command = .navigation_jump_forward,
            .replace_default_sequence = keybindings.altChar('p'),
        },
    });

    try feed(&ed, &[_]terminal.KeyEvent{th.keyChar('G')});
    try feed(&ed, &[_]terminal.KeyEvent{th.keyOptionChar('o')});
    try std.testing.expectEqual(@as(usize, 1), ed.currentTab().?.mainCursor().row);

    try feed(&ed, &[_]terminal.KeyEvent{th.keyOptionChar('u')});
    try std.testing.expectEqual(@as(usize, 0), ed.currentTab().?.mainCursor().row);

    try feed(&ed, &[_]terminal.KeyEvent{th.keyOptionChar('j')});
    try std.testing.expectEqual(@as(usize, 1), ed.currentTab().?.mainCursor().row);
}

test "Normal: recorded file navigation can jump back and forward" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{ "one", "two", "three" });
    defer ed.deinit();

    const first_id = ed.currentTab().?.syntax_buffer_id;
    ed.currentTab().?.mainCursor().row = 2;
    ed.currentTab().?.mainCursor().col = 3;

    try navigation.recordCurrentJump(&ed);
    const second = try buffer_mod.Buffer.init(a);
    try ed.addTab(second);
    const second_id = ed.currentTab().?.syntax_buffer_id;

    try std.testing.expectEqual(second_id, ed.currentTab().?.syntax_buffer_id);

    try feed(&ed, &[_]terminal.KeyEvent{th.keyOptionChar('o')});
    try std.testing.expectEqual(first_id, ed.currentTab().?.syntax_buffer_id);
    try std.testing.expectEqual(@as(usize, 2), ed.currentTab().?.mainCursor().row);
    try std.testing.expectEqual(@as(usize, 3), ed.currentTab().?.mainCursor().col);

    try feed(&ed, &[_]terminal.KeyEvent{th.keyOptionChar('p')});
    try std.testing.expectEqual(second_id, ed.currentTab().?.syntax_buffer_id);
}

// ── Typing in Insert mode ─────────────────────────────────────────────────────

test "Insert: typing ASCII chars updates buffer" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{""});
    defer ed.deinit();

    ed.state.mode = .Insert;
    try feed(&ed, &[_]terminal.KeyEvent{
        th.keyChar('H'), th.keyChar('i'),
    });
    try expectLine(a, &ed, 0, "Hi");
}

test "Insert: Tab expands to 4 spaces" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{""});
    defer ed.deinit();

    ed.state.mode = .Insert;
    try feed(&ed, &[_]terminal.KeyEvent{
        .{ .key = .Char, .char = '\t' },
    });
    try expectLine(a, &ed, 0, "    ");
}

test "Insert: Enter splits line" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{""});
    defer ed.deinit();

    ed.state.mode = .Insert;
    try feed(&ed, &[_]terminal.KeyEvent{
        th.keyChar('a'),
        th.keySpecial(.Enter),
        th.keyChar('b'),
    });

    const tab = ed.currentTab().?;
    try std.testing.expectEqual(@as(usize, 2), tab.buf.lines.items.len);
    try expectLine(a, &ed, 0, "a");
    try expectLine(a, &ed, 1, "b");
}

test "Insert: Backspace removes previous char" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{""});
    defer ed.deinit();

    ed.state.mode = .Insert;
    try feed(&ed, &[_]terminal.KeyEvent{
        th.keyChar('a'),           th.keyChar('b'), th.keyChar('c'),
        th.keySpecial(.Backspace),
    });
    try expectLine(a, &ed, 0, "ab");
}

test "Insert: Backspace at col 0 merges with previous line" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{ "first", "second" });
    defer ed.deinit();

    ed.state.mode = .Insert;
    const tab = ed.currentTab().?;
    tab.mainCursor().row = 1;
    tab.mainCursor().col = 0;

    try feed(&ed, &[_]terminal.KeyEvent{th.keySpecial(.Backspace)});

    try std.testing.expectEqual(@as(usize, 1), tab.buf.lines.items.len);
    try expectLine(a, &ed, 0, "firstsecond");
}

test "Insert: Option+Delete deletes previous word" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{"hello world"});
    defer ed.deinit();

    ed.state.mode = .Insert;
    const tab = ed.currentTab().?;
    tab.mainCursor().col = 11;

    try feed(&ed, &[_]terminal.KeyEvent{th.keyOption(.Delete)});

    try expectLine(a, &ed, 0, "hello ");
    try std.testing.expectEqual(@as(usize, 6), tab.mainCursor().col);
}

test "Insert: Option+Delete deletes previous word when terminal sends Alt+Backspace" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{"hello world"});
    defer ed.deinit();

    ed.state.mode = .Insert;
    const tab = ed.currentTab().?;
    tab.mainCursor().col = 11;

    try feed(&ed, &[_]terminal.KeyEvent{.{ .key = .Backspace, .alt = true }});

    try expectLine(a, &ed, 0, "hello ");
    try std.testing.expectEqual(@as(usize, 6), tab.mainCursor().col);
}

test "Insert: Ctrl+Z undo and Ctrl+Y redo text edit" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{""});
    defer ed.deinit();

    ed.state.mode = .Insert;
    try feed(&ed, &[_]terminal.KeyEvent{th.keyChar('x')});
    try expectLine(a, &ed, 0, "x");

    try feed(&ed, &[_]terminal.KeyEvent{th.keyCtrl('z')});
    try expectLine(a, &ed, 0, "");

    try feed(&ed, &[_]terminal.KeyEvent{th.keyCtrl('y')});
    try expectLine(a, &ed, 0, "x");
}

test "Insert: configured indent key preserves raw Tab text" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{""});
    defer ed.deinit();
    try replaceBinding(&ed, .insert, keybindings.ctrlChar('i'), .editing_indent, keybindings.keyChar('\t'));
    ed.state.mode = .Insert;

    try feed(&ed, &[_]terminal.KeyEvent{th.keyChar('\t')});
    try expectLine(a, &ed, 0, "\t");

    try feed(&ed, &[_]terminal.KeyEvent{th.keyCtrl('i')});
    try expectLine(a, &ed, 0, "\t    ");
}

test "Normal: Ctrl+Z undo and Ctrl+Y redo text edit" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{""});
    defer ed.deinit();

    try feed(&ed, &[_]terminal.KeyEvent{ th.keyChar('i'), th.keyChar('x'), th.keySpecial(.Esc) });
    try expectLine(a, &ed, 0, "x");
    try std.testing.expectEqual(editor_mod.EditorMode.Normal, ed.state.mode);

    try feed(&ed, &[_]terminal.KeyEvent{th.keyCtrl('z')});
    try expectLine(a, &ed, 0, "");

    try feed(&ed, &[_]terminal.KeyEvent{th.keyCtrl('y')});
    try expectLine(a, &ed, 0, "x");
}

// ── Command mode ──────────────────────────────────────────────────────────────

test "Command: :q on clean tab closes it" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{"hello"});
    defer ed.deinit();

    // Mark as not dirty
    ed.currentTab().?.buf.is_dirty = false;

    try feed(&ed, &[_]terminal.KeyEvent{
        th.keyChar(':'),
        th.keyChar('q'),
        th.keySpecial(.Enter),
    });

    // After :q the tab is closed → Dashboard
    try std.testing.expectEqual(editor_mod.EditorMode.Dashboard, ed.state.mode);
    try std.testing.expectEqual(@as(usize, 0), ed.state.tabs.items.len);
}

test "Command: :q on dirty buffer opens save confirmation popup" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{"hello"});
    defer ed.deinit();

    ed.currentTab().?.buf.is_dirty = true;

    try feed(&ed, &[_]terminal.KeyEvent{
        th.keyChar(':'),
        th.keyChar('q'),
        th.keySpecial(.Enter),
    });

    // Tab stays open and the save-confirmation popup is shown
    try std.testing.expectEqual(@as(usize, 1), ed.state.tabs.items.len);
    try std.testing.expectEqual(editor_mod.EditorMode.SaveConfirmation, ed.state.mode);
    try std.testing.expect(ed.state.save_confirmation.visible);
}

test "SaveConfirmation: cancel and discard use save-confirmation context" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{"dirty"});
    defer ed.deinit();

    ed.currentTab().?.buf.is_dirty = true;
    ed.state.save_confirmation.open(null);
    ed.state.mode = .SaveConfirmation;

    try feed(&ed, &[_]terminal.KeyEvent{th.keyChar('n')});
    try std.testing.expectEqual(editor_mod.EditorMode.Normal, ed.state.mode);
    try std.testing.expect(!ed.state.save_confirmation.visible);
    try std.testing.expectEqual(@as(usize, 1), ed.state.tabs.items.len);
    try std.testing.expect(ed.currentTab().?.buf.is_dirty);

    ed.state.save_confirmation.open(null);
    ed.state.mode = .SaveConfirmation;
    try feed(&ed, &[_]terminal.KeyEvent{th.keySpecial(.Enter)});
    try std.testing.expectEqual(@as(usize, 0), ed.state.tabs.items.len);
    try std.testing.expect(!ed.state.save_confirmation.visible);
}

test "SaveConfirmation: custom prompt submit preserves default d discard only" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{"dirty"});
    defer ed.deinit();
    try replaceBinding(&ed, .save_confirmation, keybindings.ctrlChar('j'), .save_confirmation_discard, keybindings.keySpecial(.Enter));

    ed.currentTab().?.buf.is_dirty = true;
    ed.state.save_confirmation.open(null);
    ed.state.mode = .SaveConfirmation;

    try feed(&ed, &[_]terminal.KeyEvent{th.keySpecial(.Enter)});
    try std.testing.expectEqual(@as(usize, 1), ed.state.tabs.items.len);
    try std.testing.expect(ed.state.save_confirmation.visible);

    try feed(&ed, &[_]terminal.KeyEvent{th.keyChar('d')});
    try std.testing.expectEqual(@as(usize, 0), ed.state.tabs.items.len);
    try std.testing.expect(!ed.state.save_confirmation.visible);
}

test "Command: :q! force-closes dirty tab" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{"hello"});
    defer ed.deinit();

    ed.currentTab().?.buf.is_dirty = true;

    try feed(&ed, &[_]terminal.KeyEvent{
        th.keyChar(':'),
        th.keyChar('q'),
        th.keyChar('!'),
        th.keySpecial(.Enter),
    });

    try std.testing.expectEqual(@as(usize, 0), ed.state.tabs.items.len);
}

test "Command: :w saves file to disk" {
    const a = std.testing.allocator;
    const log = try th.setupLogger(a);
    defer log.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = path_buf[0..try tmp.dir.realPath(std.testing.io, &path_buf)];
    const file_path = try std.fmt.allocPrint(a, "{s}/saved.txt", .{dir_path});
    defer a.free(file_path);

    var ed = try th.makeEditor(a, &[_][]const u8{"flamingo rocks"});
    defer ed.deinit();

    // Set filename so :w knows where to write.
    try ed.currentTab().?.buf.setFilename(file_path);

    try feed(&ed, &[_]terminal.KeyEvent{
        th.keyChar(':'),
        th.keyChar('w'),
        th.keySpecial(.Enter),
    });

    // File should exist on disk.
    const stat = try std.Io.Dir.cwd().statFile(std.testing.io, file_path, .{});
    try std.testing.expect(stat.size > 0);
    try std.testing.expect(!ed.currentTab().?.buf.is_dirty);
}

test "Command: unknown command shows error, stays Normal" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{""});
    defer ed.deinit();

    try feed(&ed, &[_]terminal.KeyEvent{
        th.keyChar(':'),
        th.keyChar('z'),
        th.keyChar('z'),
        th.keyChar('z'),
        th.keySpecial(.Enter),
    });

    try std.testing.expectEqual(editor_mod.EditorMode.Normal, ed.state.mode);
    try std.testing.expect(ed.state.error_message != null);
}

test "Command popup: typing and backspace update suggestions" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{""});
    defer ed.deinit();

    try feed(&ed, &[_]terminal.KeyEvent{
        th.keyChar(':'),
        th.keyChar('w'),
        th.keyChar('q'),
    });

    try std.testing.expectEqualStrings("wq", ed.state.command_popup.input.items);
    try std.testing.expectEqual(@as(usize, 1), ed.state.command_popup.suggestions.items.len);

    try feed(&ed, &[_]terminal.KeyEvent{th.keySpecial(.Backspace)});
    try std.testing.expectEqualStrings("w", ed.state.command_popup.input.items);
    try std.testing.expectEqual(@as(usize, 4), ed.state.command_popup.suggestions.items.len);
}

test "Command popup: tab moves suggestion selection without editing input" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{""});
    defer ed.deinit();

    try feed(&ed, &[_]terminal.KeyEvent{
        th.keyChar(':'),
        th.keyChar('w'),
        th.keyChar('\t'),
    });
    try std.testing.expectEqualStrings("w", ed.state.command_popup.input.items);
    try std.testing.expectEqual(@as(?usize, 1), ed.state.command_popup.selected_index);

    try feed(&ed, &[_]terminal.KeyEvent{th.keyChar('\t')});
    try std.testing.expectEqualStrings("w", ed.state.command_popup.input.items);
    try std.testing.expectEqual(@as(?usize, 2), ed.state.command_popup.selected_index);

    try feed(&ed, &[_]terminal.KeyEvent{th.keyChar('\t')});
    try std.testing.expectEqualStrings("w", ed.state.command_popup.input.items);
    try std.testing.expectEqual(@as(?usize, 3), ed.state.command_popup.selected_index);

    try feed(&ed, &[_]terminal.KeyEvent{th.keyChar('\t')});
    try std.testing.expectEqualStrings("w", ed.state.command_popup.input.items);
    try std.testing.expectEqual(@as(?usize, 0), ed.state.command_popup.selected_index);

    try feed(&ed, &[_]terminal.KeyEvent{th.keyChar('!')});
    try std.testing.expectEqualStrings("w!", ed.state.command_popup.input.items);
}

test "Command popup: arrows move suggestion selection without editing input" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{""});
    defer ed.deinit();

    try feed(&ed, &[_]terminal.KeyEvent{
        th.keyChar(':'),
        th.keyChar('w'),
        th.keySpecial(.Down),
    });
    try std.testing.expectEqualStrings("w", ed.state.command_popup.input.items);
    try std.testing.expectEqual(@as(?usize, 1), ed.state.command_popup.selected_index);

    try feed(&ed, &[_]terminal.KeyEvent{th.keySpecial(.Up)});
    try std.testing.expectEqualStrings("w", ed.state.command_popup.input.items);
    try std.testing.expectEqual(@as(?usize, 0), ed.state.command_popup.selected_index);
}

test "Command: configured submit key executes command" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{"hello"});
    defer ed.deinit();
    try replaceBinding(&ed, .command_line, keybindings.ctrlChar('j'), .command_execute, keybindings.keySpecial(.Enter));
    ed.currentTab().?.buf.is_dirty = false;

    try feed(&ed, &[_]terminal.KeyEvent{
        th.keyChar(':'),
        th.keyChar('q'),
        th.keySpecial(.Enter),
    });
    try std.testing.expectEqual(editor_mod.EditorMode.Command, ed.state.mode);
    try std.testing.expectEqual(@as(usize, 1), ed.state.tabs.items.len);

    try feed(&ed, &[_]terminal.KeyEvent{th.keyCtrl('j')});
    try std.testing.expectEqual(editor_mod.EditorMode.Dashboard, ed.state.mode);
    try std.testing.expectEqual(@as(usize, 0), ed.state.tabs.items.len);
}

test "Command: :search enters GlobalSearch mode" {
    const a = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "alpha.txt", .data = "" });
    const root_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(root_path);

    var ed = try th.makeEditor(a, &[_][]const u8{""});
    defer ed.deinit();
    ed.state.tree = try explorer_mod.Explorer.init(a, io, root_path);

    try feed(&ed, &[_]terminal.KeyEvent{
        th.keyChar(':'),
        th.keyChar('s'),
        th.keyChar('e'),
        th.keyChar('a'),
        th.keyChar('r'),
        th.keyChar('c'),
        th.keyChar('h'),
        th.keySpecial(.Enter),
    });

    try std.testing.expectEqual(editor_mod.EditorMode.GlobalSearch, ed.state.mode);
    try std.testing.expect(ed.state.global_search.visible);
    try std.testing.expect(!ed.state.command_popup.visible);
    try std.testing.expectEqualStrings(root_path, ed.state.global_search.root_path);
}

test "Command: :help opens help popup and q closes it" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{""});
    defer ed.deinit();

    try feed(&ed, &[_]terminal.KeyEvent{
        th.keyChar(':'),
        th.keyChar('h'),
        th.keyChar('e'),
        th.keyChar('l'),
        th.keyChar('p'),
        th.keySpecial(.Enter),
    });

    try std.testing.expectEqual(editor_mod.EditorMode.Help, ed.state.mode);
    try std.testing.expect(ed.state.help_popup.visible);
    try std.testing.expect(!ed.state.command_popup.visible);

    try feed(&ed, &[_]terminal.KeyEvent{th.keyChar('q')});
    try std.testing.expectEqual(editor_mod.EditorMode.Normal, ed.state.mode);
    try std.testing.expect(!ed.state.help_popup.visible);
}

test "Help: Esc closes to dashboard when no tabs are open" {
    const a = std.testing.allocator;
    var ed = try th.makeEmptyEditor(a);
    defer ed.deinit();

    ed.state.help_popup.open();
    ed.state.mode = .Help;

    try feed(&ed, &[_]terminal.KeyEvent{th.keySpecial(.Esc)});
    try std.testing.expectEqual(editor_mod.EditorMode.Dashboard, ed.state.mode);
    try std.testing.expect(!ed.state.help_popup.visible);
}

test "Help: scrolling clamps" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{""});
    defer ed.deinit();

    ed.state.help_popup.open();
    ed.state.mode = .Help;
    try feed(&ed, &[_]terminal.KeyEvent{th.keySpecial(.PageDown)});
    try std.testing.expect(ed.state.help_popup.scroll_offset > 0);

    try feed(&ed, &[_]terminal.KeyEvent{th.keySpecial(.PageUp)});
    try std.testing.expectEqual(@as(usize, 0), ed.state.help_popup.scroll_offset);
}

test "Help: q closes popup through help context" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{""});
    defer ed.deinit();

    ed.state.help_popup.open();
    ed.state.mode = .Help;

    try feed(&ed, &[_]terminal.KeyEvent{th.keyChar('q')});
    try std.testing.expectEqual(editor_mod.EditorMode.Normal, ed.state.mode);
    try std.testing.expect(!ed.state.help_popup.visible);
}

test "GlobalSearch: Esc closes and typing/backspace refreshes query" {
    const a = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "alpha.txt", .data = "" });
    const root_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(root_path);

    var ed = try th.makeEditor(a, &[_][]const u8{""});
    defer ed.deinit();
    try ed.state.global_search.open(a, root_path);
    ed.state.mode = .GlobalSearch;

    try feed(&ed, &[_]terminal.KeyEvent{ th.keyChar('a'), th.keyChar('l') });
    try std.testing.expectEqualStrings("al", ed.state.global_search.input.items);
    try std.testing.expect(ed.state.global_search.results.items.len > 0);

    try feed(&ed, &[_]terminal.KeyEvent{th.keySpecial(.Backspace)});
    try std.testing.expectEqualStrings("a", ed.state.global_search.input.items);

    try feed(&ed, &[_]terminal.KeyEvent{th.keySpecial(.Esc)});
    try std.testing.expectEqual(editor_mod.EditorMode.Normal, ed.state.mode);
    try std.testing.expect(!ed.state.global_search.visible);
}

test "GlobalSearch: Tab Down and Up move selected result" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{""});
    defer ed.deinit();

    try ed.state.global_search.open(a, ".");
    ed.state.mode = .GlobalSearch;
    try appendGlobalSearchPathResult(a, &ed, "alpha.txt");
    try appendGlobalSearchPathResult(a, &ed, "beta.txt");
    ed.state.global_search.selected_index = 0;

    try feed(&ed, &[_]terminal.KeyEvent{th.keyChar('\t')});
    try std.testing.expectEqual(@as(?usize, 1), ed.state.global_search.selected_index);

    try feed(&ed, &[_]terminal.KeyEvent{th.keySpecial(.Down)});
    try std.testing.expectEqual(@as(?usize, 0), ed.state.global_search.selected_index);

    try feed(&ed, &[_]terminal.KeyEvent{th.keySpecial(.Up)});
    try std.testing.expectEqual(@as(?usize, 1), ed.state.global_search.selected_index);
}

test "GlobalSearch: configured select-next key is used" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{""});
    defer ed.deinit();
    try replaceBinding(&ed, .global_search, keybindings.ctrlChar('n'), .global_search_select_next, keybindings.keyChar('\t'));

    try ed.state.global_search.open(a, ".");
    ed.state.mode = .GlobalSearch;
    try appendGlobalSearchPathResult(a, &ed, "alpha.txt");
    try appendGlobalSearchPathResult(a, &ed, "beta.txt");
    ed.state.global_search.selected_index = 0;

    try feed(&ed, &[_]terminal.KeyEvent{th.keyCtrl('n')});
    try std.testing.expectEqual(@as(?usize, 1), ed.state.global_search.selected_index);
}

test "GlobalSearch: Enter on path result opens file" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const log = try th.setupLogger(a);
    defer log.deinit();

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "alpha.txt", .data = "opened\n" });
    const root_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(root_path);

    var ed = try th.makeEditor(a, &[_][]const u8{""});
    defer ed.deinit();
    try ed.state.global_search.open(a, root_path);
    ed.state.mode = .GlobalSearch;

    for ("alpha") |ch| try feed(&ed, &[_]terminal.KeyEvent{th.keyChar(ch)});
    try std.testing.expectEqual(@as(?usize, 0), ed.state.global_search.selected_index);

    try feed(&ed, &[_]terminal.KeyEvent{th.keySpecial(.Enter)});
    try std.testing.expectEqual(editor_mod.EditorMode.Normal, ed.state.mode);
    try std.testing.expect(ed.currentTab().?.buf.filename != null);
    try std.testing.expect(std.mem.endsWith(u8, ed.currentTab().?.buf.filename.?, "alpha.txt"));
}

test "GlobalSearch: Enter on content result opens file and jumps" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const log = try th.setupLogger(a);
    defer log.deinit();

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "plain.txt", .data = "first\nxxneedle here\n" });
    const root_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(root_path);

    var ed = try th.makeEditor(a, &[_][]const u8{""});
    defer ed.deinit();
    try ed.state.global_search.open(a, root_path);
    ed.state.mode = .GlobalSearch;

    for ("needle") |ch| try feed(&ed, &[_]terminal.KeyEvent{th.keyChar(ch)});
    try feed(&ed, &[_]terminal.KeyEvent{th.keySpecial(.Enter)});

    const tab = ed.currentTab().?;
    try std.testing.expect(std.mem.endsWith(u8, tab.buf.filename.?, "plain.txt"));
    try std.testing.expectEqual(@as(usize, 1), tab.mainCursor().row);
    try std.testing.expectEqual(@as(usize, 2), tab.mainCursor().col);
}

// ── Search ────────────────────────────────────────────────────────────────────

test "Search: typing query finds matches" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{
        "flamingo editor",
        "another flamingo line",
        "nothing here",
    });
    defer ed.deinit();

    try feed(&ed, &[_]terminal.KeyEvent{
        th.keyChar('/'),
        th.keyChar('f'),
        th.keyChar('l'),
        th.keyChar('a'),
    });

    const ss = ed.state.search_system.?;
    try std.testing.expect(ss.matches.items.len >= 2);
}

test "Search: Down cycles to next match" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{
        "foo bar",
        "baz foo",
        "foo end",
    });
    defer ed.deinit();

    // Manually populate search (avoids needing a fully initialised search UI path)
    ed.state.mode = .Search;
    try ed.state.search_buffer.appendSlice(a, "foo");
    try ed.state.search_system.?.update(&ed.currentTab().?.buf, "foo");

    const first_idx = ed.state.search_system.?.active_match_idx;
    try feed(&ed, &[_]terminal.KeyEvent{th.keySpecial(.Down)});
    const second_idx = ed.state.search_system.?.active_match_idx;
    try std.testing.expect(first_idx != second_idx);
}

test "Search: configured next key is used" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{
        "foo bar",
        "baz foo",
        "foo end",
    });
    defer ed.deinit();
    try replaceBinding(&ed, .search, keybindings.ctrlChar('n'), .search_next_match, keybindings.keySpecial(.Down));

    ed.state.mode = .Search;
    try ed.state.search_buffer.appendSlice(a, "foo");
    try ed.state.search_system.?.update(&ed.currentTab().?.buf, "foo");

    const first_idx = ed.state.search_system.?.active_match_idx;
    try feed(&ed, &[_]terminal.KeyEvent{th.keySpecial(.Down)});
    try std.testing.expectEqual(first_idx, ed.state.search_system.?.active_match_idx);

    try feed(&ed, &[_]terminal.KeyEvent{th.keyCtrl('n')});
    try std.testing.expect(first_idx != ed.state.search_system.?.active_match_idx);
}

test "Search: Up cycles to previous match" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{
        "foo bar",
        "baz foo",
    });
    defer ed.deinit();

    ed.state.mode = .Search;
    try ed.state.search_buffer.appendSlice(a, "foo");
    try ed.state.search_system.?.update(&ed.currentTab().?.buf, "foo");
    // Start at index 0, go back → should wrap to last
    ed.state.search_system.?.active_match_idx = 0;

    try feed(&ed, &[_]terminal.KeyEvent{th.keySpecial(.Up)});
    const idx = ed.state.search_system.?.active_match_idx.?;
    try std.testing.expect(idx > 0); // wrapped to last match
}

test "Search: cursor jumps to active match row" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{
        "nothing",
        "flamingo here",
    });
    defer ed.deinit();

    ed.state.mode = .Search;
    try feed(&ed, &[_]terminal.KeyEvent{
        th.keyChar('f'), th.keyChar('l'), th.keyChar('a'),
    });

    const mc = ed.currentTab().?.mainCursor();
    try std.testing.expectEqual(@as(usize, 1), mc.row); // match is on row 1
}

test "Search: Backspace shrinks query and re-runs search" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{"flamingo"});
    defer ed.deinit();

    ed.state.mode = .Search;
    try feed(&ed, &[_]terminal.KeyEvent{
        th.keyChar('z'), th.keyChar('z'), th.keyChar('z'),
    });
    try std.testing.expectEqual(@as(usize, 0), ed.state.search_system.?.matches.items.len);

    try feed(&ed, &[_]terminal.KeyEvent{th.keySpecial(.Backspace)});
    try std.testing.expectEqual(@as(usize, 2), ed.state.search_buffer.items.len);
}

// ── Navigation with macOS Option key ─────────────────────────────────────────

test "Option+Up: moves cursor col to end-of-line" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{ "hello", "world" });
    defer ed.deinit();

    const tab = ed.currentTab().?;
    tab.mainCursor().row = 1;
    tab.mainCursor().col = 2;

    // Option+Up in handleMovement sets col = line.len()
    try feed(&ed, &[_]terminal.KeyEvent{th.keyOption(.Up)});
    // Cursor stays on same row, col moves to end (5 for "world")
    try std.testing.expectEqual(@as(usize, 1), tab.mainCursor().row);
    try std.testing.expectEqual(@as(usize, 5), tab.mainCursor().col);
}

test "Insert: Option+Up clamps a stale cursor before inserting" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{"hello"});
    defer ed.deinit();

    const tab = ed.currentTab().?;
    tab.mainCursor().row = 99;
    tab.mainCursor().col = 99;
    ed.state.mode = .Insert;

    try feed(&ed, &[_]terminal.KeyEvent{ th.keyOption(.Up), th.keyChar('!') });

    try expectLine(a, &ed, 0, "hello!");
    try std.testing.expectEqual(@as(usize, 0), tab.mainCursor().row);
    try std.testing.expectEqual(@as(usize, 6), tab.mainCursor().col);
}

test "Option+Down: moves cursor col to start-of-line" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{ "hello", "world" });
    defer ed.deinit();

    const tab = ed.currentTab().?;
    tab.mainCursor().row = 0;
    tab.mainCursor().col = 3;

    try feed(&ed, &[_]terminal.KeyEvent{th.keyOption(.Down)});
    // Option+Down in handleMovement: alt=true, ctrl=false → sets col=0.
    try std.testing.expectEqual(@as(usize, 0), tab.mainCursor().row);
    try std.testing.expectEqual(@as(usize, 0), tab.mainCursor().col);
}

test "Option+Left: word jump moves cursor left" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{"hello world"});
    defer ed.deinit();

    const tab = ed.currentTab().?;
    tab.mainCursor().col = 11; // end of line

    try feed(&ed, &[_]terminal.KeyEvent{th.keyOption(.Left)});
    try std.testing.expect(tab.mainCursor().col < 11);
}

test "Option+Right: word jump moves cursor right" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{"hello world"});
    defer ed.deinit();

    const tab = ed.currentTab().?;
    tab.mainCursor().col = 0;

    try feed(&ed, &[_]terminal.KeyEvent{th.keyOption(.Right)});
    try std.testing.expect(tab.mainCursor().col > 0);
}

test "Vertical movement preserves preferred column across short lines" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{ "abcdefghij", "xy", "abcdefghij" });
    defer ed.deinit();

    const tab = ed.currentTab().?;
    tab.mainCursor().row = 0;
    tab.mainCursor().col = 8;

    try feed(&ed, &[_]terminal.KeyEvent{th.keySpecial(.Down)});
    try std.testing.expectEqual(@as(usize, 1), tab.mainCursor().row);
    try std.testing.expectEqual(@as(usize, 2), tab.mainCursor().col);
    try std.testing.expectEqual(@as(?usize, 8), tab.mainCursor().preferred_col);

    try feed(&ed, &[_]terminal.KeyEvent{th.keySpecial(.Down)});
    try std.testing.expectEqual(@as(usize, 2), tab.mainCursor().row);
    try std.testing.expectEqual(@as(usize, 8), tab.mainCursor().col);
    try std.testing.expectEqual(@as(?usize, 8), tab.mainCursor().preferred_col);
}

test "Horizontal movement resets preferred column" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{ "abcdefghij", "xy", "abcdefghij" });
    defer ed.deinit();

    const tab = ed.currentTab().?;
    tab.mainCursor().row = 0;
    tab.mainCursor().col = 8;

    try feed(&ed, &[_]terminal.KeyEvent{ th.keySpecial(.Down), th.keySpecial(.Left) });
    try std.testing.expectEqual(@as(usize, 1), tab.mainCursor().row);
    try std.testing.expectEqual(@as(usize, 1), tab.mainCursor().col);
    try std.testing.expectEqual(@as(?usize, null), tab.mainCursor().preferred_col);
}

test "Normal: PageDown and PageUp move by the visible page" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{
        "row0",
        "row1",
        "row2",
        "row3",
        "row4",
        "row5",
    });
    defer ed.deinit();
    ed.height = 4;

    const tab = ed.currentTab().?;
    tab.mainCursor().row = 0;

    try feed(&ed, &[_]terminal.KeyEvent{th.keySpecial(.PageDown)});
    try std.testing.expect(tab.mainCursor().row > 0);

    try feed(&ed, &[_]terminal.KeyEvent{th.keySpecial(.PageUp)});
    try std.testing.expectEqual(@as(usize, 0), tab.mainCursor().row);
}

test "Option+] cycles to next tab" {
    const a = std.testing.allocator;
    var ed = try th.makeEmptyEditor(a);
    defer ed.deinit();

    const b0 = try buffer_mod.Buffer.init(a);
    try ed.addTab(b0);
    const b1 = try buffer_mod.Buffer.init(a);
    try ed.addTab(b1);
    ed.state.active_tab_index = 0;

    try feed(&ed, &[_]terminal.KeyEvent{th.keyOptionChar(']')});
    try std.testing.expectEqual(@as(usize, 1), ed.state.active_tab_index);
}

test "Option+[ cycles to previous tab" {
    const a = std.testing.allocator;
    var ed = try th.makeEmptyEditor(a);
    defer ed.deinit();

    const b0 = try buffer_mod.Buffer.init(a);
    try ed.addTab(b0);
    const b1 = try buffer_mod.Buffer.init(a);
    try ed.addTab(b1);
    ed.state.active_tab_index = 1;

    // Option+[ is represented as alt=true, key=Char, char='['.
    try feed(&ed, &[_]terminal.KeyEvent{th.keyOptionChar('[')});
    try std.testing.expectEqual(@as(usize, 0), ed.state.active_tab_index);
}

test "Ctrl+Option+Up: addCursorAbove" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{ "row0", "row1", "row2" });
    defer ed.deinit();

    // Must be in Normal mode for ctrl+alt shortcuts to be processed.
    ed.state.mode = .Normal;
    ed.currentTab().?.mainCursor().row = 2;
    try feed(&ed, &[_]terminal.KeyEvent{th.keyCtrlOption(.Up)});
    try std.testing.expectEqual(@as(usize, 2), ed.currentTab().?.cursors.items.len);
}

test "Ctrl+Option+Down: addCursorBelow" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{ "row0", "row1", "row2" });
    defer ed.deinit();

    // Must be in Normal mode for ctrl+alt shortcuts to be processed.
    ed.state.mode = .Normal;
    ed.currentTab().?.mainCursor().row = 0;
    try feed(&ed, &[_]terminal.KeyEvent{th.keyCtrlOption(.Down)});
    try std.testing.expectEqual(@as(usize, 2), ed.currentTab().?.cursors.items.len);
}

test "Shift+Up: extends selection" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{ "line0", "line1" });
    defer ed.deinit();

    const tab = ed.currentTab().?;
    tab.mainCursor().row = 1;
    tab.mainCursor().col = 3;

    try feed(&ed, &[_]terminal.KeyEvent{th.keyShift(.Up)});
    try std.testing.expect(tab.mainCursor().selection_start != null);
}

// ── Explorer & tab control ────────────────────────────────────────────────────

test "configured default Ctrl+B toggles explorer_visible" {
    const a = std.testing.allocator;
    // Explorer.init calls logz.info(), so we must set up the logger first.
    const log = try th.setupLogger(a);
    defer log.deinit();

    var ed = try th.makeEditor(a, &[_][]const u8{""});
    defer ed.deinit();

    try std.testing.expect(!ed.state.explorer_visible);
    try feed(&ed, &[_]terminal.KeyEvent{th.keyCtrl('b')});
    try std.testing.expect(ed.state.explorer_visible);
    try feed(&ed, &[_]terminal.KeyEvent{th.keyCtrl('b')});
    try std.testing.expect(!ed.state.explorer_visible);
}

test "configured toggle_explorer key is used" {
    const a = std.testing.allocator;
    const log = try th.setupLogger(a);
    defer log.deinit();

    var ed = try th.makeEditor(a, &[_][]const u8{""});
    defer ed.deinit();
    try replaceBinding(&ed, .global, keybindings.ctrlChar('g'), .explorer_toggle, keybindings.ctrlChar('b'));

    try feed(&ed, &[_]terminal.KeyEvent{th.keyCtrl('b')});
    try std.testing.expect(!ed.state.explorer_visible);

    try feed(&ed, &[_]terminal.KeyEvent{th.keyCtrl('g')});
    try std.testing.expect(ed.state.explorer_visible);
}

test "Ctrl+T toggles terminal panel and enters Terminal mode" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{""});
    defer ed.deinit();

    try std.testing.expect(!ed.terminal_panel.visible);
    try feed(&ed, &[_]terminal.KeyEvent{th.keyCtrl('t')});

    try std.testing.expect(ed.terminal_panel.visible);
    try std.testing.expect(ed.terminal_panel.focused);
    try std.testing.expectEqual(editor_mod.EditorMode.Terminal, ed.state.mode);

    try feed(&ed, &[_]terminal.KeyEvent{th.keyCtrl('t')});
    try std.testing.expect(!ed.terminal_panel.visible);
    try std.testing.expect(!ed.terminal_panel.focused);
    try std.testing.expectEqual(editor_mod.EditorMode.Normal, ed.state.mode);
}

test "configured toggle_terminal key is used" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{""});
    defer ed.deinit();
    try replaceBinding(&ed, .global, keybindings.ctrlChar('g'), .terminal_toggle, keybindings.ctrlChar('t'));

    try feed(&ed, &[_]terminal.KeyEvent{th.keyCtrl('t')});
    try std.testing.expect(!ed.terminal_panel.visible);

    try feed(&ed, &[_]terminal.KeyEvent{th.keyCtrl('g')});
    try std.testing.expect(ed.terminal_panel.visible);
    try std.testing.expect(ed.terminal_panel.focused);
    try std.testing.expectEqual(editor_mod.EditorMode.Terminal, ed.state.mode);
}

test "Terminal mode Esc blurs terminal but keeps panel visible" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{""});
    defer ed.deinit();

    try feed(&ed, &[_]terminal.KeyEvent{th.keyCtrl('t')});
    try feed(&ed, &[_]terminal.KeyEvent{th.keySpecial(.Esc)});

    try std.testing.expect(ed.terminal_panel.visible);
    try std.testing.expect(!ed.terminal_panel.focused);
    try std.testing.expectEqual(editor_mod.EditorMode.Normal, ed.state.mode);
}

test "Terminal mode scroll controls use terminal context and text passes through" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{""});
    defer ed.deinit();
    ed.height = 8;

    try feed(&ed, &[_]terminal.KeyEvent{th.keyCtrl('t')});
    try ed.terminal_panel.appendOutput("one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\n");

    try feed(&ed, &[_]terminal.KeyEvent{th.keySpecial(.PageUp)});
    try std.testing.expect(ed.terminal_panel.scroll_offset > 0);

    try feed(&ed, &[_]terminal.KeyEvent{th.keyShift(.End)});
    try std.testing.expectEqual(@as(usize, 0), ed.terminal_panel.scroll_offset);

    try feed(&ed, &[_]terminal.KeyEvent{th.keyChar('x')});
    try std.testing.expectEqual(editor_mod.EditorMode.Terminal, ed.state.mode);
    try std.testing.expect(ed.terminal_panel.focused);
}

test "Ctrl+E cycles focus between editor explorer and terminal" {
    const a = std.testing.allocator;
    const log = try th.setupLogger(a);
    defer log.deinit();

    var ed = try th.makeEditor(a, &[_][]const u8{""});
    defer ed.deinit();

    try feed(&ed, &[_]terminal.KeyEvent{th.keyCtrl('b')});
    try std.testing.expect(ed.state.explorer_visible);
    try std.testing.expect(ed.state.explorer_focused);

    try feed(&ed, &[_]terminal.KeyEvent{th.keyCtrl('t')});
    try std.testing.expect(ed.terminal_panel.visible);
    try std.testing.expect(ed.terminal_panel.focused);
    try std.testing.expect(!ed.state.explorer_focused);

    try feed(&ed, &[_]terminal.KeyEvent{th.keyCtrl('e')});
    try std.testing.expect(!ed.terminal_panel.focused);
    try std.testing.expect(!ed.state.explorer_focused);
    try std.testing.expectEqual(editor_mod.EditorMode.Normal, ed.state.mode);

    try feed(&ed, &[_]terminal.KeyEvent{th.keyCtrl('e')});
    try std.testing.expect(ed.state.explorer_focused);
    try std.testing.expect(!ed.terminal_panel.focused);

    try feed(&ed, &[_]terminal.KeyEvent{th.keyCtrl('e')});
    try std.testing.expect(!ed.state.explorer_focused);
    try std.testing.expect(ed.terminal_panel.focused);
    try std.testing.expectEqual(editor_mod.EditorMode.Terminal, ed.state.mode);
}

test "Ctrl+W closes current tab" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{"hello"});
    defer ed.deinit();

    try std.testing.expectEqual(@as(usize, 1), ed.state.tabs.items.len);
    try feed(&ed, &[_]terminal.KeyEvent{th.keyCtrl('w')});
    try std.testing.expectEqual(@as(usize, 0), ed.state.tabs.items.len);
}

test "configured close_tab key is used" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{"hello"});
    defer ed.deinit();
    try replaceBinding(&ed, .global, keybindings.ctrlChar('u'), .app_close_tab, keybindings.ctrlChar('w'));

    try feed(&ed, &[_]terminal.KeyEvent{th.keyCtrl('w')});
    try std.testing.expectEqual(@as(usize, 1), ed.state.tabs.items.len);

    try feed(&ed, &[_]terminal.KeyEvent{th.keyCtrl('u')});
    try std.testing.expectEqual(@as(usize, 0), ed.state.tabs.items.len);
}

test "configured Ctrl+Shift+K delete_line works when terminal reports Ctrl+K" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{ "keep", "delete", "also keep" });
    defer ed.deinit();

    ed.currentTab().?.mainCursor().row = 1;
    try feed(&ed, &[_]terminal.KeyEvent{th.keyCtrl('k')});

    const tab = ed.currentTab().?;
    try std.testing.expectEqual(@as(usize, 2), tab.buf.lines.items.len);
    try expectLine(a, &ed, 0, "keep");
    try expectLine(a, &ed, 1, "also keep");
}

test "configured Ctrl+E switches explorer focus" {
    const a = std.testing.allocator;
    const log = try th.setupLogger(a);
    defer log.deinit();

    var ed = try th.makeEditor(a, &[_][]const u8{""});
    defer ed.deinit();
    try feed(&ed, &[_]terminal.KeyEvent{th.keyCtrl('b')});
    try std.testing.expect(ed.state.explorer_visible);
    try std.testing.expect(ed.state.explorer_focused);

    try feed(&ed, &[_]terminal.KeyEvent{th.keyCtrl('e')});
    try std.testing.expect(!ed.state.explorer_focused);
}

test "Explorer: Option+N opens new file prompt before edit shortcuts" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const log = try th.setupLogger(a);
    defer log.deinit();

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(root_path);

    var ed = try th.makeEditor(a, &[_][]const u8{"hello"});
    defer ed.deinit();
    try attachFocusedExplorer(a, io, &ed, root_path);

    try feed(&ed, &[_]terminal.KeyEvent{th.keyOptionChar('n')});

    try std.testing.expectEqual(editor_mod.EditorMode.Prompt, ed.state.mode);
    try std.testing.expect(ed.state.prompt_popup.visible);
    try std.testing.expectEqual(prompt_mod.PromptKind.explorer_new_file, ed.state.prompt_popup.kind);
}

test "Explorer: Option+R opens rename prompt" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const log = try th.setupLogger(a);
    defer log.deinit();

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "alpha.txt", .data = "" });
    const root_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(root_path);

    var ed = try th.makeEditor(a, &[_][]const u8{"hello"});
    defer ed.deinit();
    try attachFocusedExplorer(a, io, &ed, root_path);

    try feed(&ed, &[_]terminal.KeyEvent{th.keyOptionChar('r')});

    try std.testing.expectEqual(editor_mod.EditorMode.Prompt, ed.state.mode);
    try std.testing.expect(ed.state.prompt_popup.visible);
    try std.testing.expectEqual(prompt_mod.PromptKind.explorer_rename, ed.state.prompt_popup.kind);
    try std.testing.expectEqualStrings("alpha.txt", ed.state.prompt_popup.input.items);
}

test "Explorer: Up and Down move selection" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const log = try th.setupLogger(a);
    defer log.deinit();

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "alpha.txt", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "beta.txt", .data = "" });
    const root_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(root_path);

    var ed = try th.makeEditor(a, &[_][]const u8{"hello"});
    defer ed.deinit();
    try attachFocusedExplorer(a, io, &ed, root_path);

    try std.testing.expectEqual(@as(usize, 0), ed.state.tree.?.selected_index);

    try feed(&ed, &[_]terminal.KeyEvent{th.keySpecial(.Down)});
    try std.testing.expectEqual(@as(usize, 1), ed.state.tree.?.selected_index);

    try feed(&ed, &[_]terminal.KeyEvent{th.keySpecial(.Up)});
    try std.testing.expectEqual(@as(usize, 0), ed.state.tree.?.selected_index);
}

test "Explorer: configured movement key remains available" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const log = try th.setupLogger(a);
    defer log.deinit();

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "alpha.txt", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "beta.txt", .data = "" });
    const root_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(root_path);

    var ed = try th.makeEditor(a, &[_][]const u8{"hello"});
    defer ed.deinit();
    try replaceBinding(&ed, .explorer, keybindings.ctrlChar('j'), .explorer_move_down, keybindings.keySpecial(.Down));
    try attachFocusedExplorer(a, io, &ed, root_path);

    try feed(&ed, &[_]terminal.KeyEvent{th.keySpecial(.Down)});
    try std.testing.expectEqual(@as(usize, 0), ed.state.tree.?.selected_index);

    try feed(&ed, &[_]terminal.KeyEvent{th.keyCtrl('j')});
    try std.testing.expectEqual(@as(usize, 1), ed.state.tree.?.selected_index);
}

test "Explorer: Option+Delete opens delete prompt" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const log = try th.setupLogger(a);
    defer log.deinit();

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "alpha.txt", .data = "" });
    const root_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(root_path);

    var ed = try th.makeEditor(a, &[_][]const u8{"hello"});
    defer ed.deinit();
    try attachFocusedExplorer(a, io, &ed, root_path);

    try feed(&ed, &[_]terminal.KeyEvent{th.keyOption(.Delete)});

    try std.testing.expectEqual(editor_mod.EditorMode.Prompt, ed.state.mode);
    try std.testing.expect(ed.state.prompt_popup.visible);
    try std.testing.expectEqual(prompt_mod.PromptKind.explorer_delete_confirm, ed.state.prompt_popup.kind);
}

test "ExplorerSearch: query editing selection movement and cancel" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const log = try th.setupLogger(a);
    defer log.deinit();

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "alpha.txt", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "alpine.txt", .data = "" });
    const root_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(root_path);

    var ed = try th.makeEditor(a, &[_][]const u8{"hello"});
    defer ed.deinit();
    try attachFocusedExplorer(a, io, &ed, root_path);

    try feed(&ed, &[_]terminal.KeyEvent{ th.keyChar('/'), th.keyChar('a'), th.keyChar('l') });
    try std.testing.expect(ed.state.tree.?.search_active);
    try std.testing.expectEqualStrings("al", ed.state.tree.?.search_query.items);
    try std.testing.expect(ed.state.tree.?.search_results.items.len >= 2);
    try std.testing.expectEqual(@as(usize, 0), ed.state.tree.?.search_selected_index);

    try feed(&ed, &[_]terminal.KeyEvent{th.keySpecial(.Down)});
    try std.testing.expectEqual(@as(usize, 1), ed.state.tree.?.search_selected_index);

    try feed(&ed, &[_]terminal.KeyEvent{th.keySpecial(.Up)});
    try std.testing.expectEqual(@as(usize, 0), ed.state.tree.?.search_selected_index);

    try feed(&ed, &[_]terminal.KeyEvent{th.keySpecial(.Backspace)});
    try std.testing.expectEqualStrings("a", ed.state.tree.?.search_query.items);

    try feed(&ed, &[_]terminal.KeyEvent{th.keySpecial(.Esc)});
    try std.testing.expect(!ed.state.tree.?.search_active);
    try std.testing.expectEqualStrings("", ed.state.tree.?.search_query.items);
}

test "Prompt: text backspace and cancel use prompt context" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{"hello"});
    defer ed.deinit();

    try ed.state.prompt_popup.open(a, .explorer_rename, "Rename", "alpha.txt", "");
    ed.state.mode = .Prompt;

    try feedText(&ed, "new");
    try std.testing.expectEqualStrings("new", ed.state.prompt_popup.input.items);

    try feed(&ed, &[_]terminal.KeyEvent{th.keySpecial(.Backspace)});
    try std.testing.expectEqualStrings("ne", ed.state.prompt_popup.input.items);

    try feed(&ed, &[_]terminal.KeyEvent{th.keySpecial(.Esc)});
    try std.testing.expectEqual(editor_mod.EditorMode.Normal, ed.state.mode);
    try std.testing.expect(!ed.state.prompt_popup.visible);
}

test "Prompt: delete confirmation uses y and n command keys without raw text" {
    const a = std.testing.allocator;
    var ed = try th.makeEditor(a, &[_][]const u8{"hello"});
    defer ed.deinit();

    try ed.state.prompt_popup.open(a, .explorer_delete_confirm, "Delete", "alpha.txt", "");
    ed.state.mode = .Prompt;

    try feed(&ed, &[_]terminal.KeyEvent{th.keyChar('n')});
    try std.testing.expectEqual(editor_mod.EditorMode.Normal, ed.state.mode);
    try std.testing.expect(!ed.state.prompt_popup.visible);
    try std.testing.expectEqualStrings("", ed.state.prompt_popup.input.items);
}

test "plain Tab inserts indentation when explorer is visible" {
    const a = std.testing.allocator;
    const log = try th.setupLogger(a);
    defer log.deinit();

    var ed = try th.makeEditor(a, &[_][]const u8{""});
    defer ed.deinit();

    try feed(&ed, &[_]terminal.KeyEvent{th.keyCtrl('b')});
    try std.testing.expect(ed.state.explorer_visible);
    try std.testing.expect(ed.state.explorer_focused);

    ed.state.mode = .Insert;
    ed.state.explorer_focused = false;

    try feed(&ed, &[_]terminal.KeyEvent{th.keyChar('\t')});
    try expectLine(a, &ed, 0, "    ");
    try std.testing.expect(!ed.state.explorer_focused);
}

test "Ctrl+S saves current file" {
    const a = std.testing.allocator;
    const log = try th.setupLogger(a);
    defer log.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = path_buf[0..try tmp.dir.realPath(std.testing.io, &path_buf)];
    const file_path = try std.fmt.allocPrint(a, "{s}/ctrl_s.txt", .{dir_path});
    defer a.free(file_path);

    var ed = try th.makeEditor(a, &[_][]const u8{"saved by ctrl+s"});
    defer ed.deinit();

    try ed.currentTab().?.buf.setFilename(file_path);
    ed.currentTab().?.buf.is_dirty = true;
    ed.state.mode = .Normal;

    try feed(&ed, &[_]terminal.KeyEvent{th.keyCtrl('s')});

    try std.testing.expect(!ed.currentTab().?.buf.is_dirty);
}
