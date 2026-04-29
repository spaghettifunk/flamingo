const std = @import("std");

pub const RpcMessage = struct {
    allocator: std.mem.Allocator,
    content: []u8, // JSON content

    pub fn deinit(self: *RpcMessage) void {
        self.allocator.free(self.content);
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
            const n = try reader.read(&b);
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
        const n = try reader.read(content[bytes_read..]);
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
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(alloc);

    const payload = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}";
    try writeMessage(buf.writer(alloc), payload);

    var fbs = std.io.fixedBufferStream(buf.items);
    var msg = try readMessage(alloc, fbs.reader());
    defer msg.deinit();

    try std.testing.expectEqualStrings(payload, msg.content);
}
