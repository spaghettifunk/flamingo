const std = @import("std");
const logz = @import("logz");
const ts = @import("tree-sitter");
const event_queue = @import("event_queue.zig");
const syntax = @import("../syntax.zig");

const ParseRequest = struct {
    buffer_id: u64,
    revision: u64,
    language: syntax.LanguageId,
    source: []u8,

    fn deinit(self: *ParseRequest, allocator: std.mem.Allocator) void {
        if (self.source.len > 0) {
            allocator.free(self.source);
            self.source = &.{};
        }
    }
};

pub const SyntaxParseWorker = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    queue: *event_queue.EventQueue,
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    pending: ?ParseRequest = null,
    quit: bool = false,
    thread: std.Thread = undefined,

    pub fn start(allocator: std.mem.Allocator, io: std.Io, queue: *event_queue.EventQueue) !*SyntaxParseWorker {
        const worker = try allocator.create(SyntaxParseWorker);
        errdefer allocator.destroy(worker);

        worker.* = .{
            .allocator = allocator,
            .io = io,
            .queue = queue,
        };

        worker.thread = try std.Thread.spawn(.{}, run, .{worker});
        return worker;
    }

    pub fn stop(self: *SyntaxParseWorker) void {
        // Stop producers before the editor closes the shared EventQueue. Any
        // in-flight source snapshot remains owned here until discarded or
        // transferred through a successful queue push.
        self.mutex.lockUncancelable(self.io);
        self.quit = true;
        if (self.pending) |*request| {
            request.deinit(self.allocator);
            self.pending = null;
        }
        self.cond.signal(self.io);
        self.mutex.unlock(self.io);

        self.thread.join();
        self.allocator.destroy(self);
    }

    pub fn requestParse(
        self: *SyntaxParseWorker,
        buffer_id: u64,
        revision: u64,
        language: syntax.LanguageId,
        source: []u8,
    ) void {
        var request = ParseRequest{
            .buffer_id = buffer_id,
            .revision = revision,
            .language = language,
            .source = source,
        };

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.quit) {
            request.deinit(self.allocator);
            return;
        }

        if (self.pending) |*old| {
            old.deinit(self.allocator);
        }
        self.pending = request;
        self.cond.signal(self.io);
    }

    fn run(self: *SyntaxParseWorker) void {
        var parser: ?*ts.Parser = null;
        defer if (parser) |p| p.destroy();
        var parser_language: ?syntax.LanguageId = null;

        while (true) {
            var request = self.takeRequest() orelse break;

            if (parser == null) {
                parser = ts.Parser.create();
                parser_language = null;
            }

            if (parser_language == null or parser_language.? != request.language) {
                parser.?.setLanguage(syntax.languagePtr(request.language)) catch |err| {
                    logz.err().fmt("msg", "syntax parser language setup failed: {any}", .{err}).log();
                    request.deinit(self.allocator);
                    continue;
                };
                parser_language = request.language;
            }

            const tree = parser.?.parseString(request.source, null) orelse {
                logz.debug().fmt("msg", "syntax parser returned no tree for revision {d}", .{request.revision}).log();
                request.deinit(self.allocator);
                continue;
            };
            const markdown_inline_tree = if (request.language == .markdown)
                syntax.parseMarkdownInlineTree(self.allocator, request.source, tree) catch |err| {
                    logz.err().fmt("msg", "markdown inline parse failed: {any}", .{err}).log();
                    tree.destroy();
                    request.deinit(self.allocator);
                    continue;
                }
            else
                null;

            if (self.isQuitting()) {
                tree.destroy();
                if (markdown_inline_tree) |inline_tree| inline_tree.destroy();
                request.deinit(self.allocator);
                continue;
            }

            const result = syntax.ParseResult{
                .buffer_id = request.buffer_id,
                .revision = request.revision,
                .language = request.language,
                .source = request.source,
                .tree = tree,
                .markdown_inline_tree = markdown_inline_tree,
            };
            request.source = &.{};

            self.queue.push(.{ .syntax_parse_result = result }) catch |err| {
                logz.err().fmt("msg", "failed to enqueue syntax parse result: {any}", .{err}).log();
                var owned = result;
                owned.deinit(self.allocator);
            };
        }
    }

    fn takeRequest(self: *SyntaxParseWorker) ?ParseRequest {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        while (self.pending == null and !self.quit) {
            self.cond.waitUncancelable(self.io, &self.mutex);
        }

        if (self.pending) |request| {
            self.pending = null;
            return request;
        }

        return null;
    }

    fn isQuitting(self: *SyntaxParseWorker) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.quit;
    }
};
