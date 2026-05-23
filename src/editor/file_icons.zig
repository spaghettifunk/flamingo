const std = @import("std");
const icons = @import("icons.zig");
const render_mod = @import("renderer/virtual_screen.zig");

pub fn iconForDirectory(icon_set: icons.IconSet, is_expanded: bool) []const u8 {
    return if (is_expanded) icon_set.folder_open else icon_set.folder_collapsed;
}

pub fn folderIcon(icon_set: icons.IconSet) []const u8 {
    return icon_set.folder;
}

pub fn iconForFileName(icon_set: icons.IconSet, name: []const u8) []const u8 {
    const ext = std.fs.path.extension(name);
    if (std.mem.eql(u8, ext, ".zig")) return icon_set.file_zig;
    if (std.mem.eql(u8, ext, ".toml") or std.mem.eql(u8, ext, ".json") or
        std.mem.eql(u8, ext, ".zon") or std.mem.eql(u8, ext, ".xml"))
        return icon_set.file_config;
    if (std.mem.eql(u8, ext, ".md")) return icon_set.file_markdown;
    if (std.ascii.eqlIgnoreCase(std.fs.path.basename(name), "LICENSE")) return icon_set.file_license;
    return icon_set.file;
}

pub fn styleForFileName(name: []const u8) render_mod.RenderStyle {
    const ext = std.fs.path.extension(name);
    if (std.mem.eql(u8, ext, ".zig") or std.mem.eql(u8, ext, ".ziggy")) return .explorer_zig;
    if (std.mem.eql(u8, ext, ".toml") or std.mem.eql(u8, ext, ".json") or
        std.mem.eql(u8, ext, ".zon") or std.mem.eql(u8, ext, ".xml"))
        return .explorer_config;
    if (std.mem.eql(u8, ext, ".md")) return .explorer_md;
    if (std.ascii.eqlIgnoreCase(std.fs.path.basename(name), "LICENSE")) return .explorer_license;
    return .explorer_file;
}
