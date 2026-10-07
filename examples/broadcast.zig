const std = @import("std");
const zws = @import("zWebSockets");
const zs = @import("zSockets");

const PerSocketData = struct {};

var global_app: *zws.SslApp = undefined;

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
        .max_payload_length = 16 * 1024 * 1024,
        .idle_timeout = 16,
        .max_backpressure = 1 * 1024 * 1024,
        .close_on_backpressure_limit = false,
        .reset_idle_timeout_on_send = false,
        .send_pings_automatically = true,
        .upgrade = null,
        .open = .init(
            null,
            (struct {
                pub fn call(_: ?*anyopaque, a: std.mem.Allocator, io: std.Io, ws_: *zws.WebSocket(true, true, PerSocketData)) !void {
                    _ = try ws_.subscribe(a, io, "broadcast", false);
                }
            }).call,
            null,
        ),
        .message = .init(
            null,
            (struct {
                pub fn call(_: ?*anyopaque, _: std.mem.Allocator, _: std.Io, _: *zws.WebSocket(true, true, PerSocketData), _: []const u8, _: zws.OpCode) !void {}
            }).call,
            null,
        ),
        .drain = .init(
            null,
            (struct {
                pub fn call(_: ?*anyopaque, a: std.mem.Allocator, io: std.Io, ws_: *zws.WebSocket(true, true, PerSocketData)) !void {
                    _ = try ws_.subscribe(a, io, "broadcast", false);
                }
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

    const loop: *zs.Loop = @ptrCast(@alignCast(try zws.Loop.get(allocator, init.io, null)));
    const delay_timer = try zs.createTimer(allocator, init.io, loop, false, &.{});
    zs.timerSet(
        delay_timer,
        (struct {
            pub fn call(a: std.mem.Allocator, io: std.Io, _: *zs.Timer) !void {
                const millis = std.Io.Clock.real.now(io).toMilliseconds();
                // std.debug.print("Broadcasting timestamp: {d}\n", .{millis});
                _ = try global_app.publish(a, io, "broadcast", std.mem.asBytes(&millis), .binary, false);
            }
        }).call,
        8,
        8,
    );
    global_app = &app;
    _ = try app.run(allocator, init.io);
}
