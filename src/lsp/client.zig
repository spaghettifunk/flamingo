const std = @import("std");
const rpc = @import("rpc.zig");
const logz = @import("logz");
const event_queue = @import("../editor/event_queue.zig");

pub const ClientState = enum {
    uninitialized,
    initializing,
    ready,
};

pub const RequestType = enum {
    initialize,
    completion,
};

pub const LspClient = struct {
    allocator: std.mem.Allocator,
    plugin_name: []const u8,
    process: std.process.Child,
    reader_thread: std.Thread,
    stderr_thread: std.Thread,
    queue: *event_queue.EventQueue,
    quit_flag: std.atomic.Value(bool),
    state: ClientState = .uninitialized,
    request_id: usize = 1,
    opened_files: std.StringHashMap(bool),
    document_versions: std.StringHashMap(i32),
    pending_requests: std.AutoHashMap(usize, RequestType),

    pub fn start(
        allocator: std.mem.Allocator,
        plugin_name: []const u8,
        command: []const []const u8,
        queue: *event_queue.EventQueue,
    ) !*LspClient {
        var client = try allocator.create(LspClient);
        errdefer allocator.destroy(client);

        client.* = .{
            .allocator = allocator,
            .plugin_name = try allocator.dupe(u8, plugin_name),
            .queue = queue,
            .quit_flag = std.atomic.Value(bool).init(false),
            .opened_files = std.StringHashMap(bool).init(allocator),
            .document_versions = std.StringHashMap(i32).init(allocator),
            .pending_requests = std.AutoHashMap(usize, RequestType).init(allocator),
            .process = std.process.Child.init(command, allocator),
            .reader_thread = undefined,
            .stderr_thread = undefined,
        };

        client.process.stdin_behavior = .Pipe;
        client.process.stdout_behavior = .Pipe;
        client.process.stderr_behavior = .Pipe;

        try client.process.spawn();

        client.reader_thread = try std.Thread.spawn(.{}, readerLoop, .{client});
        client.stderr_thread = try std.Thread.spawn(.{}, stderrLoop, .{client});

        return client;
    }

    pub fn stop(self: *LspClient) void {
        self.quit_flag.store(true, .seq_cst);

        _ = self.process.kill() catch {};

        self.reader_thread.join();
        self.stderr_thread.join();
        self.allocator.free(self.plugin_name);
        self.opened_files.deinit();
        self.document_versions.deinit();
        self.pending_requests.deinit();
        self.allocator.destroy(self);
    }

    fn readerLoop(self: *LspClient) void {
        const stdout = self.process.stdout orelse return;

        while (!self.quit_flag.load(.seq_cst)) {
            var msg = rpc.readMessage(self.allocator, stdout) catch |err| {
                if (err == error.EndOfStream) break;
                logz.err().fmt("msg", "rpc read error: {any}", .{err}).log();
                break;
            };

            self.queue.push(.{
                .lsp_message = .{
                    .plugin_name = self.plugin_name,
                    .message = msg.content,
                },
            }) catch {
                msg.deinit();
                break;
            };
            // We transfer ownership of msg.content to the queue
        }
    }

    pub fn sendRequest(self: *LspClient, json_payload: []const u8) !void {
        logz.info().fmt("msg", "Sending LSP request to {s}: {s}", .{ self.plugin_name, json_payload }).log();
        const stdin = self.process.stdin orelse return error.NoStdin;

        var writer_buf: [1]u8 = undefined;
        var w = stdin.writer(&writer_buf).interface;
        try rpc.writeMessage(&w, json_payload);
    }

    pub fn send(self: *LspClient, payload: anytype) !void {
        var out = std.io.Writer.Allocating.init(self.allocator);
        defer out.deinit();
        try std.json.Stringify.value(payload, .{}, &out.writer);
        const json = out.written();
        logz.info().fmt("msg", "Stringified LSP payload: {s}", .{json}).log();
        try self.sendRequest(json);
    }

    fn stderrLoop(self: *LspClient) void {
        const stderr = self.process.stderr orelse return;
        var buf: [1024]u8 = undefined;

        while (!self.quit_flag.load(.seq_cst)) {
            const n = stderr.read(&buf) catch break;
            if (n == 0) break;
            logz.info().fmt("lsp_stderr", "[{s}] {s}", .{ self.plugin_name, buf[0..n] }).log();
        }
    }
};
