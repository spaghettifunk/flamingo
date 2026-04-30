const std = @import("std");
const plugin = @import("../plugin/manager.zig");
const lsp_client = @import("client.zig");
const event_queue = @import("../editor/event_queue.zig");
const protocol = @import("protocol.zig");
const logz = @import("logz");

pub const LspManager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    plugin_mgr: plugin.PluginManager,
    clients: std.StringHashMap(*lsp_client.LspClient),
    queue: *event_queue.EventQueue,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, queue: *event_queue.EventQueue) !LspManager {
        var mgr = plugin.PluginManager.init(allocator);
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
        self.plugin_mgr.deinit();
    }

    pub fn startLspForFile(self: *LspManager, filename: []const u8) !void {
        const ext = std.fs.path.extension(filename);
        if (self.plugin_mgr.getPluginForExtension(ext)) |p| {
            if (!self.clients.contains(p.name)) {
                logz.info().fmt("msg", "Starting LSP for plugin {s}", .{p.name}).log();
                const client = try lsp_client.LspClient.start(self.allocator, self.io, p.name, p.lsp_command, self.queue);
                try self.clients.put(p.name, client);

                try self.sendInitialize(client);
            }
        }
    }

    fn sendInitialize(self: *LspManager, client: *lsp_client.LspClient) !void {
        const cwd = std.Io.Dir.cwd().realPathFileAlloc(self.io, ".", self.allocator) catch |err| {
            logz.err().fmt("msg", "Failed to get CWD for LSP rootUri: {any}", .{err}).log();
            return err;
        };
        defer self.allocator.free(cwd);
        const root_uri = try std.fmt.allocPrint(self.allocator, "file://{s}", .{cwd});
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
                for (arr.items) |item| {
                    try new_arr.append(try cloneValue(allocator, item));
                }
                return .{ .array = new_arr };
            },
            .object => |obj| {
                var new_obj: std.json.ObjectMap = .{};
                var it = obj.iterator();
                while (it.next()) |entry| {
                    try new_obj.put(allocator, try allocator.dupe(u8, entry.key_ptr.*), try cloneValue(allocator, entry.value_ptr.*));
                }
                return .{ .object = new_obj };
            },
        }
    }

    pub fn freeValue(self: *LspManager, v: std.json.Value) void {
        switch (v) {
            .number_string => |s| self.allocator.free(s),
            .string => |s| self.allocator.free(s),
            .array => |arr| {
                for (arr.items) |item| {
                    self.freeValue(item);
                }
                var mutable_arr = arr;
                mutable_arr.deinit();
            },
            .object => |obj| {
                var it = obj.iterator();
                while (it.next()) |entry| {
                    self.allocator.free(entry.key_ptr.*);
                    self.freeValue(entry.value_ptr.*);
                }
                var mutable_obj = obj;
                mutable_obj.deinit(self.allocator);
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
                        .languageId = p.name,
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
};
