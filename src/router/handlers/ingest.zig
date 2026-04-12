const httpz = @import("httpz");

fn ingest(_: *httpz.Request, res: *httpz.Response) !void {
    try res.json(.{ .data = "OK" }, .{});
}
