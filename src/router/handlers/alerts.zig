const httpz = @import("httpz");

fn alerts(_: *httpz.Request, res: *httpz.Response) !void {
    try res.json(.{ .data = "OK" }, .{});
}
