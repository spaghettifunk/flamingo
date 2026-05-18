const std = @import("std");
const toml = @import("toml");
const commands = @import("editor/commands.zig");
const command_keybindings = @import("editor/keybindings.zig");

pub const KeybindingsConfig = struct {
    global: ?toml.Table = null,
    normal: ?toml.Table = null,
    insert: ?toml.Table = null,
    command_line: ?toml.Table = null,
    dashboard: ?toml.Table = null,
    explorer: ?toml.Table = null,
    explorer_search: ?toml.Table = null,
    search: ?toml.Table = null,
    global_search: ?toml.Table = null,
    help: ?toml.Table = null,
    terminal: ?toml.Table = null,
    picker: ?toml.Table = null,
    picker_new_file: ?toml.Table = null,
    picker_open_folder: ?toml.Table = null,
    prompt: ?toml.Table = null,
    open_file_prompt: ?toml.Table = null,
    completion: ?toml.Table = null,
    save_confirmation: ?toml.Table = null,
    unknown_contexts: []const []const u8 = &.{},

    pub fn tomlIntoStruct(ctx: anytype, table: *toml.Table) !KeybindingsConfig {
        var cfg = KeybindingsConfig{};
        var unknown = std.ArrayListUnmanaged([]const u8).empty;
        errdefer unknown.deinit(ctx.alloc);

        var it = table.iterator();
        while (it.next()) |entry| {
            var consumed = false;

            inline for (@typeInfo(KeybindingsConfig).@"struct".fields) |field| {
                if (comptime field.type == ?toml.Table) {
                    if (std.mem.eql(u8, entry.key_ptr.*, field.name)) {
                        switch (entry.value_ptr.*) {
                            .table => |value| @field(cfg, field.name) = value.*,
                            else => return error.InvalidValueType,
                        }
                        consumed = true;
                    }
                }
            }

            if (!consumed) try unknown.append(ctx.alloc, entry.key_ptr.*);
        }

        cfg.unknown_contexts = try unknown.toOwnedSlice(ctx.alloc);
        return cfg;
    }
};

pub const ExplorerConfig = struct {
    width_percentage: u8 = 20,
};

// ── Root config ──────────────────────────────────────────────────────────────

pub const Config = struct {
    debug: bool = false,
    keybindings: KeybindingsConfig = .{},
    explorer: ExplorerConfig = .{},
};

// ── Validation ───────────────────────────────────────────────────────────────

pub const ConfigError = error{InvalidKeybinding};

pub fn validate(_: *const Config) ConfigError!void {
    // Keybinding schema validation needs config diagnostics and is performed by
    // buildKeybindingRegistry before the editor enters raw terminal mode.
}

fn contextTable(cfg: *const KeybindingsConfig, context: command_keybindings.BindingContext) ?toml.Table {
    return switch (context) {
        .global => cfg.global,
        .normal => cfg.normal,
        .insert => cfg.insert,
        .command_line => cfg.command_line,
        .dashboard => cfg.dashboard,
        .explorer => cfg.explorer,
        .explorer_search => cfg.explorer_search,
        .search => cfg.search,
        .global_search => cfg.global_search,
        .help => cfg.help,
        .terminal => cfg.terminal,
        .picker => cfg.picker,
        .picker_new_file => cfg.picker_new_file,
        .picker_open_folder => cfg.picker_open_folder,
        .prompt => cfg.prompt,
        .open_file_prompt => cfg.open_file_prompt,
        .completion => cfg.completion,
        .save_confirmation => cfg.save_confirmation,
    };
}

fn parseKeyForContext(
    allocator: std.mem.Allocator,
    diagnostics: *command_keybindings.BuildDiagnostics,
    context: command_keybindings.BindingContext,
    key_text: []const u8,
) !?command_keybindings.KeySequence {
    return command_keybindings.parseKeySequence(key_text) catch |err| {
        try diagnostics.addError(
            allocator,
            "[{s}] \"{s}\" is not a supported key sequence: {s}",
            .{ @tagName(context), key_text, @errorName(err) },
        );
        return null;
    };
}

fn appendNewBindingTable(
    allocator: std.mem.Allocator,
    diagnostics: *command_keybindings.BuildDiagnostics,
    context: command_keybindings.BindingContext,
    table: *const toml.Table,
    overrides: *std.ArrayListUnmanaged(command_keybindings.UserBindingOverride),
    unbinds: *std.ArrayListUnmanaged(command_keybindings.UserUnbind),
) !void {
    var it = table.iterator();
    while (it.next()) |entry| {
        const key_text = entry.key_ptr.*;
        if (std.mem.eql(u8, key_text, "unbind")) {
            switch (entry.value_ptr.*) {
                .table => |unbind_table| {
                    const keys_value = unbind_table.get("keys") orelse {
                        try diagnostics.addError(allocator, "[{s}.unbind] is missing keys array", .{@tagName(context)});
                        continue;
                    };
                    switch (keys_value) {
                        .array => |items| {
                            for (items.items) |item| {
                                switch (item) {
                                    .string => |unbind_key| {
                                        const sequence = (try parseKeyForContext(allocator, diagnostics, context, unbind_key)) orelse continue;
                                        try unbinds.append(allocator, .{
                                            .context = context,
                                            .sequence = sequence,
                                            .source_key = unbind_key,
                                        });
                                    },
                                    else => try diagnostics.addError(allocator, "[{s}.unbind] keys must be strings", .{@tagName(context)}),
                                }
                            }
                        },
                        else => try diagnostics.addError(allocator, "[{s}.unbind] keys must be an array", .{@tagName(context)}),
                    }
                },
                else => try diagnostics.addError(allocator, "[{s}] unbind must be a table", .{@tagName(context)}),
            }
            continue;
        }

        const command_name = switch (entry.value_ptr.*) {
            .string => |value| value,
            .table => {
                try diagnostics.addError(
                    allocator,
                    "[{s}] \"{s}\" uses inline command args, which are not supported yet",
                    .{ @tagName(context), key_text },
                );
                continue;
            },
            else => {
                try diagnostics.addError(
                    allocator,
                    "[{s}] \"{s}\" must map to a command name string",
                    .{ @tagName(context), key_text },
                );
                continue;
            },
        };
        const sequence = (try parseKeyForContext(allocator, diagnostics, context, key_text)) orelse continue;
        const command = commands.commandByCanonicalName(command_name) orelse {
            try diagnostics.addError(
                allocator,
                "[{s}] \"{s}\" maps to unknown command \"{s}\"",
                .{ @tagName(context), key_text, command_name },
            );
            continue;
        };
        var existing_index: usize = 0;
        while (existing_index < overrides.items.len) {
            const existing = overrides.items[existing_index];
            if (existing.context == context and existing.sequence.eql(sequence)) {
                try diagnostics.addWarning(
                    allocator,
                    "[{s}] \"{s}\" overrides an earlier keybinding",
                    .{ @tagName(context), key_text },
                );
                _ = overrides.orderedRemove(existing_index);
                continue;
            }
            existing_index += 1;
        }
        try overrides.append(allocator, .{
            .context = context,
            .sequence = sequence,
            .command = command,
            .source_key = key_text,
            .source_command = command_name,
        });
    }
}

fn isLegacyFlatKey(name: []const u8) bool {
    const legacy_names = [_][]const u8{
        "new_file",
        "open_file",
        "open_folder",
        "settings",
        "quit",
        "toggle_explorer",
        "toggle_terminal",
        "switch_focus",
        "close_tab",
        "next_tab",
        "previous_tab",
        "jump_back",
        "jump_forward",
        "dashboard_up",
        "dashboard_down",
        "dashboard_select",
        "explorer_up",
        "explorer_down",
        "explorer_open",
        "explorer_new_file",
        "explorer_rename",
        "explorer_delete",
        "insert_mode",
        "command_mode",
        "search_mode",
        "normal_mode",
        "insert_newline",
        "delete_back",
        "delete_word_back",
        "indent",
        "prompt_submit",
        "prompt_backspace",
        "save",
        "undo",
        "redo",
        "select_all",
        "copy",
        "cut",
        "paste",
        "duplicate_line",
        "delete_line",
        "add_cursor_above",
        "add_cursor_below",
        "move_up",
        "move_down",
        "move_left",
        "move_right",
        "line_start",
        "line_end",
        "word_left",
        "word_right",
        "search_next",
        "search_previous",
        "completion_auto_trigger",
        "completion_trigger",
        "completion_next",
        "completion_previous",
        "completion_accept",
        "completion_cancel",
    };
    for (legacy_names) |legacy_name| {
        if (std.mem.eql(u8, name, legacy_name)) return true;
    }
    return false;
}

pub fn buildKeybindingRegistry(
    allocator: std.mem.Allocator,
    cfg: *const Config,
    diagnostics: *command_keybindings.BuildDiagnostics,
) !command_keybindings.Registry {
    for (cfg.keybindings.unknown_contexts) |name| {
        if (isLegacyFlatKey(name)) {
            try diagnostics.addError(
                allocator,
                "legacy flat [keybindings] field \"{s}\" is no longer supported; use context-specific tables such as [keybindings.normal] \"ctrl+s\" = \"file.write\"",
                .{name},
            );
        } else {
            try diagnostics.addError(allocator, "[keybindings.{s}] is not a supported keybinding context", .{name});
        }
    }

    var overrides = std.ArrayListUnmanaged(command_keybindings.UserBindingOverride).empty;
    defer overrides.deinit(allocator);
    var unbinds = std.ArrayListUnmanaged(command_keybindings.UserUnbind).empty;
    defer unbinds.deinit(allocator);

    inline for (std.meta.fields(command_keybindings.BindingContext)) |field| {
        const context: command_keybindings.BindingContext = @enumFromInt(field.value);
        if (contextTable(&cfg.keybindings, context)) |table| {
            try appendNewBindingTable(allocator, diagnostics, context, &table, &overrides, &unbinds);
        }
    }

    return command_keybindings.Registry.fromDefaultsAndConfig(allocator, overrides.items, unbinds.items, diagnostics);
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
