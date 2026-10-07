const std = @import("std");
const zws = @import("zWebSockets");
const zs = @import("zSockets");

pub fn main(init: std.process.Init) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    // const allocator = std.heap.smp_allocator;

    var app = try zws.SslApp.init(allocator, init.io, .{
        .key_file_name = "misc/key.pem",
        .cert_file_name = "misc/cert.pem",
        .passphrase = "1234",
    });
    // need to handle this better
    defer app.deinit(allocator, init.io) catch unreachable;

    _ = try app.get(allocator, "/:first/static/:second", .init(
        null,
        (struct {
            pub fn call(_: ?*anyopaque, a: std.mem.Allocator, io: std.Io, res: *zws.HttpResponse(zws.SslApp.Ssl), req: *zws.HttpRequest) !void {
                _ = try res.write(a, "<h1>first is: ");
                _ = try res.write(a, req.getParameter(.{ .name = "first" }).?);
                _ = try res.write(a, "</h1>");
                _ = try res.write(a, "<h1>second is: ");
                _ = try res.write(a, req.getParameter(.{ .name = "second" }).?);
                try res.end(a, io, "</h1>", false);
            }
        }).call,
        null,
    ));

    _ = try app.listen(allocator, init.io, .{ .port = 3000 }, .init(
        null,
        (struct {
            pub fn call(_: ?*anyopaque, _: std.mem.Allocator, _: std.Io, ls: ?*zs.ListenSocket) !void {
                if (ls) |_| {
                    std.debug.print("Listening on port: 3000\n", .{});
                }
            }
        }).call,
        null,
    ));

    _ = try app.run(allocator, init.io);
}
