const std = @import("std");

fn DeclType(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .pointer => |ptr| ptr.child,
        else => T,
    };
}

fn readShort(reader: anytype, buffer: []u8) !usize {
    if (comptime @hasDecl(DeclType(@TypeOf(reader)), "readSliceShort")) {
        return reader.readSliceShort(buffer);
    }
    return reader.read(buffer);
}

pub const RpcMessage = struct {
    allocator: std.mem.Allocator,
    content: []u8, // JSON content

    pub fn deinit(self: *RpcMessage) void {
        if (self.content.len > 0) {
            self.allocator.free(self.content);
            self.content = &[_]u8{};
        }
    }
};

/// Reads a single JSON-RPC message from a blocking reader.
/// The caller owns the returned message and must call deinit().
pub fn readMessage(allocator: std.mem.Allocator, reader: anytype) !RpcMessage {
    var content_length: usize = 0;

    // Read headers
    while (true) {
        var line_buf: [256]u8 = undefined;
        var len: usize = 0;
        while (len < line_buf.len) {
            var b: [1]u8 = undefined;
            const n = try readShort(reader, &b);
            if (n == 0) return error.EndOfStream;

            line_buf[len] = b[0];
            len += 1;
            if (b[0] == '\n') break;
        }

        var trimmed = line_buf[0..len];
        if (trimmed.len > 0 and trimmed[trimmed.len - 1] == '\n') trimmed = trimmed[0 .. trimmed.len - 1];
        if (trimmed.len > 0 and trimmed[trimmed.len - 1] == '\r') trimmed = trimmed[0 .. trimmed.len - 1];

        if (trimmed.len == 0) break; // empty line \r\n signals end of headers

        const prefix = "Content-Length: ";
        if (std.mem.startsWith(u8, trimmed, prefix)) {
            const len_str = trimmed[prefix.len..];
            content_length = try std.fmt.parseInt(usize, len_str, 10);
        }
    }

    if (content_length == 0) return error.InvalidContentLength;

    const content = try allocator.alloc(u8, content_length);
    errdefer allocator.free(content);

    var bytes_read: usize = 0;
    while (bytes_read < content_length) {
        const n = try readShort(reader, content[bytes_read..]);
        if (n == 0) return error.UnexpectedEndOfStream;
        bytes_read += n;
    }

    return RpcMessage{
        .allocator = allocator,
        .content = content,
    };
}

/// Writes a JSON-RPC message to a writer.
pub fn writeMessage(writer: anytype, json_content: []const u8) !void {
    try writer.print("Content-Length: {d}\r\n\r\n{s}", .{ json_content.len, json_content });
}

test "rpc write and read" {
    const alloc = std.testing.allocator;
    var out = std.Io.Writer.Allocating.init(alloc);
    defer out.deinit();

    const payload = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}";
    try writeMessage(&out.writer, payload);

    var reader = std.Io.Reader.fixed(out.written());
    var msg = try readMessage(alloc, &reader);
    defer msg.deinit();

    try std.testing.expectEqualStrings(payload, msg.content);
}
