const std = @import("std");
const agent = @import("session.zig");

pub const OpenAIEventKind = enum {
    message_delta,
    tool_call,
    completed,
    error_message,
};

pub const OpenAIStreamEvent = struct {
    kind: OpenAIEventKind,
    text: []const u8 = "",
    tool_name: []const u8 = "",
    tool_arguments: []const u8 = "",
};

pub const OpenAIClient = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    api_key: []const u8,
    model: []const u8,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, api_key: []const u8, model: []const u8) OpenAIClient {
        return .{
            .allocator = allocator,
            .io = io,
            .api_key = api_key,
            .model = model,
        };
    }

    pub fn fetchResponseStream(self: *OpenAIClient, request: Request) ![]u8 {
        const payload = try buildResponseRequest(self.allocator, self.model, request);
        defer self.allocator.free(payload);

        var client = std.http.Client{ .allocator = self.allocator, .io = self.io };
        defer client.deinit();

        var response = std.Io.Writer.Allocating.init(self.allocator);
        errdefer response.deinit();

        var auth_buf: [512]u8 = undefined;
        const auth = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{self.api_key}) catch return error.ApiKeyTooLong;
        const headers = [_]std.http.Header{
            .{ .name = "authorization", .value = auth },
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "accept", .value = "text/event-stream" },
        };

        const result = try client.fetch(.{
            .location = .{ .url = "https://api.openai.com/v1/responses" },
            .method = .POST,
            .payload = payload,
            .extra_headers = &headers,
            .response_writer = &response.writer,
        });
        if (@intFromEnum(result.status) < 200 or @intFromEnum(result.status) >= 300) {
            return error.OpenAIRequestFailed;
        }
        return response.toOwnedSlice();
    }
};

pub const Request = struct {
    mode: agent.AgentMode,
    prompt: []const u8,
};

pub fn buildResponseRequest(allocator: std.mem.Allocator, model: []const u8, request: Request) ![]u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();
    const w = &out.writer;

    try w.writeAll("{\"model\":");
    try std.json.Stringify.value(model, .{}, w);
    try w.writeAll(",\"stream\":true,\"instructions\":");
    const instructions =
        \\You are a coding agent inside Flamingo. You may request workspace context only through host tools.
        \\Do not claim to write files directly. Code changes must be proposed as reviewable patches.
        \\For implementation requests, prepare a proposal instead of direct edits.
    ;
    try std.json.Stringify.value(instructions, .{}, w);
    try w.writeAll(",\"input\":");
    try std.json.Stringify.value(request.prompt, .{}, w);
    try w.writeAll(",\"metadata\":{\"mode\":");
    try std.json.Stringify.value(request.mode.label(), .{}, w);
    try w.writeAll("},\"tools\":");
    try writeToolSchemas(w);
    try w.writeAll("}");
    return out.toOwnedSlice();
}

fn writeToolSchemas(w: *std.Io.Writer) !void {
    try w.writeAll(
        \\[
        \\{"type":"function","name":"list_files","description":"List workspace files through the host-controlled tool registry.","parameters":{"type":"object","properties":{"root_relative_path":{"type":"string"},"max_results":{"type":"integer","minimum":1}}}},
        \\{"type":"function","name":"read_file","description":"Read a capped text file through the host-controlled tool registry.","parameters":{"type":"object","properties":{"path":{"type":"string"},"start_line":{"type":"integer","minimum":1},"max_lines":{"type":"integer","minimum":1}},"required":["path"]}},
        \\{"type":"function","name":"search_text","description":"Search text through the host-controlled tool registry.","parameters":{"type":"object","properties":{"query":{"type":"string"},"max_results":{"type":"integer","minimum":1}},"required":["query"]}},
        \\{"type":"function","name":"get_git_status","description":"Return workspace git status through the host.","parameters":{"type":"object","properties":{}}},
        \\{"type":"function","name":"get_git_diff_summary","description":"Return a compact git diff summary through the host.","parameters":{"type":"object","properties":{}}},
        \\{"type":"function","name":"propose_patch","description":"Create a patch proposal for user review. This must not write files.","parameters":{"type":"object","properties":{"file_path":{"type":"string"},"description":{"type":"string"},"unified_diff":{"type":"string"}},"required":["file_path","description","unified_diff"]}}
        \\]
    );
}

pub fn parseSseEvents(allocator: std.mem.Allocator, bytes: []const u8, sink: anytype) !void {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (!std.mem.startsWith(u8, line, "data:")) continue;
        const data = std.mem.trim(u8, line["data:".len..], " \t");
        if (std.mem.eql(u8, data, "[DONE]")) break;
        if (data.len == 0) continue;

        var parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch continue;
        defer parsed.deinit();
        const object = switch (parsed.value) {
            .object => |object| object,
            else => continue,
        };
        const type_value = jsonString(object.get("type")) orelse continue;
        if (std.mem.eql(u8, type_value, "response.output_text.delta")) {
            const delta = jsonString(object.get("delta")) orelse "";
            try sink.emit(.{ .kind = .message_delta, .text = delta });
        } else if (std.mem.eql(u8, type_value, "response.output_item.done")) {
            if (object.get("item")) |item_value| {
                const item = switch (item_value) {
                    .object => |item| item,
                    else => continue,
                };
                const item_type = jsonString(item.get("type")) orelse "";
                if (std.mem.eql(u8, item_type, "function_call")) {
                    const name = jsonString(item.get("name")) orelse "";
                    const arguments = jsonString(item.get("arguments")) orelse "{}";
                    try sink.emit(.{ .kind = .tool_call, .tool_name = name, .tool_arguments = arguments });
                }
            }
        } else if (std.mem.eql(u8, type_value, "response.completed")) {
            try sink.emit(.{ .kind = .completed });
        } else if (std.mem.eql(u8, type_value, "error")) {
            const message = jsonString(object.get("message")) orelse "OpenAI stream error";
            try sink.emit(.{ .kind = .error_message, .text = message });
        }
    }
}

fn jsonString(value: ?std.json.Value) ?[]const u8 {
    return switch (value orelse return null) {
        .string => |text| text,
        else => null,
    };
}

test "openai client builds responses request with tools" {
    const allocator = std.testing.allocator;
    const body = try buildResponseRequest(allocator, "gpt-5-codex", .{ .mode = .plan, .prompt = "inspect agent" });
    defer allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"model\":\"gpt-5-codex\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"stream\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"name\":\"search_text\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"name\":\"propose_patch\"") != null);
}

test "openai client parses sse text and completion events" {
    const Sink = struct {
        texts: std.ArrayListUnmanaged([]const u8) = .empty,
        completed: bool = false,

        pub fn emit(self: *@This(), event: OpenAIStreamEvent) !void {
            switch (event.kind) {
                .message_delta => try self.texts.append(std.testing.allocator, try std.testing.allocator.dupe(u8, event.text)),
                .tool_call => {},
                .completed => self.completed = true,
                .error_message => {},
            }
        }
    };

    var sink = Sink{};
    defer {
        for (sink.texts.items) |text| std.testing.allocator.free(text);
        sink.texts.deinit(std.testing.allocator);
    }
    try parseSseEvents(std.testing.allocator,
        \\data: {"type":"response.output_text.delta","delta":"hello"}
        \\data: {"type":"response.completed"}
        \\data: [DONE]
        \\
    , &sink);
    try std.testing.expectEqual(@as(usize, 1), sink.texts.items.len);
    try std.testing.expectEqualStrings("hello", sink.texts.items[0]);
    try std.testing.expect(sink.completed);
}

test "openai client parses function call events" {
    const Sink = struct {
        name: []u8 = &.{},
        args: []u8 = &.{},

        pub fn emit(self: *@This(), event: OpenAIStreamEvent) !void {
            switch (event.kind) {
                .tool_call => {
                    self.name = try std.testing.allocator.dupe(u8, event.tool_name);
                    self.args = try std.testing.allocator.dupe(u8, event.tool_arguments);
                },
                .message_delta, .completed, .error_message => {},
            }
        }
    };

    var sink = Sink{};
    defer {
        if (sink.name.len > 0) std.testing.allocator.free(sink.name);
        if (sink.args.len > 0) std.testing.allocator.free(sink.args);
    }
    try parseSseEvents(std.testing.allocator,
        \\data: {"type":"response.output_item.done","item":{"type":"function_call","name":"search_text","arguments":"{\"query\":\"agent\"}"}}
        \\data: [DONE]
        \\
    , &sink);
    try std.testing.expectEqualStrings("search_text", sink.name);
    try std.testing.expect(std.mem.indexOf(u8, sink.args, "agent") != null);
}
