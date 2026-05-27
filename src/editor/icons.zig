const std = @import("std");

pub const IconMode = enum {
    auto,
    nerd_font,
    unicode,
    ascii,
};

pub const IconSet = struct {
    folder: []const u8,
    folder_open: []const u8,
    folder_collapsed: []const u8,
    file: []const u8,
    file_zig: []const u8,
    file_config: []const u8,
    file_markdown: []const u8,
    file_license: []const u8,
    file_modified: []const u8,
    git_branch: []const u8,
    git_added: []const u8,
    git_modified: []const u8,
    git_deleted: []const u8,
    git_ignored: []const u8,
    warning: []const u8,
    error_icon: []const u8,
    info: []const u8,
    success: []const u8,
    terminal: []const u8,
    search: []const u8,
    settings: []const u8,
    help: []const u8,
    close: []const u8,
    expanded: []const u8,
    collapsed: []const u8,
    status_separator_left: []const u8,
    status_separator_right: []const u8,
    clock: []const u8,
    line_count: []const u8,
    context: []const u8,
};

pub const nerdFontIcons = IconSet{
    .folder = "",
    .folder_open = " ",
    .folder_collapsed = " ",
    .file = "",
    .file_zig = "",
    .file_config = "",
    .file_markdown = "",
    .file_license = "",
    .file_modified = "●",
    .git_branch = "",
    .git_added = "●",
    .git_modified = "●",
    .git_deleted = "●",
    .git_ignored = "●",
    .warning = "",
    .error_icon = "",
    .info = "",
    .success = "",
    .terminal = "",
    .search = "",
    .settings = "",
    .help = "",
    .close = "",
    .expanded = "",
    .collapsed = "",
    .status_separator_left = "",
    .status_separator_right = "",
    .clock = "",
    .line_count = "◇",
    .context = "◆",
};

pub const unicodeIcons = IconSet{
    .folder = "▸",
    .folder_open = "▾",
    .folder_collapsed = "▸",
    .file = "•",
    .file_zig = "z",
    .file_config = "*",
    .file_markdown = "m",
    .file_license = "L",
    .file_modified = "*",
    .git_branch = "⑂",
    .git_added = "●",
    .git_modified = "●",
    .git_deleted = "●",
    .git_ignored = "●",
    .warning = "!",
    .error_icon = "×",
    .info = "i",
    .success = "✓",
    .terminal = "$",
    .search = "/",
    .settings = "*",
    .help = "?",
    .close = "×",
    .expanded = "▾",
    .collapsed = "▸",
    .status_separator_left = "│",
    .status_separator_right = "│",
    .clock = "@",
    .line_count = "◇",
    .context = "◆",
};

pub const asciiIcons = IconSet{
    .folder = "d",
    .folder_open = "v d",
    .folder_collapsed = "> d",
    .file = "-",
    .file_zig = "z",
    .file_config = "*",
    .file_markdown = "m",
    .file_license = "L",
    .file_modified = "*",
    .git_branch = "git",
    .git_added = "●",
    .git_modified = "●",
    .git_deleted = "●",
    .git_ignored = "●",
    .warning = "!",
    .error_icon = "x",
    .info = "i",
    .success = "+",
    .terminal = "$",
    .search = "/",
    .settings = "*",
    .help = "?",
    .close = "x",
    .expanded = "v",
    .collapsed = ">",
    .status_separator_left = "<",
    .status_separator_right = ">",
    .clock = "@",
    .line_count = "L",
    .context = "*",
};

pub const EmptyEnv = struct {
    pub fn get(_: EmptyEnv, _: []const u8) ?[]const u8 {
        return null;
    }
};

pub fn parseIconMode(value: []const u8) ?IconMode {
    inline for (std.meta.fields(IconMode)) |field| {
        if (std.mem.eql(u8, value, field.name)) return @enumFromInt(field.value);
    }
    return null;
}

pub fn iconModeName(mode: IconMode) []const u8 {
    return @tagName(mode);
}

pub fn iconSetForMode(mode: IconMode) IconSet {
    return switch (mode) {
        .auto, .unicode => unicodeIcons,
        .nerd_font => nerdFontIcons,
        .ascii => asciiIcons,
    };
}

pub fn hasUtf8Locale(env: anytype) bool {
    const locale = nonEmptyEnvValue(env, "LC_ALL") orelse nonEmptyEnvValue(env, "LC_CTYPE") orelse nonEmptyEnvValue(env, "LANG") orelse return false;
    return localeLooksUtf8(locale);
}

fn envValue(env: anytype, name: []const u8) ?[]const u8 {
    return env.get(name);
}

fn nonEmptyEnvValue(env: anytype, name: []const u8) ?[]const u8 {
    const value = envValue(env, name) orelse return null;
    return if (value.len > 0) value else null;
}

fn localeLooksUtf8(value: []const u8) bool {
    return std.mem.indexOf(u8, value, "UTF-8") != null or
        std.mem.indexOf(u8, value, "utf-8") != null or
        std.mem.indexOf(u8, value, "UTF8") != null or
        std.mem.indexOf(u8, value, "utf8") != null;
}

pub fn detectIconMode(env: anytype, config_mode: IconMode) IconMode {
    const requested = if (envValue(env, "FLAMINGO_ICON_MODE")) |override|
        parseIconMode(override) orelse config_mode
    else
        config_mode;

    return switch (requested) {
        .nerd_font, .unicode, .ascii => requested,
        .auto => if (hasUtf8Locale(env)) .unicode else .ascii,
    };
}

test "icon sets are complete" {
    inline for (.{ nerdFontIcons, unicodeIcons, asciiIcons }) |set| {
        inline for (std.meta.fields(IconSet)) |field| {
            try std.testing.expect(@field(set, field.name).len > 0);
        }
    }
}

test "icon mode detection respects env override and conservative auto" {
    const Env = struct {
        icon_mode: ?[]const u8 = null,
        lang: ?[]const u8 = null,
        lc_all: ?[]const u8 = null,

        pub fn get(self: @This(), name: []const u8) ?[]const u8 {
            if (std.mem.eql(u8, name, "FLAMINGO_ICON_MODE")) return self.icon_mode;
            if (std.mem.eql(u8, name, "LC_ALL")) return self.lc_all;
            if (std.mem.eql(u8, name, "LANG")) return self.lang;
            return null;
        }
    };

    try std.testing.expectEqual(IconMode.nerd_font, detectIconMode(Env{ .icon_mode = "nerd_font", .lang = "C" }, .ascii));
    try std.testing.expectEqual(IconMode.unicode, detectIconMode(Env{ .icon_mode = "auto", .lang = "en_US.UTF-8" }, .nerd_font));
    try std.testing.expectEqual(IconMode.unicode, detectIconMode(Env{ .lc_all = "", .lang = "en_US.UTF-8" }, .auto));
    try std.testing.expectEqual(IconMode.unicode, detectIconMode(Env{ .lang = "en_US.UTF-8" }, .auto));
    try std.testing.expectEqual(IconMode.ascii, detectIconMode(Env{}, .auto));
    try std.testing.expectEqual(IconMode.ascii, detectIconMode(Env{ .icon_mode = "bogus", .lang = "en_US.UTF-8" }, .ascii));
}
