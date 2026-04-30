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
    io: std.Io,
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
        io: std.Io,
        plugin_name: []const u8,
        command: []const []const u8,
        queue: *event_queue.EventQueue,
    ) !*LspClient {
        var client = try allocator.create(LspClient);
        errdefer allocator.destroy(client);

        client.* = .{
            .allocator = allocator,
            .io = io,
            .plugin_name = try allocator.dupe(u8, plugin_name),
            .queue = queue,
            .quit_flag = std.atomic.Value(bool).init(false),
            .opened_files = std.StringHashMap(bool).init(allocator),
            .document_versions = std.StringHashMap(i32).init(allocator),
            .pending_requests = std.AutoHashMap(usize, RequestType).init(allocator),
            .process = undefined,
            .reader_thread = undefined,
            .stderr_thread = undefined,
        };
        var process_started = false;
        var reader_started = false;
        var stderr_started = false;
        errdefer {
            client.quit_flag.store(true, .seq_cst);
            if (process_started) client.process.kill(io);
            if (reader_started) client.reader_thread.join();
            if (stderr_started) client.stderr_thread.join();
            client.opened_files.deinit();
            client.document_versions.deinit();
            client.pending_requests.deinit();
            allocator.free(client.plugin_name);
            allocator.destroy(client);
        }

        client.process = try std.process.spawn(io, .{
            .argv = command,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
        });
        process_started = true;

        client.reader_thread = try std.Thread.spawn(.{}, readerLoop, .{client});
        reader_started = true;
        client.stderr_thread = try std.Thread.spawn(.{}, stderrLoop, .{client});
        stderr_started = true;

        return client;
    }

    pub fn stop(self: *LspClient) void {
        self.quit_flag.store(true, .seq_cst);

        self.process.kill(self.io);

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
        var reader_buf: [4096]u8 = undefined;
        var reader = stdout.readerStreaming(self.io, &reader_buf);

        while (!self.quit_flag.load(.seq_cst)) {
            var msg = rpc.readMessage(self.allocator, &reader.interface) catch |err| {
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
        var w = stdin.writer(self.io, &writer_buf);
        try rpc.writeMessage(&w.interface, json_payload);
        try w.interface.flush();
    }

    pub fn send(self: *LspClient, payload: anytype) !void {
        var out = std.Io.Writer.Allocating.init(self.allocator);
        defer out.deinit();
        try std.json.Stringify.value(payload, .{}, &out.writer);
        const json = out.written();
        logz.info().fmt("msg", "Stringified LSP payload: {s}", .{json}).log();
        try self.sendRequest(json);
    }

    fn stderrLoop(self: *LspClient) void {
        const stderr = self.process.stderr orelse return;
        var buf: [1024]u8 = undefined;
        var reader_buf: [4096]u8 = undefined;
        var reader = stderr.readerStreaming(self.io, &reader_buf);

        while (!self.quit_flag.load(.seq_cst)) {
            const n = reader.interface.readSliceShort(&buf) catch break;
            if (n == 0) break;
            logz.info().fmt("lsp_stderr", "[{s}] {s}", .{ self.plugin_name, buf[0..n] }).log();
        }
    }
};
