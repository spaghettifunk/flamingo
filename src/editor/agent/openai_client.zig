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
    last_error_detail: ?[]u8 = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, api_key: []const u8, model: []const u8) OpenAIClient {
        return .{
            .allocator = allocator,
            .io = io,
            .api_key = api_key,
            .model = model,
        };
    }

    pub fn deinit(self: *OpenAIClient) void {
        self.clearErrorDetail();
        self.* = undefined;
    }

    pub fn errorDetail(self: *const OpenAIClient) ?[]const u8 {
        return self.last_error_detail;
    }

    pub fn fetchResponseStream(self: *OpenAIClient, request: Request) ![]u8 {
        self.clearErrorDetail();

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
            self.captureHttpError(result.status, response.written()) catch {};
            return error.OpenAIRequestFailed;
        }
        return response.toOwnedSlice();
    }

    fn clearErrorDetail(self: *OpenAIClient) void {
        if (self.last_error_detail) |detail| self.allocator.free(detail);
        self.last_error_detail = null;
    }

    fn captureHttpError(self: *OpenAIClient, status: std.http.Status, body: []const u8) !void {
        self.clearErrorDetail();
        self.last_error_detail = try formatHttpErrorDetail(self.allocator, status, body);
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
            const message = try formatStreamErrorMessage(allocator, object, data);
            defer allocator.free(message);
            try sink.emit(.{ .kind = .error_message, .text = message });
        } else if (std.mem.eql(u8, type_value, "response.failed")) {
            const message = try formatResponseFailureMessage(allocator, object, data);
            defer allocator.free(message);
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

fn formatHttpErrorDetail(allocator: std.mem.Allocator, status: std.http.Status, body: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, body, " \t\r\n");
    if (trimmed.len == 0) {
        return std.fmt.allocPrint(allocator, "HTTP {d}", .{@intFromEnum(status)});
    }

    if (parseOpenAIErrorMessage(allocator, trimmed)) |message| {
        defer allocator.free(message);
        return std.fmt.allocPrint(allocator, "HTTP {d}: {s}", .{ @intFromEnum(status), message });
    } else |_| {}

    const max_body_len: usize = 512;
    const shown = trimmed[0..@min(trimmed.len, max_body_len)];
    if (shown.len < trimmed.len) {
        return std.fmt.allocPrint(allocator, "HTTP {d}: {s}...", .{ @intFromEnum(status), shown });
    }
    return std.fmt.allocPrint(allocator, "HTTP {d}: {s}", .{ @intFromEnum(status), shown });
}

fn parseOpenAIErrorMessage(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidOpenAIErrorBody,
    };
    const error_value = root.get("error") orelse return error.InvalidOpenAIErrorBody;
    const error_object = switch (error_value) {
        .object => |object| object,
        else => return error.InvalidOpenAIErrorBody,
    };
    const message = jsonString(error_object.get("message")) orelse return error.InvalidOpenAIErrorBody;
    const type_name = jsonString(error_object.get("type"));
    const code = jsonString(error_object.get("code"));
    if (type_name) |kind| {
        if (code) |code_text| {
            return std.fmt.allocPrint(allocator, "{s} ({s}, {s})", .{ message, kind, code_text });
        }
        return std.fmt.allocPrint(allocator, "{s} ({s})", .{ message, kind });
    }
    if (code) |code_text| {
        return std.fmt.allocPrint(allocator, "{s} ({s})", .{ message, code_text });
    }
    return allocator.dupe(u8, message);
}

fn formatStreamErrorMessage(allocator: std.mem.Allocator, object: anytype, raw_event: []const u8) ![]u8 {
    if (jsonString(object.get("message"))) |message| {
        return formatErrorFields(
            allocator,
            "OpenAI stream error",
            message,
            jsonString(object.get("code")),
            jsonString(object.get("param")),
        );
    }

    if (object.get("error")) |error_value| {
        if (formatErrorValue(allocator, "OpenAI stream error", error_value)) |message| {
            return message;
        } else |_| {}
    }

    return formatRawStreamError(allocator, "OpenAI stream error", raw_event);
}

fn formatResponseFailureMessage(allocator: std.mem.Allocator, object: anytype, raw_event: []const u8) ![]u8 {
    if (object.get("response")) |response_value| {
        const response_object = switch (response_value) {
            .object => |response_object| response_object,
            else => return formatRawStreamError(allocator, "OpenAI response failed", raw_event),
        };
        if (response_object.get("error")) |error_value| {
            if (formatErrorValue(allocator, "OpenAI response failed", error_value)) |message| {
                return message;
            } else |_| {}
        }
        if (jsonString(response_object.get("status"))) |status| {
            return std.fmt.allocPrint(allocator, "OpenAI response failed: status {s}", .{status});
        }
    }
    return formatRawStreamError(allocator, "OpenAI response failed", raw_event);
}

fn formatErrorValue(allocator: std.mem.Allocator, prefix: []const u8, error_value: std.json.Value) ![]u8 {
    const error_object = switch (error_value) {
        .object => |error_object| error_object,
        else => return error.InvalidOpenAIErrorBody,
    };
    const message = jsonString(error_object.get("message")) orelse return error.InvalidOpenAIErrorBody;
    return formatErrorFields(
        allocator,
        prefix,
        message,
        jsonString(error_object.get("code")),
        jsonString(error_object.get("param")),
    );
}

fn formatErrorFields(
    allocator: std.mem.Allocator,
    prefix: []const u8,
    message: []const u8,
    code: ?[]const u8,
    param: ?[]const u8,
) ![]u8 {
    if (code) |code_text| {
        if (param) |param_text| {
            return std.fmt.allocPrint(allocator, "{s}: {s} ({s}, param: {s})", .{ prefix, message, code_text, param_text });
        }
        return std.fmt.allocPrint(allocator, "{s}: {s} ({s})", .{ prefix, message, code_text });
    }
    if (param) |param_text| {
        return std.fmt.allocPrint(allocator, "{s}: {s} (param: {s})", .{ prefix, message, param_text });
    }
    return std.fmt.allocPrint(allocator, "{s}: {s}", .{ prefix, message });
}

fn formatRawStreamError(allocator: std.mem.Allocator, prefix: []const u8, raw_event: []const u8) ![]u8 {
    const max_event_len: usize = 512;
    const shown = raw_event[0..@min(raw_event.len, max_event_len)];
    if (shown.len < raw_event.len) {
        return std.fmt.allocPrint(allocator, "{s}: {s}...", .{ prefix, shown });
    }
    return std.fmt.allocPrint(allocator, "{s}: {s}", .{ prefix, shown });
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

test "openai client parses top-level stream error details" {
    const Sink = struct {
        message: []u8 = &.{},

        pub fn emit(self: *@This(), event: OpenAIStreamEvent) !void {
            if (event.kind == .error_message) {
                self.message = try std.testing.allocator.dupe(u8, event.text);
            }
        }
    };

    var sink = Sink{};
    defer if (sink.message.len > 0) std.testing.allocator.free(sink.message);
    try parseSseEvents(std.testing.allocator,
        \\data: {"type":"error","code":"rate_limit_exceeded","message":"Too many requests","param":"model"}
        \\
    , &sink);
    try std.testing.expectEqualStrings("OpenAI stream error: Too many requests (rate_limit_exceeded, param: model)", sink.message);
}

test "openai client parses response failed error details" {
    const Sink = struct {
        message: []u8 = &.{},

        pub fn emit(self: *@This(), event: OpenAIStreamEvent) !void {
            if (event.kind == .error_message) {
                self.message = try std.testing.allocator.dupe(u8, event.text);
            }
        }
    };

    var sink = Sink{};
    defer if (sink.message.len > 0) std.testing.allocator.free(sink.message);
    try parseSseEvents(std.testing.allocator,
        \\data: {"type":"response.failed","response":{"status":"failed","error":{"code":"server_error","message":"Generation failed"}}}
        \\
    , &sink);
    try std.testing.expectEqualStrings("OpenAI response failed: Generation failed (server_error)", sink.message);
}

test "openai client formats JSON request error details" {
    const detail = try formatHttpErrorDetail(std.testing.allocator, .bad_request,
        \\{"error":{"message":"Unknown model","type":"invalid_request_error","code":"model_not_found"}}
    );
    defer std.testing.allocator.free(detail);
    try std.testing.expectEqualStrings("HTTP 400: Unknown model (invalid_request_error, model_not_found)", detail);
}

test "openai client formats non-JSON request error details" {
    const detail = try formatHttpErrorDetail(std.testing.allocator, .bad_gateway, "upstream unavailable");
    defer std.testing.allocator.free(detail);
    try std.testing.expectEqualStrings("HTTP 502: upstream unavailable", detail);
}
