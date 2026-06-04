const std = @import("std");
const prompt_popup = @import("../prompt_popup.zig");
const viewport_mod = @import("../navigation/viewport.zig");
const popup = @import("popup.zig");

pub fn promptFooter(kind: prompt_popup.PromptKind) []const u8 {
    return switch (kind) {
        .explorer_new_file => "Enter create  Backspace edit  Esc cancel",
        .explorer_new_folder => "Enter create  Backspace edit  Esc cancel",
        .explorer_rename => "Enter rename  Backspace edit  Esc cancel",
        .explorer_delete_confirm => "Enter/y confirm  Esc/n cancel",
        .todo_new => "Enter create  Backspace edit  Esc cancel",
        .todo_edit => "Enter update  Backspace edit  Esc cancel",
        .todo_delete_confirm => "Enter/y confirm  Esc/n cancel",
        .comment_new => "Enter save  Backspace edit  Esc cancel",
        .comment_reply => "Enter reply  Backspace edit  Esc cancel",
        .comment_edit => "Enter update  Backspace edit  Esc cancel",
        .comment_delete_confirm => "Enter/y confirm  Esc/n cancel",
    };
}

fn popupGeometry(editor: anytype, visible: bool, item_count: usize, show_items: bool, max_visible_items: usize) ?popup.CommandPopupGeometry {
    const viewport = viewport_mod.bufferViewportGeometry(editor);
    return popup.popupGeometry(
        editor.height,
        viewport.start_col,
        viewport.width,
        visible,
        item_count,
        show_items,
        max_visible_items,
    );
}

pub fn renderVirtualPromptPopup(editor: anytype) void {
    if (!editor.state.prompt_popup.visible) return;
    const popup_state = &editor.state.prompt_popup;
    const geom = popupGeometry(editor, true, 4, true, 4) orelse return;
    const inner_width = geom.width - 2;
    popup.drawVirtualPopupTop(&editor.renderer.screen, geom, popup_state.title, .command_popup_border);

    const body_row = geom.row + 1;
    popup.drawVirtualPopupRow(&editor.renderer.screen, body_row, geom.col, geom.width, .command_popup_border, .command_popup);
    if (popup_state.kind == .explorer_delete_confirm or popup_state.kind == .todo_delete_confirm or popup_state.kind == .comment_delete_confirm) {
        var col = geom.col + 2;
        const label = if (popup_state.kind == .todo_delete_confirm)
            "Delete TODO "
        else if (popup_state.kind == .comment_delete_confirm)
            "Delete comment "
        else
            "Delete ";
        popup.writeVirtualTruncated(&editor.renderer.screen, body_row, &col, geom.col + geom.width - 1, label, .command_popup);
        popup.writeVirtualTruncated(&editor.renderer.screen, body_row, &col, geom.col + geom.width - 1, popup_state.context_path, .command_popup);
        popup.writeVirtualTruncated(&editor.renderer.screen, body_row, &col, geom.col + geom.width - 1, "?", .command_popup);
    } else {
        const shown_context = popup_state.context_path[0..@min(popup_state.context_path.len, inner_width / 2)];
        var col = geom.col + 2;
        popup.writeVirtualTruncated(&editor.renderer.screen, body_row, &col, geom.col + geom.width - 1, shown_context, .command_popup);
        popup.writeVirtualTruncated(&editor.renderer.screen, body_row, &col, geom.col + geom.width - 1, " > ", .command_popup);
        popup.writeVirtualTruncated(&editor.renderer.screen, body_row, &col, geom.col + geom.width - 1, popup_state.input.items, .command_popup);
    }

    var row_offset: usize = 2;
    if (popup_state.error_message) |msg| {
        const row = geom.row + row_offset;
        popup.drawVirtualPopupRow(&editor.renderer.screen, row, geom.col, geom.width, .command_popup_border, .popup_error);
        editor.renderer.screen.writeText(row, geom.col + 2, msg[0..@min(msg.len, inner_width -| 2)], .popup_error);
        row_offset += 1;
    }

    const separator_row = geom.row + row_offset;
    popup.drawVirtualPopupSeparator(&editor.renderer.screen, separator_row, geom.col, geom.width, .command_popup_border);
    row_offset += 1;

    const footer_row = geom.row + row_offset;
    popup.drawVirtualPopupRow(&editor.renderer.screen, footer_row, geom.col, geom.width, .command_popup_border, .popup_footer);
    const footer = promptFooter(popup_state.kind);
    editor.renderer.screen.writeText(footer_row, geom.col + 2, footer[0..@min(footer.len, inner_width -| 2)], .popup_footer);
    popup.drawVirtualPopupBottom(&editor.renderer.screen, footer_row + 1, geom.col, geom.width, .command_popup_border);
}

pub fn renderVirtualSaveConfirmationPopup(editor: anytype) void {
    if (!editor.state.save_confirmation.visible) return;
    const popup_state = &editor.state.save_confirmation;
    const geom = popupGeometry(editor, true, 0, false, 0) orelse return;
    const inner_width = geom.width - 2;

    // Title row
    popup.drawVirtualPopupTop(&editor.renderer.screen, geom, " Save File ", .command_popup_border);

    // Body: show filename
    const body_row = geom.row + 1;
    popup.drawVirtualPopupRow(&editor.renderer.screen, body_row, geom.col, geom.width, .command_popup_border, .command_popup);
    const display = popup_state.displayName();
    const shown = display[0..@min(display.len, inner_width -| 4)];
    var name_buf: [256]u8 = undefined;
    const name_line = std.fmt.bufPrint(&name_buf, "  {s}", .{shown}) catch "";
    editor.renderer.screen.writeText(body_row, geom.col + 2, name_line[0..@min(name_line.len, inner_width -| 2)], .command_popup);

    // Separator
    const sep_row = geom.row + 2;
    popup.drawVirtualPopupSeparator(&editor.renderer.screen, sep_row, geom.col, geom.width, .command_popup_border);

    // Footer hint
    const footer_row = geom.row + 3;
    popup.drawVirtualPopupRow(&editor.renderer.screen, footer_row, geom.col, geom.width, .command_popup_border, .popup_footer);
    const hint = "[S] Save   [D] Discard   [Esc] Cancel";
    editor.renderer.screen.writeText(footer_row, geom.col + 2, hint[0..@min(hint.len, inner_width -| 2)], .popup_footer);

    // Bottom border
    popup.drawVirtualPopupBottom(&editor.renderer.screen, geom.row + 4, geom.col, geom.width, .command_popup_border);
}
