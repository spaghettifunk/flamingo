const std = @import("std");
const logz = @import("logz");

pub fn init(allocator: std.mem.Allocator, log_level: u3) !void {
    // initialize a logging pool
    try logz.setup(allocator, .{
        .level = @enumFromInt(log_level),
        .pool_size = 100,
        .buffer_size = 4096,
        .large_buffer_count = 8,
        .large_buffer_size = 16384,
        .output = .stdout,
        .encoding = .logfmt,
    });
}

pub fn shutdown() !void {
    logz.deinit();
}
