const std = @import("std");
const zws = @import("zWebSockets");
const zs = @import("zSockets");

const PerSocketData = struct {
    const Self = @This();
    topics: std.ArrayList([]const u8) = .empty,
    nr: u32 = 0,

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        for (self.topics.items) |t| {
            allocator.free(t);
        }
        self.topics.deinit(allocator);
    }
};

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

    _ = try app.get(allocator, "/*", .init(
        null,
        (struct {
            pub fn call(_: ?*anyopaque, a: std.mem.Allocator, io: std.Io, res: *zws.HttpResponse(zws.SslApp.Ssl), _: *zws.HttpRequest) !void {
                try res.end(a, io, "Hello world!", false);
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
