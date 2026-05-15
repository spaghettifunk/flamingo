const std = @import("std");
const render_mod = @import("renderer/virtual_screen.zig");

pub fn iconForDirectory(is_expanded: bool) []const u8 {
    return if (is_expanded) " " else " ";
}

pub fn folderIcon() []const u8 {
    return "";
}

pub fn iconForFileName(name: []const u8) []const u8 {
    const ext = std.fs.path.extension(name);
    if (std.mem.eql(u8, ext, ".zig")) return "";
    if (std.mem.eql(u8, ext, ".toml") or std.mem.eql(u8, ext, ".json") or
        std.mem.eql(u8, ext, ".zon") or std.mem.eql(u8, ext, ".xml"))
        return "";
    if (std.mem.eql(u8, ext, ".md")) return "";
    if (std.ascii.eqlIgnoreCase(std.fs.path.basename(name), "LICENSE")) return "";
    return "";
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
