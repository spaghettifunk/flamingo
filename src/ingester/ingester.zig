const std = @import("std");
const chilli = @import("chilli");
const logz = @import("logz");
const httpz = @import("httpz");

const PORT = 8801;

pub fn ingester(_: chilli.CommandContext) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // call our shutdown function (below) when
    // SIGINT or SIGTERM are received
    std.posix.sigaction(std.posix.SIG.INT, &.{
        .handler = .{ .handler = shutdown },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    }, null);
    std.posix.sigaction(std.posix.SIG.TERM, &.{
        .handler = .{ .handler = shutdown },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    }, null);

    try init(allocator);
}

var server: ?*httpz.Server(void) = null;

pub fn init(allocator: std.mem.Allocator) !void {
    var s = try httpz.Server(void).init(allocator, .{
        .address = .localhost(PORT),
    }, {});
    defer s.deinit();

    var router = try s.router(.{});
    router.get("/healthz", healthz, .{});

    server = &s;
    try s.listen();
}

fn shutdown(_: c_int) callconv(.c) void {
    if (server) |s| {
        server = null;
        s.stop();
    }
}

fn healthz(_: *httpz.Request, res: *httpz.Response) !void {
    try res.json(.{ .data = "OK" }, .{});
}
