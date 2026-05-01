const std = @import("std");
const logz = @import("logz");

pub fn init(io: std.Io, allocator: std.mem.Allocator, debug_enabled: bool) !void {
    try logz.setup(io, allocator, .{
        .level = if (debug_enabled) .Debug else .None,
        .pool_size = 100,
        .buffer_size = 4096,
        .large_buffer_count = 8,
        .large_buffer_size = 16384,
        .output = if (debug_enabled) .{ .file = "flamingo.log" } else .stdout,
        .encoding = .logfmt,
    });
}

pub fn shutdown() !void {
    logz.deinit();
}
