const httpz = @import("httpz");

pub fn status(_: *httpz.Request, res: *httpz.Response) !void {
    try res.json(.{ .data = "OK" }, .{});
}
