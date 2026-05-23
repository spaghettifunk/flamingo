const std = @import("std");

pub const Plugin = struct {
    name: []const u8,
    extensions: []const []const u8,
    lsp_command: []const []const u8, // e.g. &[_][]const u8{"zls"}
    language_id: []const u8,
    owned_extensions: ?[][]const u8 = null,
    owned_lsp_command: ?[]const []const u8 = null,

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
        for (self.plugins.items) |p| {
            if (p.owned_extensions) |extensions| {
                for (extensions) |extension| self.allocator.free(extension);
                self.allocator.free(extensions);
            }
            if (p.owned_lsp_command) |command| self.allocator.free(command);
        }
        self.plugins.deinit(self.allocator);
        self.plugins = std.ArrayList(Plugin).empty;
    }

    pub fn registerDefaults(self: *PluginManager) !void {
        try self.plugins.append(self.allocator, .{
            .name = "zig",
            .extensions = &[_][]const u8{ ".zig", ".zon" },
            .lsp_command = &[_][]const u8{"zls"},
            .language_id = "zig",
        });
        try self.plugins.append(self.allocator, .{
            .name = "go",
            .extensions = &[_][]const u8{".go"},
            .lsp_command = &[_][]const u8{"gopls"},
            .language_id = "go",
        });
        try self.plugins.append(self.allocator, .{
            .name = "json",
            .extensions = &[_][]const u8{".json"},
            .lsp_command = &[_][]const u8{ "vscode-json-languageserver", "--stdio" },
            .language_id = "json",
        });
        try self.plugins.append(self.allocator, .{
            .name = "yaml",
            .extensions = &[_][]const u8{ ".yaml", ".yml" },
            .lsp_command = &[_][]const u8{ "yaml-language-server", "--stdio" },
            .language_id = "yaml",
        });
        try self.plugins.append(self.allocator, .{
            .name = "toml",
            .extensions = &[_][]const u8{".toml"},
            .lsp_command = &[_][]const u8{ "taplo", "lsp", "stdio" },
            .language_id = "toml",
        });
        try self.plugins.append(self.allocator, .{
            .name = "protobuf",
            .extensions = &[_][]const u8{".proto"},
            .lsp_command = &[_][]const u8{ "buf", "lsp", "serve" },
            .language_id = "proto",
        });
    }

    pub fn getPluginForExtension(self: *PluginManager, ext: []const u8) ?*const Plugin {
        for (self.plugins.items) |*p| {
            if (p.matchesExtension(ext)) return p;
        }
        return null;
    }

    pub fn getPluginByName(self: *PluginManager, name: []const u8) ?*Plugin {
        for (self.plugins.items) |*p| {
            if (std.mem.eql(u8, p.name, name)) return p;
        }
        return null;
    }

    pub fn overrideLsp(self: *PluginManager, name: []const u8, command: []const u8, args: []const []const u8, language_id: ?[]const u8) !void {
        const p = self.getPluginByName(name) orelse return;
        const owned = try self.allocator.alloc([]const u8, args.len + 1);
        errdefer self.allocator.free(owned);
        owned[0] = command;
        for (args, 0..) |arg, i| {
            owned[i + 1] = arg;
        }
        if (p.owned_lsp_command) |old| self.allocator.free(old);
        p.lsp_command = owned;
        p.owned_lsp_command = owned;
        if (language_id) |id| p.language_id = id;
    }

    pub fn overrideExtensions(self: *PluginManager, name: []const u8, extensions: []const []const u8) !void {
        const p = self.getPluginByName(name) orelse return;
        if (extensions.len == 0) return;

        const owned = try self.allocator.alloc([]const u8, extensions.len);
        var initialized: usize = 0;
        errdefer {
            for (owned[0..initialized]) |extension| self.allocator.free(extension);
            self.allocator.free(owned);
        }

        for (extensions, 0..) |extension, i| {
            owned[i] = if (std.mem.startsWith(u8, extension, "."))
                try self.allocator.dupe(u8, extension)
            else
                try std.fmt.allocPrint(self.allocator, ".{s}", .{extension});
            initialized += 1;
        }

        if (p.owned_extensions) |old| {
            for (old) |extension| self.allocator.free(extension);
            self.allocator.free(old);
        }
        p.extensions = owned;
        p.owned_extensions = owned;
    }
};
