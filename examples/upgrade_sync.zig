const std = @import("std");
const zws = @import("zWebSockets");
const zs = @import("zSockets");

const PerSocketData = struct {
    something: i32,
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

    _ = try app.ws(allocator, init.io, PerSocketData, "/*", .{
        .compression = .shared_compressor,
        .max_payload_length = 16 * 1024,
        .idle_timeout = 10,
        .max_backpressure = 1 * 1024 * 1024,
        .close_on_backpressure_limit = false,
        .reset_idle_timeout_on_send = false,
        .send_pings_automatically = true,
        .upgrade = .init(
            null,
            (struct {
                pub fn call(_: ?*anyopaque, a: std.mem.Allocator, io: std.Io, res: *zws.HttpResponse(zws.SslApp.Ssl), req: *zws.HttpRequest, context: *zs.SocketContext) !void {
                    try res.upgrade(
                        PerSocketData,
                        a,
                        io,
                        .{ .something = 13 },
                        req.getHeader("sec-websocket-key") orelse &.{},
                        req.getHeader("sec-websocket-protocol") orelse &.{},
                        req.getHeader("sec-websocket-extensions") orelse &.{},
                        context,
                    );
                }
            }).call,
            null,
        ),
        .open = .init(
            null,
            (struct {
                pub fn call(_: ?*anyopaque, _: std.mem.Allocator, _: std.Io, ws_: *zws.WebSocket(true, true, PerSocketData)) !void {
                    std.debug.print("Something is: {d}\n", .{ws_.getUserData().something});
                }
            }).call,
            null,
        ),
        .message = .init(
            null,
            (struct {
                pub fn call(_: ?*anyopaque, a: std.mem.Allocator, io: std.Io, ws_: *zws.WebSocket(true, true, PerSocketData), message: []const u8, op_code: zws.OpCode) !void {
                    _ = try ws_.send(a, io, message, op_code, .no_action, true);
                }
            }).call,
            null,
        ),
        .drain = .init(
            null,
            (struct {
                pub fn call(_: ?*anyopaque, _: std.mem.Allocator, _: std.Io, _: *zws.WebSocket(true, true, PerSocketData)) !void {}
            }).call,
            null,
        ),
        .ping = .init(
            null,
            (struct {
                pub fn call(_: ?*anyopaque, _: std.mem.Allocator, _: std.Io, _: *zws.WebSocket(true, true, PerSocketData), _: []const u8) !void {}
            }).call,
            null,
        ),
        .pong = .init(
            null,
            (struct {
                pub fn call(_: ?*anyopaque, _: std.mem.Allocator, _: std.Io, _: *zws.WebSocket(true, true, PerSocketData), _: []const u8) !void {}
            }).call,
            null,
        ),
        .close = .init(
            null,
            (struct {
                pub fn call(_: ?*anyopaque, _: std.mem.Allocator, _: std.Io, _: *zws.WebSocket(true, true, PerSocketData), _: i32, _: []const u8) !void {}
            }).call,
            null,
        ),
    });

    _ = try app.listen(allocator, init.io, .{ .port = 9001 }, .init(
        null,
        (struct {
            pub fn call(_: ?*anyopaque, _: std.mem.Allocator, _: std.Io, ls: ?*zs.ListenSocket) !void {
                if (ls) |_| {
                    std.debug.print("Listening on port: 9001\n", .{});
                }
            }
        }).call,
        null,
    ));

    _ = try app.run(allocator, init.io);
}
