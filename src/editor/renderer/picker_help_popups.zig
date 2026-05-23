const filesystem_picker = @import("../filesystem_picker.zig");
const file_icons = @import("../file_icons.zig");
const help_mod = @import("../help.zig");
const viewport_mod = @import("../navigation/viewport.zig");
const popup = @import("popup.zig");
const render_mod = @import("virtual_screen.zig");

const help_popup_title = " Help ";

pub fn pickerTitle(mode: filesystem_picker.PickerMode, phase: filesystem_picker.PickerPhase) []const u8 {
    return switch (mode) {
        .open_file => " Open File ",
        .open_folder => " Open Folder ",
        .new_file_location => if (phase == .entering_name) " New File " else " New File Location ",
    };
}

fn pickerTitleForPicker(picker: *const filesystem_picker.FilesystemPicker) []const u8 {
    if (picker.mode == .open_folder and picker.folder_purpose == .create_workspace) {
        return " Create Workspace ";
    }
    return pickerTitle(picker.mode, picker.phase);
}

pub fn pickerFooter(mode: filesystem_picker.PickerMode, phase: filesystem_picker.PickerPhase) []const u8 {
    if (mode == .new_file_location and phase == .entering_name) {
        return "Enter create  Backspace edit  Esc cancel";
    }
    return switch (mode) {
        .open_file => "Up/Down move  Enter open  Backspace up  Esc cancel",
        .open_folder => "Up/Down move  Enter enter folder  Space select folder  Backspace up  Esc cancel",
        .new_file_location => "Up/Down move  Enter enter folder  Space choose location  Backspace up  Esc cancel",
    };
}

pub fn pickerPrompt(mode: filesystem_picker.PickerMode, phase: filesystem_picker.PickerPhase) []const u8 {
    if (mode == .new_file_location and phase == .entering_name) return "Name the new file";
    return switch (mode) {
        .open_file => "Select a file...",
        .open_folder => "Select a directory...",
        .new_file_location => "Choose a location...",
    };
}

fn pickerPromptForPicker(picker: *const filesystem_picker.FilesystemPicker) []const u8 {
    if (picker.mode == .open_folder and picker.folder_purpose == .create_workspace) {
        return "Select workspace folder...";
    }
    return pickerPrompt(picker.mode, picker.phase);
}

pub fn pickerFooterCompact(width: usize) bool {
    return width < 62;
}

pub fn pickerFooterLineOne(mode: filesystem_picker.PickerMode, phase: filesystem_picker.PickerPhase, compact: bool) []const u8 {
    if (mode == .new_file_location and phase == .entering_name) {
        return if (compact) "Enter create  Backspace edit" else "Enter create  Backspace edit  Esc cancel";
    }
    return switch (mode) {
        .open_file => if (compact) "Enter open  ↑/↓ select" else "Enter open  ↑/↓ select  Backspace parent  Esc cancel",
        .open_folder => if (compact) "Enter browse  Space select" else "Enter browse  Space select  . current  Backspace parent  Esc cancel",
        .new_file_location => if (compact) "Enter browse  Space name" else "Enter browse  Space name  Backspace parent  Esc cancel",
    };
}

pub fn pickerFooterLineTwo(mode: filesystem_picker.PickerMode, phase: filesystem_picker.PickerPhase, compact: bool) ?[]const u8 {
    if (!compact) return null;
    if (mode == .new_file_location and phase == .entering_name) return "Esc cancel";
    return switch (mode) {
        .open_file => "Esc cancel  Backspace parent",
        .open_folder => "Esc cancel  Backspace parent  . current",
        .new_file_location => "Esc cancel  Backspace parent",
    };
}

pub fn pickerFooterLineCount(mode: filesystem_picker.PickerMode, phase: filesystem_picker.PickerPhase, width: usize) usize {
    return if (pickerFooterLineTwo(mode, phase, pickerFooterCompact(width)) == null) 1 else 2;
}

pub fn filesystemPickerGeometry(editor: anytype, mode: filesystem_picker.PickerMode, phase: filesystem_picker.PickerPhase, has_error: bool) ?popup.FilesystemPickerGeometry {
    if (editor.width < 24 or editor.height < 9) return null;

    const available_width = editor.width -| 4;
    if (available_width < 24) return null;
    const capped_width = @min(available_width, @as(usize, 72));
    const panel_width = if (capped_width >= 36) capped_width else available_width;
    if (panel_width < 24) return null;

    const available_height = editor.height -| 2;
    if (available_height < 8) return null;
    const target_height = @max(@as(usize, 8), (editor.height * 65) / 100);
    const footer_rows = pickerFooterLineCount(mode, phase, panel_width);
    const minimum_height = 6 + footer_rows + @as(usize, if (has_error) 1 else 0) + 1;
    const panel_height = @min(available_height, @max(minimum_height, target_height));
    if (panel_height < minimum_height) return null;

    const row = if (available_height > panel_height) ((available_height - panel_height) / 2) -| 1 else 0;
    return .{
        .row = row,
        .col = (editor.width - panel_width) / 2,
        .width = panel_width,
        .height = panel_height,
    };
}

pub fn helpPopupGeometry(editor: anytype) ?popup.FilesystemPickerGeometry {
    if (!editor.state.help_popup.visible or editor.width < 20 or editor.height < 7) return null;

    const viewport = viewport_mod.bufferViewportGeometry(editor);
    if (viewport.width < 20) return null;

    const right_margin: usize = if (viewport.width >= 34) 2 else 0;
    const available_width = viewport.width -| right_margin;
    if (available_width < 20) return null;
    const desired_width: usize = 56;
    const max_width: usize = 72;
    const panel_width = if (available_width >= 28)
        @min(@min(desired_width, max_width), available_width)
    else
        available_width;
    if (panel_width < 20) return null;

    const status_row = viewport_mod.statusRowIndex(editor);
    if (status_row == 0) return null;
    const bottom_row = status_row - 1;
    const usable_height = bottom_row + 1;
    if (usable_height < 6) return null;

    const content_height = editor.state.help_popup.totalRows(&editor.keybinding_registry) + 4;
    const target_height = @min(@max(@as(usize, 8), (usable_height * 65) / 100), @as(usize, 24));
    const panel_height = @min(usable_height, @min(content_height, target_height));
    if (panel_height < 6) return null;

    const viewport_col = viewport.start_col -| 1;
    const col = viewport_col + viewport.width - panel_width - right_margin;
    return .{
        .row = bottom_row + 1 - panel_height,
        .col = col,
        .width = panel_width,
        .height = panel_height,
    };
}

pub fn helpPopupBodyRows(editor: anytype) usize {
    const geom = helpPopupGeometry(editor) orelse return 1;
    return @max(@as(usize, 1), geom.height -| 4);
}

pub fn pickerEntryIcon(editor: anytype, entry: filesystem_picker.PickerEntry) []const u8 {
    return switch (entry.kind) {
        .directory => file_icons.folderIcon(editor.icons),
        .file => file_icons.iconForFileName(editor.icons, entry.name),
        .other => editor.icons.file,
    };
}

pub fn pickerEntryStyle(entry: filesystem_picker.PickerEntry, selected: bool) render_mod.RenderStyle {
    if (selected) return .explorer_selected_focus;
    return switch (entry.kind) {
        .directory => .explorer_folder,
        .file => file_icons.styleForFileName(entry.name),
        .other => .explorer_dim,
    };
}

pub fn renderVirtualFilesystemPickerPopup(editor: anytype) void {
    if (!editor.state.filesystem_picker.visible) return;
    const picker = &editor.state.filesystem_picker;
    const geom = filesystemPickerGeometry(editor, picker.mode, picker.phase, picker.error_message != null) orelse return;
    const inner_end = geom.col + geom.width - 1;
    const title = pickerTitleForPicker(picker);
    popup.drawPickerTop(&editor.renderer.screen, geom, title, .command_popup_border);

    var row = geom.row + 1;
    popup.drawPickerRow(&editor.renderer.screen, row, geom.col, geom.width, .command_popup_border, .command_popup);
    var col = geom.col + 2;
    popup.writeVirtualTruncatedCells(&editor.renderer.screen, row, &col, inner_end, editor.icons.folder, .explorer_folder, false);
    popup.writeVirtualTruncatedCells(&editor.renderer.screen, row, &col, inner_end, " ", .command_popup, false);
    popup.writeVirtualTruncatedCells(&editor.renderer.screen, row, &col, inner_end, picker.cwd, .command_popup, true);
    row += 1;

    popup.drawPickerRow(&editor.renderer.screen, row, geom.col, geom.width, .command_popup_border, .command_popup);
    col = geom.col + 2;
    const prompt_icon = switch (picker.mode) {
        .open_folder => file_icons.folderIcon(editor.icons),
        else => editor.icons.file,
    };
    popup.writeVirtualTruncatedCells(&editor.renderer.screen, row, &col, inner_end, prompt_icon, .command_popup_prompt, false);
    popup.writeVirtualTruncatedCells(&editor.renderer.screen, row, &col, inner_end, " ", .command_popup, false);
    popup.writeVirtualTruncatedCells(&editor.renderer.screen, row, &col, inner_end, pickerPromptForPicker(picker), .command_popup_prompt, false);
    row += 1;

    popup.drawPickerSeparator(&editor.renderer.screen, row, geom.col, geom.width, .command_popup_border);
    row += 1;

    const footer_rows = pickerFooterLineCount(picker.mode, picker.phase, geom.width);
    const error_rows: usize = if (picker.error_message == null) 0 else 1;
    const result_height = geom.height -| (6 + footer_rows + error_rows);

    if (picker.phase == .entering_name) {
        for (0..result_height) |offset| {
            const item_row = row + offset;
            popup.drawPickerRow(&editor.renderer.screen, item_row, geom.col, geom.width, .command_popup_border, .explorer_bg);
            if (offset == 0) {
                col = geom.col + 2;
                popup.writeVirtualTruncatedCells(&editor.renderer.screen, item_row, &col, inner_end, editor.icons.file, .explorer_file, false);
                popup.writeVirtualTruncatedCells(&editor.renderer.screen, item_row, &col, inner_end, " ", .explorer_file, false);
                popup.writeVirtualTruncatedCells(&editor.renderer.screen, item_row, &col, inner_end, "filename: ", .explorer_dim, false);
                popup.writeVirtualTruncatedCells(&editor.renderer.screen, item_row, &col, inner_end, picker.input.items, .normal, false);
            }
        }
    } else {
        if (picker.entries.items.len == 0) {
            for (0..result_height) |offset| {
                const item_row = row + offset;
                popup.drawPickerRow(&editor.renderer.screen, item_row, geom.col, geom.width, .command_popup_border, .explorer_bg);
                if (offset == 0) {
                    col = geom.col + 2;
                    popup.writeVirtualTruncatedCells(&editor.renderer.screen, item_row, &col, inner_end, "No entries", .explorer_dim, false);
                }
            }
        } else {
            if (picker.selected_index >= picker.scroll_offset + result_height) {
                picker.scroll_offset = picker.selected_index - result_height + 1;
            } else if (picker.selected_index < picker.scroll_offset) {
                picker.scroll_offset = picker.selected_index;
            }
            for (0..result_height) |offset| {
                const item_row = row + offset;
                const index = picker.scroll_offset + offset;
                if (index >= picker.entries.items.len) {
                    popup.drawPickerRow(&editor.renderer.screen, item_row, geom.col, geom.width, .command_popup_border, .explorer_bg);
                    continue;
                }
                const entry = picker.entries.items[index];
                const selected = index == picker.selected_index;
                const row_style: render_mod.RenderStyle = if (selected) .explorer_selected_focus else .explorer_bg;
                const text_style = pickerEntryStyle(entry, selected);
                popup.drawPickerRow(&editor.renderer.screen, item_row, geom.col, geom.width, .command_popup_border, row_style);
                col = geom.col + 2;
                popup.writeVirtualTruncatedCells(&editor.renderer.screen, item_row, &col, inner_end, pickerEntryIcon(editor, entry), text_style, false);
                popup.writeVirtualTruncatedCells(&editor.renderer.screen, item_row, &col, inner_end, " ", row_style, false);
                popup.writeVirtualTruncatedCells(&editor.renderer.screen, item_row, &col, inner_end, entry.name, text_style, false);
                if (entry.kind == .directory) {
                    popup.writeVirtualTruncatedCells(&editor.renderer.screen, item_row, &col, inner_end, "/", text_style, false);
                }
            }
        }
    }
    row += result_height;

    popup.drawPickerSeparator(&editor.renderer.screen, row, geom.col, geom.width, .command_popup_border);
    row += 1;

    if (picker.error_message) |msg| {
        popup.drawPickerRow(&editor.renderer.screen, row, geom.col, geom.width, .command_popup_border, .popup_error);
        col = geom.col + 2;
        popup.writeVirtualTruncatedCells(&editor.renderer.screen, row, &col, inner_end, msg, .popup_error, false);
        row += 1;
    }

    const compact = pickerFooterCompact(geom.width);
    popup.drawPickerRow(&editor.renderer.screen, row, geom.col, geom.width, .command_popup_border, .popup_footer);
    col = geom.col + 2;
    popup.writeVirtualTruncatedCells(&editor.renderer.screen, row, &col, inner_end, pickerFooterLineOne(picker.mode, picker.phase, compact), .popup_footer, false);
    row += 1;
    if (pickerFooterLineTwo(picker.mode, picker.phase, compact)) |line| {
        popup.drawPickerRow(&editor.renderer.screen, row, geom.col, geom.width, .command_popup_border, .popup_footer);
        col = geom.col + 2;
        popup.writeVirtualTruncatedCells(&editor.renderer.screen, row, &col, inner_end, line, .popup_footer, false);
    }

    popup.drawPickerBottom(&editor.renderer.screen, geom.row + geom.height - 1, geom.col, geom.width, .command_popup_border);
}

pub fn helpFooter(width: usize) []const u8 {
    return if (width < 46)
        "q/Esc close  Up/Down scroll"
    else
        "q/Esc close  Up/Down scroll  PgUp/PgDn page";
}

pub fn renderVirtualHelpPopup(editor: anytype) void {
    if (!editor.state.help_popup.visible) return;
    const geom = helpPopupGeometry(editor) orelse return;
    const body_rows = @max(@as(usize, 1), geom.height -| 4);
    const inner_end = geom.col + geom.width - 1;
    editor.state.help_popup.clampScroll(&editor.keybinding_registry, body_rows);

    popup.drawPickerTop(&editor.renderer.screen, geom, help_popup_title, .command_popup_border);

    const key_width: usize = if (geom.width < 42) 14 else 24;
    var body_row: usize = geom.row + 1;
    for (0..body_rows) |offset| {
        const source_row = editor.state.help_popup.scroll_offset + offset;
        const row = body_row + offset;
        const help_row = editor.state.help_popup.rowAt(&editor.keybinding_registry, source_row);
        switch (help_row orelse {
            popup.drawPickerRow(&editor.renderer.screen, row, geom.col, geom.width, .command_popup_border, .explorer_bg);
            continue;
        }) {
            .category => |category| {
                popup.drawPickerRow(&editor.renderer.screen, row, geom.col, geom.width, .command_popup_border, .explorer_selected_focus);
                var col = geom.col + 2;
                popup.writeVirtualTruncatedCells(&editor.renderer.screen, row, &col, inner_end, help_mod.categoryTitle(category), .explorer_selected_focus, false);
            },
            .command => |command| {
                popup.drawPickerRow(&editor.renderer.screen, row, geom.col, geom.width, .command_popup_border, .explorer_bg);
                var col = geom.col + 2;
                var key_buf: [192]u8 = undefined;
                var description_buf: [256]u8 = undefined;
                const key_text = help_mod.formatCommandKeys(command.meta, &editor.keybinding_registry, &key_buf);
                const description = help_mod.formatCommandDescription(command.meta, &description_buf);
                const key_start = col;
                popup.writeVirtualTruncatedCells(&editor.renderer.screen, row, &col, @min(inner_end, key_start + key_width), key_text, .command_popup_prompt, false);
                if (col < key_start + key_width and col < inner_end) {
                    while (col < key_start + key_width and col < inner_end) : (col += 1) {
                        editor.renderer.screen.set(row, col, ' ', .explorer_bg);
                    }
                }
                popup.writeVirtualTruncatedCells(&editor.renderer.screen, row, &col, inner_end, "  ", .explorer_bg, false);
                popup.writeVirtualTruncatedCells(&editor.renderer.screen, row, &col, inner_end, description, .command_popup, false);
            },
        }
    }
    body_row += body_rows;

    popup.drawPickerSeparator(&editor.renderer.screen, body_row, geom.col, geom.width, .command_popup_border);
    body_row += 1;

    popup.drawPickerRow(&editor.renderer.screen, body_row, geom.col, geom.width, .command_popup_border, .popup_footer);
    var col = geom.col + 2;
    popup.writeVirtualTruncatedCells(&editor.renderer.screen, body_row, &col, inner_end, helpFooter(geom.width), .popup_footer, false);

    popup.drawPickerBottom(&editor.renderer.screen, geom.row + geom.height - 1, geom.col, geom.width, .command_popup_border);
}
