const std = @import("std");

pub const Plugin = struct {
    name: []const u8,
    extensions: []const []const u8,
    lsp_command: []const []const u8, // e.g. &[_][]const u8{"zls"}

    pub fn matchesExtension(self: Plugin, ext: []const u8) bool {
        for (self.extensions) |e| {
            if (std.mem.eql(u8, e, ext)) return true;
        }
        return false;
    }
};

pub const PluginManager = struct {
    allocator: std.mem.Allocator,
    plugins: std.ArrayList(Plugin),

    pub fn init(allocator: std.mem.Allocator) PluginManager {
        return .{
            .allocator = allocator,
            .plugins = std.ArrayList(Plugin).empty,
        };
    }

    pub fn deinit(self: *PluginManager) void {
        self.plugins.deinit(self.allocator);
        self.plugins = std.ArrayList(Plugin).empty;
    }

    pub fn registerDefaults(self: *PluginManager) !void {
        try self.plugins.append(self.allocator, .{
            .name = "zig",
            .extensions = &[_][]const u8{ ".zig", ".zon" },
            .lsp_command = &[_][]const u8{"zls"},
        });
        try self.plugins.append(self.allocator, .{
            .name = "go",
            .extensions = &[_][]const u8{".go"},
            .lsp_command = &[_][]const u8{"gopls"},
        });
        try self.plugins.append(self.allocator, .{
            .name = "json",
            .extensions = &[_][]const u8{".json"},
            .lsp_command = &[_][]const u8{ "vscode-json-languageserver", "--stdio" },
        });
        try self.plugins.append(self.allocator, .{
            .name = "yaml",
            .extensions = &[_][]const u8{ ".yaml", ".yml" },
            .lsp_command = &[_][]const u8{ "yaml-language-server", "--stdio" },
        });
        try self.plugins.append(self.allocator, .{
            .name = "toml",
            .extensions = &[_][]const u8{".toml"},
            .lsp_command = &[_][]const u8{ "taplo", "lsp", "stdio" },
        });
    }

    pub fn getPluginForExtension(self: *PluginManager, ext: []const u8) ?*const Plugin {
        for (self.plugins.items) |*p| {
            if (p.matchesExtension(ext)) return p;
        }
        return null;
    }
};
