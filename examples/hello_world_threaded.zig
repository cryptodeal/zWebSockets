const std = @import("std");
const zws = @import("zWebSockets");
const zs = @import("zSockets");

const LocalCluster = zws.LocalCluster(zws.SslApp);

pub fn main(init: std.process.Init) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    // const allocator = std.heap.smp_allocator;
    try LocalCluster.init(allocator, init.io, .{
        .key_file_name = "misc/key.pem",
        .cert_file_name = "misc/cert.pem",
        .passphrase = "1234",
    }, .init(
        null,
        (struct {
            pub fn call(_: ?*anyopaque, a: std.mem.Allocator, io: std.Io, app: *LocalCluster.AppT) !void {
                _ = try app.get(a, "/*", .init(
                    null,
                    (struct {
                        pub fn call(_: ?*anyopaque, a_: std.mem.Allocator, io_: std.Io, res: *zws.HttpResponse(LocalCluster.ssl), _: *zws.HttpRequest) !void {
                            // std.debug.print("Responding from thread 0x{x:0<9}\n", .{std.Thread.getCurrentId()});
                            try res.end(a_, io_, "Hello world!", false);
                        }
                    }).call,
                    null,
                ));
                _ = try app.listen(a, io, .{ .port = 3000 }, .init(
                    null,
                    (struct {
                        pub fn call(_: ?*anyopaque, _: std.mem.Allocator, _: std.Io, listen_socket: ?*zs.ListenSocket) !void {
                            if (listen_socket) |ls| {
                                std.debug.print("Thread 0x{x:0<9} listening on port {d}\n", .{ std.Thread.getCurrentId(), try ls.s.localPort(true) });
                            } else {
                                std.debug.print("Thread 0x{x:0<9} failed to listen on port 3000\n", .{std.Thread.getCurrentId()});
                            }
                        }
                    }).call,
                    null,
                ));
            }
        }).call,
        null,
    ));
    defer LocalCluster.deinit(allocator);
}
