const std = @import("std");
const plugin = @import("../plugin/manager.zig");
const lsp_client = @import("client.zig");
const event_queue = @import("../editor/runtime/event_queue.zig");
const protocol = @import("protocol.zig");
const logz = @import("logz");

pub const DefinitionRequestResult = union(enum) {
    requested: struct {
        request_id: usize,
        plugin_name: []const u8,
    },
    no_plugin,
    no_client,
    not_ready,
};

pub const DefinitionLocation = struct {
    uri: []const u8,
    row: usize,
    col: usize,
};

pub const LspManager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    plugin_mgr: plugin.PluginManager,
    clients: std.StringHashMap(*lsp_client.LspClient),
    queue: *event_queue.EventQueue,

    pub const StartLspResult = union(enum) {
        no_plugin,
        already_running: []const u8,
        started: []const u8,
        command_unavailable: []const u8,
        start_failed: []const u8,
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io, queue: *event_queue.EventQueue) !LspManager {
        var mgr = plugin.PluginManager.init(allocator);
        errdefer mgr.deinit();
        try mgr.registerDefaults();

        return .{
            .allocator = allocator,
            .io = io,
            .plugin_mgr = mgr,
            .clients = std.StringHashMap(*lsp_client.LspClient).init(allocator),
            .queue = queue,
        };
    }

    pub fn deinit(self: *LspManager) void {
        var it = self.clients.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.stop();
        }
        self.clients.deinit();
        self.clients = std.StringHashMap(*lsp_client.LspClient).init(self.allocator);
        self.plugin_mgr.deinit();
    }

    pub fn startLspForFile(self: *LspManager, filename: []const u8) !StartLspResult {
        const ext = std.fs.path.extension(filename);
        const p = self.plugin_mgr.getPluginForExtension(ext) orelse return .no_plugin;
        if (self.clients.contains(p.name)) return .{ .already_running = p.name };

        if (!try self.commandAvailable(p.lsp_command[0])) {
            logz.warn().fmt("msg", "LSP command not found for plugin {s}: {s}", .{ p.name, p.lsp_command[0] }).log();
            return .{ .command_unavailable = p.name };
        }

        const root_path = self.workspaceRootForFile(filename) catch |err| blk: {
            logz.warn().fmt("msg", "Failed to detect LSP workspace root for {s}: {any}", .{ filename, err }).log();
            break :blk try self.fallbackWorkspaceRoot(filename);
        };
        defer self.allocator.free(root_path);

        logz.info().fmt("msg", "Starting LSP for plugin {s}", .{p.name}).log();
        const client = lsp_client.LspClient.start(self.allocator, self.io, p.name, p.lsp_command, self.queue) catch |err| {
            logz.warn().fmt("msg", "Failed to start LSP for plugin {s}: {any}", .{ p.name, err }).log();
            return .{ .start_failed = p.name };
        };
        errdefer client.stop();
        try self.clients.put(p.name, client);

        self.sendInitialize(client, root_path) catch |err| {
            logz.warn().fmt("msg", "Failed to initialize LSP for plugin {s}: {any}", .{ p.name, err }).log();
            _ = self.clients.remove(p.name);
            client.stop();
            return .{ .start_failed = p.name };
        };
        return .{ .started = p.name };
    }

    fn commandAvailable(self: *LspManager, command: []const u8) !bool {
        if (command.len == 0) return false;
        if (std.mem.indexOfScalar(u8, command, '/') != null) {
            if (std.fs.path.isAbsolute(command)) {
                std.Io.Dir.accessAbsolute(self.io, command, .{}) catch return false;
            } else {
                std.Io.Dir.cwd().access(self.io, command, .{}) catch return false;
            }
            return true;
        }

        const path_z = std.c.getenv("PATH") orelse return false;
        const path = std.mem.span(path_z);
        var it = std.mem.splitScalar(u8, path, ':');
        while (it.next()) |dir| {
            if (dir.len == 0) continue;
            const candidate = try std.fs.path.join(self.allocator, &.{ dir, command });
            defer self.allocator.free(candidate);
            std.Io.Dir.accessAbsolute(self.io, candidate, .{}) catch continue;
            return true;
        }
        return false;
    }

    fn sendInitialize(self: *LspManager, client: *lsp_client.LspClient, root_path: []const u8) !void {
        const root_uri = try self.pathToUri(self.allocator, root_path);
        defer self.allocator.free(root_uri);

        client.state = .initializing;
        const req = protocol.InitializeRequest{
            .id = client.request_id,
            .params = .{
                .processId = null, // Can be null
                .rootUri = root_uri,
                .capabilities = .{},
            },
        };
        try client.pending_requests.put(client.request_id, .initialize);
        client.request_id += 1;
        try client.send(req);
    }

    pub const HandleResult = union(enum) {
        none,
        initialized,
        completion: std.json.Value,
        definition: struct {
            request_id: usize,
            result: std.json.Value,
        },
        diagnostics: std.json.Value,
    };

    pub fn handleMessage(self: *LspManager, plugin_name: []const u8, message: []const u8) !HandleResult {
        const client = self.clients.get(plugin_name) orelse return .none;

        logz.info().fmt("msg", "Received LSP msg from {s}: {s}", .{ plugin_name, message }).log();

        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, message, .{}) catch |err| {
            logz.err().fmt("msg", "Failed to parse LSP msg: {any}", .{err}).log();
            return .none;
        };
        defer parsed.deinit();

        const root = parsed.value.object;

        if (root.get("id")) |id_val| {
            if (id_val == .integer) {
                const id = @as(usize, @intCast(id_val.integer));
                if (client.pending_requests.get(id)) |req_type| {
                    _ = client.pending_requests.remove(id);

                    switch (req_type) {
                        .initialize => {
                            client.state = .ready;
                            logz.info().fmt("msg", "LSP {s} initialized successfully", .{plugin_name}).log();

                            const notif = protocol.InitializedNotification{};
                            try client.send(notif);
                            return .initialized;
                        },
                        .completion => {
                            if (root.get("result")) |result| {
                                // Clone the result because 'parsed' will be deinited
                                const result_cloned = try cloneValue(self.allocator, result);
                                return .{ .completion = result_cloned };
                            }
                        },
                        .definition => {
                            if (root.get("result")) |result| {
                                // Clone the result because 'parsed' will be deinited.
                                const result_cloned = try cloneValue(self.allocator, result);
                                return .{ .definition = .{
                                    .request_id = id,
                                    .result = result_cloned,
                                } };
                            }
                            return .{ .definition = .{
                                .request_id = id,
                                .result = .null,
                            } };
                        },
                    }
                }
            }
        }

        if (root.get("method")) |method_val| {
            if (method_val == .string and std.mem.eql(u8, method_val.string, "textDocument/publishDiagnostics")) {
                if (root.get("params")) |params_val| {
                    const params_cloned = try cloneValue(self.allocator, params_val);
                    return .{ .diagnostics = params_cloned };
                }
            }
        }

        return .none;
    }

    fn cloneValue(allocator: std.mem.Allocator, v: std.json.Value) !std.json.Value {
        switch (v) {
            .null => return .null,
            .bool => |b| return .{ .bool = b },
            .integer => |i| return .{ .integer = i },
            .float => |f| return .{ .float = f },
            .number_string => |s| return .{ .number_string = try allocator.dupe(u8, s) },
            .string => |s| return .{ .string = try allocator.dupe(u8, s) },
            .array => |arr| {
                var new_arr = try std.json.Array.initCapacity(allocator, arr.items.len);
                errdefer freeJsonValue(allocator, .{ .array = new_arr });
                for (arr.items) |item| {
                    const cloned = try cloneValue(allocator, item);
                    var appended = false;
                    errdefer if (!appended) freeJsonValue(allocator, cloned);
                    try new_arr.append(cloned);
                    appended = true;
                }
                return .{ .array = new_arr };
            },
            .object => |obj| {
                var new_obj: std.json.ObjectMap = .{};
                errdefer freeJsonValue(allocator, .{ .object = new_obj });
                var it = obj.iterator();
                while (it.next()) |entry| {
                    const key = try allocator.dupe(u8, entry.key_ptr.*);
                    var inserted = false;
                    errdefer if (!inserted) allocator.free(key);

                    const cloned = try cloneValue(allocator, entry.value_ptr.*);
                    errdefer if (!inserted) freeJsonValue(allocator, cloned);

                    try new_obj.put(allocator, key, cloned);
                    inserted = true;
                }
                return .{ .object = new_obj };
            },
        }
    }

    pub fn freeValue(self: *LspManager, v: std.json.Value) void {
        freeJsonValue(self.allocator, v);
    }

    fn freeJsonValue(allocator: std.mem.Allocator, v: std.json.Value) void {
        switch (v) {
            .number_string => |s| allocator.free(s),
            .string => |s| allocator.free(s),
            .array => |arr| {
                for (arr.items) |item| {
                    freeJsonValue(allocator, item);
                }
                var mutable_arr = arr;
                mutable_arr.deinit();
            },
            .object => |obj| {
                var it = obj.iterator();
                while (it.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    freeJsonValue(allocator, entry.value_ptr.*);
                }
                var mutable_obj = obj;
                mutable_obj.deinit(allocator);
            },
            else => {},
        }
    }

    pub fn notifyOpen(self: *LspManager, filename: []const u8, content: []const u8) !void {
        const ext = std.fs.path.extension(filename);
        const p = self.plugin_mgr.getPluginForExtension(ext) orelse return;
        const client = self.clients.get(p.name) orelse return;

        try client.opened_files.put(filename, true);

        if (client.state == .ready) {
            const uri = try self.pathToUri(self.allocator, filename);
            defer self.allocator.free(uri);

            try client.document_versions.put(filename, 1);

            const notif = protocol.DidOpenNotification{
                .params = .{
                    .textDocument = .{
                        .uri = uri,
                        .languageId = p.language_id,
                        .version = 1,
                        .text = content,
                    },
                },
            };
            try client.send(notif);
        }
    }

    pub fn notifyChange(self: *LspManager, filename: []const u8, content: []const u8) !void {
        const ext = std.fs.path.extension(filename);
        const p = self.plugin_mgr.getPluginForExtension(ext) orelse return;
        const client = self.clients.get(p.name) orelse return;

        if (client.state != .ready) return;

        const uri = try self.pathToUri(self.allocator, filename);
        defer self.allocator.free(uri);

        const v = client.document_versions.get(filename) orelse 0;
        const next_v = v + 1;
        try client.document_versions.put(filename, next_v);

        const notif = protocol.DidChangeNotification{
            .params = .{
                .textDocument = .{
                    .uri = uri,
                    .version = next_v,
                },
                .contentChanges = &[_]protocol.TextDocumentContentChangeEvent{
                    .{ .text = content },
                },
            },
        };
        try client.send(notif);
    }

    pub fn notifySave(self: *LspManager, filename: []const u8) !void {
        const ext = std.fs.path.extension(filename);
        const p = self.plugin_mgr.getPluginForExtension(ext) orelse return;
        const client = self.clients.get(p.name) orelse return;

        if (client.state != .ready) return;

        const uri = try self.pathToUri(self.allocator, filename);
        defer self.allocator.free(uri);

        const notif = protocol.DidSaveNotification{
            .params = .{
                .textDocument = .{ .uri = uri },
            },
        };
        try client.send(notif);
    }

    pub fn notifyClose(self: *LspManager, filename: []const u8) !void {
        const ext = std.fs.path.extension(filename);
        const p = self.plugin_mgr.getPluginForExtension(ext) orelse return;
        const client = self.clients.get(p.name) orelse return;

        _ = client.opened_files.remove(filename);
        _ = client.document_versions.remove(filename);

        if (client.state != .ready) return;

        const uri = try self.pathToUri(self.allocator, filename);
        defer self.allocator.free(uri);

        const notif = protocol.DidCloseNotification{
            .params = .{
                .textDocument = .{ .uri = uri },
            },
        };
        try client.send(notif);
    }

    pub fn requestCompletion(self: *LspManager, filename: []const u8, row: usize, col: usize) !void {
        logz.info().fmt("msg", "Requesting completion for {s} at {d}:{d}", .{ filename, row, col }).log();
        const ext = std.fs.path.extension(filename);
        const p = self.plugin_mgr.getPluginForExtension(ext) orelse return;
        const client = self.clients.get(p.name) orelse return;

        if (client.state != .ready) return;

        const uri = try self.pathToUri(self.allocator, filename);
        defer self.allocator.free(uri);

        const req = protocol.CompletionRequest{
            .id = client.request_id,
            .params = .{
                .textDocument = .{ .uri = uri },
                .position = .{ .line = row, .character = col },
            },
        };
        try client.pending_requests.put(client.request_id, .completion);
        client.request_id += 1;
        try client.send(req);
    }

    pub fn requestDefinition(self: *LspManager, filename: []const u8, row: usize, col: usize) !DefinitionRequestResult {
        logz.info().fmt("msg", "Requesting definition for {s} at {d}:{d}", .{ filename, row, col }).log();
        const ext = std.fs.path.extension(filename);
        const p = self.plugin_mgr.getPluginForExtension(ext) orelse return .no_plugin;
        const client = self.clients.get(p.name) orelse return .no_client;

        if (client.state != .ready) return .not_ready;

        const uri = try self.pathToUri(self.allocator, filename);
        defer self.allocator.free(uri);

        // Flamingo cursor columns are byte offsets today, matching the current
        // completion path. LSP characters are UTF-16 code units; add conversion
        // here when the editor grows a shared byte<->UTF-16 position helper.
        const request_id = client.request_id;
        const req = protocol.DefinitionRequest{
            .id = request_id,
            .params = .{
                .textDocument = .{ .uri = uri },
                .position = .{ .line = row, .character = col },
            },
        };
        try client.pending_requests.put(request_id, .definition);
        client.request_id += 1;
        try client.send(req);
        return .{ .requested = .{
            .request_id = request_id,
            .plugin_name = p.name,
        } };
    }

    pub fn pathToUri(self: *LspManager, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        var abs_path: []const u8 = undefined;
        var owned_path: ?[]u8 = null;
        var owned_path_z: ?[:0]u8 = null;
        defer {
            if (owned_path) |p| allocator.free(p);
            if (owned_path_z) |p| allocator.free(p);
        }

        if (std.fs.path.isAbsolute(path)) {
            owned_path = try allocator.dupe(u8, path);
            abs_path = owned_path.?;
        } else {
            owned_path_z = std.Io.Dir.cwd().realPathFileAlloc(self.io, path, allocator) catch |err| {
                logz.err().fmt("msg", "Failed to get realpath for {s}: {any}", .{ path, err }).log();
                return try allocator.dupe(u8, path); // fallback to original
            };
            abs_path = owned_path_z.?;
        }

        return try std.fmt.allocPrint(allocator, "file://{s}", .{abs_path});
    }

    pub fn workspaceRootForFile(self: *LspManager, filename: []const u8) ![]u8 {
        const parent = try self.absoluteParentDir(filename);
        defer self.allocator.free(parent);

        if (try self.findAncestorWithAny(parent, &.{ "buf.yaml", "buf.work.yaml", "buf.gen.yaml" })) |root| {
            return root;
        }
        if (try self.findAncestorWithAny(parent, &.{".git"})) |root| {
            return root;
        }
        return try self.allocator.dupe(u8, parent);
    }

    fn fallbackWorkspaceRoot(self: *LspManager, filename: []const u8) ![]u8 {
        return self.absoluteParentDir(filename) catch std.Io.Dir.cwd().realPathFileAlloc(self.io, ".", self.allocator);
    }

    fn absoluteParentDir(self: *LspManager, filename: []const u8) ![]u8 {
        const abs_file = if (std.fs.path.isAbsolute(filename))
            try self.allocator.dupe(u8, filename)
        else
            std.Io.Dir.cwd().realPathFileAlloc(self.io, filename, self.allocator) catch |err| blk: {
                if (std.fs.path.dirname(filename)) |dir| {
                    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(self.io, ".", self.allocator);
                    defer self.allocator.free(cwd);
                    break :blk try std.fs.path.join(self.allocator, &.{ cwd, dir });
                }
                return err;
            };
        defer self.allocator.free(abs_file);

        const parent = std.fs.path.dirname(abs_file) orelse abs_file;
        return try self.allocator.dupe(u8, parent);
    }

    fn findAncestorWithAny(self: *LspManager, start_dir: []const u8, markers: []const []const u8) !?[]u8 {
        var current = start_dir;
        while (true) {
            for (markers) |marker| {
                const candidate = try std.fs.path.join(self.allocator, &.{ current, marker });
                defer self.allocator.free(candidate);
                std.Io.Dir.accessAbsolute(self.io, candidate, .{}) catch continue;
                return try self.allocator.dupe(u8, current);
            }

            const parent = std.fs.path.dirname(current) orelse return null;
            if (parent.len == current.len) return null;
            current = parent;
        }
    }
};

pub fn firstDefinitionLocation(result: std.json.Value) ?DefinitionLocation {
    return switch (result) {
        .null => null,
        .object => |obj| definitionLocationFromObject(obj),
        .array => |arr| blk: {
            for (arr.items) |item| {
                if (item != .object) continue;
                if (definitionLocationFromObject(item.object)) |location| break :blk location;
            }
            break :blk null;
        },
        else => null,
    };
}

fn definitionLocationFromObject(obj: std.json.ObjectMap) ?DefinitionLocation {
    if (obj.get("uri")) |uri_val| {
        if (uri_val != .string) return null;
        const range = obj.get("range") orelse return null;
        const start = rangeStart(range) orelse return null;
        return .{ .uri = uri_val.string, .row = start.line, .col = start.character };
    }

    if (obj.get("targetUri")) |uri_val| {
        if (uri_val != .string) return null;
        const range = obj.get("targetSelectionRange") orelse obj.get("targetRange") orelse return null;
        const start = rangeStart(range) orelse return null;
        return .{ .uri = uri_val.string, .row = start.line, .col = start.character };
    }

    return null;
}

fn rangeStart(value: std.json.Value) ?protocol.Position {
    if (value != .object) return null;
    const start = value.object.get("start") orelse return null;
    if (start != .object) return null;
    const line = jsonUsize(start.object.get("line") orelse return null) orelse return null;
    const character = jsonUsize(start.object.get("character") orelse return null) orelse return null;
    return .{ .line = line, .character = character };
}

fn jsonUsize(value: std.json.Value) ?usize {
    return switch (value) {
        .integer => |i| if (i >= 0) @intCast(i) else null,
        else => null,
    };
}

pub fn fileUriToPathAlloc(allocator: std.mem.Allocator, uri: []const u8) ![]u8 {
    const file_prefix = "file://";
    if (!std.mem.startsWith(u8, uri, file_prefix)) return error.UnsupportedUri;

    const rest = uri[file_prefix.len..];
    const path = if (std.mem.startsWith(u8, rest, "localhost/"))
        rest["localhost".len..]
    else if (std.mem.startsWith(u8, rest, "/"))
        rest
    else
        return error.UnsupportedUriHost;

    return percentDecodeAlloc(allocator, path);
}

fn percentDecodeAlloc(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '%') {
            if (i + 2 >= input.len) return error.InvalidUriEscape;
            const hi = hexValue(input[i + 1]) orelse return error.InvalidUriEscape;
            const lo = hexValue(input[i + 2]) orelse return error.InvalidUriEscape;
            try out.append(allocator, (hi << 4) | lo);
            i += 3;
        } else {
            try out.append(allocator, input[i]);
            i += 1;
        }
    }

    return out.toOwnedSlice(allocator);
}

fn hexValue(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}
