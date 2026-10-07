const std = @import("std");
const zws = @import("zWebSockets");
const zs = @import("zSockets");

// TODO: HTTP Cache needs testing to verify no allocations are leaking
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

    _ = try app.get(allocator, "/not-cached", .init(
        null,
        (struct {
            pub fn call(_: ?*anyopaque, a: std.mem.Allocator, io: std.Io, res: *zws.HttpResponse(zws.SslApp.Ssl), _: *zws.HttpRequest) !void {
                try res.end(a, io, "Responding without a cache", false);
            }
        }).call,
        null,
    ));

    _ = try app.http_cache.get(
        allocator,
        "/*",
        .init(
            null,
            (struct {
                pub fn call(_: ?*anyopaque, a: std.mem.Allocator, io: std.Io, res: *zws.SslApp.HttpCacheResponse, _: *zws.HttpRequest) !void {
                    std.debug.print("Filling cache now\n", .{});
                    try res.end(a, io, "This is a response", false);
                }
            }).call,
            null,
        ),
        .{ .lower_expiry = 1, .upper_expiry = 5 },
    );

    _ = try app.listen(allocator, init.io, .{ .port = 8080 }, .init(
        null,
        (struct {
            pub fn call(_: ?*anyopaque, _: std.mem.Allocator, _: std.Io, ls: ?*zs.ListenSocket) !void {
                if (ls) |_| {
                    std.debug.print("Listening on port: 8080\n", .{});
                } else {
                    std.debug.print("Failed to listen on port: 8080\n", .{});
                }
            }
        }).call,
        null,
    ));

    _ = try app.run(allocator, init.io);
}
