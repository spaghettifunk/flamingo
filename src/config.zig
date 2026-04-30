const std = @import("std");
const toml = @import("toml");

pub const KeybindingsConfig = struct {
    new_file: []const u8 = "ctrl+n",
    open_file: []const u8 = "ctrl+o",
    open_folder: []const u8 = "ctrl+f",
    settings: []const u8 = "ctrl+p",
    quit: []const u8 = "ctrl+q",

    toggle_explorer: []const u8 = "ctrl+b",
    switch_focus: []const u8 = "ctrl+e",
    close_tab: []const u8 = "ctrl+w",
    next_tab: []const u8 = "alt+[",
    previous_tab: []const u8 = "alt+]",

    dashboard_up: []const u8 = "up",
    dashboard_down: []const u8 = "down",
    dashboard_select: []const u8 = "enter",

    explorer_up: []const u8 = "up",
    explorer_down: []const u8 = "down",
    explorer_open: []const u8 = "enter",

    insert_mode: []const u8 = "i",
    command_mode: []const u8 = ":",
    search_mode: []const u8 = "/",
    normal_mode: []const u8 = "esc",

    insert_newline: []const u8 = "enter",
    delete_back: []const u8 = "backspace",
    indent: []const u8 = "tab",

    prompt_submit: []const u8 = "enter",
    prompt_backspace: []const u8 = "backspace",

    save: []const u8 = "ctrl+s",
    select_all: []const u8 = "ctrl+a",
    copy: []const u8 = "ctrl+c",
    cut: []const u8 = "ctrl+x",
    paste: []const u8 = "ctrl+v",
    duplicate_line: []const u8 = "ctrl+d",
    delete_line: []const u8 = "ctrl+shift+k",
    add_cursor_above: []const u8 = "ctrl+alt+up",
    add_cursor_below: []const u8 = "ctrl+alt+down",

    move_up: []const u8 = "up",
    move_down: []const u8 = "down",
    move_left: []const u8 = "left",
    move_right: []const u8 = "right",
    line_start: []const u8 = "alt+down",
    line_end: []const u8 = "alt+up",
    word_left: []const u8 = "alt+left",
    word_right: []const u8 = "alt+right",

    search_next: []const u8 = "down",
    search_previous: []const u8 = "up",

    completion_auto_trigger: []const u8 = ".",
    completion_trigger: []const u8 = "ctrl+space",
    completion_next: []const u8 = "down",
    completion_previous: []const u8 = "up",
    completion_accept: []const u8 = "enter",
    completion_cancel: []const u8 = "esc",
};

pub const ExplorerConfig = struct {
    width_percentage: u8 = 20,
};

// ── Root config ──────────────────────────────────────────────────────────────

pub const Config = struct {
    keybindings: KeybindingsConfig = .{},
    explorer: ExplorerConfig = .{},
};

// ── Validation ───────────────────────────────────────────────────────────────

pub const ConfigError = error{InvalidKeybinding};

fn validateKeybinding(chord: []const u8) ConfigError!void {
    const event = @import("terminal.zig").parseKeyChord(chord);
    if (event.key == .None) return error.InvalidKeybinding;
}

pub fn validate(cfg: *const Config) ConfigError!void {
    inline for (@typeInfo(KeybindingsConfig).@"struct".fields) |field| {
        try validateKeybinding(@field(cfg.keybindings, field.name));
    }
}

// ── Loading ──────────────────────────────────────────────────────────────────

pub fn loadFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
) !toml.Parsed(Config) {
    // Read the whole file into a slice — caller's allocator owns it.
    const source = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, std.Io.Limit.limited(4 * 1024 * 1024));
    defer allocator.free(source);

    var parser = toml.Parser(Config).init(allocator);
    defer parser.deinit();

    return parser.parseString(source);
}
