const httpz = @import("httpz");

fn search(_: *httpz.Request, res: *httpz.Response) !void {
    try res.json(.{ .data = "OK" }, .{});
}
