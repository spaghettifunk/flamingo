const buffer = @import("../model/buffer.zig");
const commands = @import("../commands.zig");
const command_keybindings = @import("../keybindings.zig");
const state_mod = @import("../state/state.zig");
const tab_mod = @import("../model/tab.zig");
const terminal = @import("../../terminal.zig");

pub const max_movement_coalesce_batch_count = 64;

pub const CoalescedMovement = enum {
    up,
    down,
    left,
    right,
};

pub const MovementCoalesceStopReason = enum {
    none,
    not_eligible,
    no_pending_input,
    different_key,
    mode_changed,
    overlay_active,
    selection_active,
    max_batch,
    pending_sequence,
    read_error,
    unknown,

    pub fn name(self: MovementCoalesceStopReason) []const u8 {
        return switch (self) {
            .none => "none",
            .not_eligible => "not_eligible",
            .no_pending_input => "no_pending_input",
            .different_key => "different_key",
            .mode_changed => "mode_changed",
            .overlay_active => "overlay_active",
            .selection_active => "selection_active",
            .max_batch => "max_batch",
            .pending_sequence => "pending_sequence",
            .read_error => "read_error",
            .unknown => "unknown",
        };
    }
};

pub const MovementCoalesceSnapshot = struct {
    mode: state_mod.EditorMode,
    active_tab_index: usize,
    tab_count: usize,
    buffer_ptr: *const buffer.Buffer,
    buffer_revision: u64,
    cursor_count: usize,
};

pub const CoalescingCandidate = struct {
    movement: CoalescedMovement,
    event: terminal.KeyEvent,
    snapshot: MovementCoalesceSnapshot,
};

pub const MovementCoalesceEligibility = union(enum) {
    eligible: CoalescingCandidate,
    blocked: MovementCoalesceStopReason,
};

pub fn movementCoalescingEligibilityBefore(editor: anytype, event: terminal.KeyEvent) MovementCoalesceEligibility {
    if (editor.state.mode != .Normal and editor.state.mode != .Insert) return .{ .blocked = .overlay_active };
    if (editor.state.error_message != null) return .{ .blocked = .not_eligible };
    if (editor.state.explorer_focused) return .{ .blocked = .overlay_active };
    if (editor.state.lsp_ui.completion_active) return .{ .blocked = .overlay_active };
    if (editor.state.search_buffer.items.len > 0) return .{ .blocked = .overlay_active };
    if (editor.state.tree) |tree| {
        if (tree.search_active) return .{ .blocked = .overlay_active };
    }
    if (editor.state.mode == .Normal and editor.state.pending_normal_sequence.len > 0) {
        return .{ .blocked = .pending_sequence };
    }
    if (event.shift) return .{ .blocked = .selection_active };

    const movement = coalescedMovementForEvent(editor, event) orelse return .{ .blocked = .not_eligible };
    if (matchesNonSimpleMovement(editor, event)) return .{ .blocked = .not_eligible };
    const tab = editor.currentTab() orelse return .{ .blocked = .not_eligible };
    if (tab.cursors.items.len != 1) return .{ .blocked = .not_eligible };
    if (hasActiveSelection(tab)) return .{ .blocked = .selection_active };

    return .{ .eligible = .{
        .movement = movement,
        .event = event,
        .snapshot = .{
            .mode = editor.state.mode,
            .active_tab_index = editor.state.active_tab_index,
            .tab_count = editor.state.tabs.items.len,
            .buffer_ptr = &tab.buf,
            .buffer_revision = tab.buf.revision,
            .cursor_count = tab.cursors.items.len,
        },
    } };
}

pub fn coalescedMovementForEvent(editor: anytype, event: terminal.KeyEvent) ?CoalescedMovement {
    if (event.ctrl or event.alt or event.shift) return null;

    const allowed_key = switch (event.key) {
        .Up, .Down, .Left, .Right => true,
        .Char => editor.state.mode == .Normal and
            (event.char == 'h' or event.char == 'j' or event.char == 'k' or event.char == 'l'),
        else => false,
    };
    if (!allowed_key) return null;

    const context: commands.CommandContext = if (editor.state.mode == .Insert) .insert else .normal;
    const command = resolveDefaultContextCommand(editor, context, event) orelse return null;
    return switch (command) {
        .navigation_move_up => .up,
        .navigation_move_down => .down,
        .navigation_move_left => .left,
        .navigation_move_right => .right,
        else => null,
    };
}

pub fn matchesNonSimpleMovement(editor: anytype, event: terminal.KeyEvent) bool {
    const context: commands.CommandContext = if (editor.state.mode == .Insert) .insert else .normal;
    const command = resolveDefaultContextCommand(editor, context, event) orelse return false;
    return switch (command) {
        .navigation_line_start,
        .navigation_line_end,
        .navigation_word_left,
        .navigation_word_right,
        => true,
        else => false,
    };
}

pub fn coalescingStopReasonAfterMovement(editor: anytype, snapshot: MovementCoalesceSnapshot) ?MovementCoalesceStopReason {
    if (editor.state.mode != snapshot.mode) return .mode_changed;
    if (editor.state.mode != .Normal and editor.state.mode != .Insert) return .mode_changed;
    if (editor.state.explorer_focused) return .overlay_active;
    if (editor.state.lsp_ui.completion_active) return .overlay_active;
    if (editor.state.search_buffer.items.len > 0) return .overlay_active;
    if (editor.state.tree) |tree| {
        if (tree.search_active) return .overlay_active;
    }
    if (editor.state.mode == .Normal and editor.state.pending_normal_sequence.len > 0) return .pending_sequence;
    if (editor.state.tabs.items.len != snapshot.tab_count) return .unknown;
    if (editor.state.active_tab_index != snapshot.active_tab_index) return .unknown;

    const tab = editor.currentTab() orelse return .unknown;
    if (&tab.buf != snapshot.buffer_ptr) return .unknown;
    if (tab.buf.revision != snapshot.buffer_revision) return .unknown;
    if (tab.cursors.items.len != snapshot.cursor_count) return .unknown;
    if (hasActiveSelection(tab)) return .selection_active;
    return null;
}

pub fn coalescingStopReasonForNext(
    editor: anytype,
    candidate: CoalescingCandidate,
    event: terminal.KeyEvent,
    batch_count: usize,
) ?MovementCoalesceStopReason {
    if (batch_count >= max_movement_coalesce_batch_count) return .max_batch;
    if (event.key == .None) return .no_pending_input;
    if (coalescingStopReasonAfterMovement(editor, candidate.snapshot)) |reason| return reason;
    const movement = coalescedMovementForEvent(editor, event) orelse return .different_key;
    if (movement != candidate.movement or !event.eql(candidate.event)) return .different_key;
    return null;
}

pub fn hasActiveSelection(tab: *const tab_mod.Tab) bool {
    for (tab.cursors.items) |cursor| {
        if (cursor.selection_start != null) return true;
    }
    return false;
}

fn resolveDefaultContextCommand(editor: anytype, context: commands.CommandContext, event: terminal.KeyEvent) ?commands.CommandId {
    const result = editor.keybinding_registry.resolve(context, command_keybindings.KeySequence.fromEvent(event));
    return switch (result) {
        .command => |command| command,
        else => null,
    };
}
