const std = @import("std");
const chilli = @import("chilli");
const logz = @import("logz");
const httpz = @import("httpz");
const context = @import("../context.zig");
const status = @import("handlers/status.zig");

const PORT = 8801;
var server: ?*httpz.Server(void) = null;

pub fn router(ctx: chilli.CommandContext) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // call our shutdown function when
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

    const flamingo_ctx = ctx.getContextData(context.FlamingoContext).?;

    try start(allocator, flamingo_ctx);
}

fn start(allocator: std.mem.Allocator, fctx: *context.FlamingoContext) !void {
    var s = try httpz.Server(void).init(allocator, .{
        .address = .localhost(fctx.config.http.port),
    }, {});
    defer s.deinit();

    var r = try s.router(.{});
    r.get("/healthz", healthz, .{});

    var api = r.group("/api/v1", .{});
    api.get("/api/v1/status", status.status, .{});

    server = &s;

    logz.info()
        .string("msg", "Listening")
        .string("address", fctx.config.http.address)
        .int("port", fctx.config.http.port)
        .log();
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
