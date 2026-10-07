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

    _ = try app.ws(allocator, init.io, PerSocketData, "/*", .{
        .compression = .disabled,
        .max_payload_length = 16 * 1024 * 1024,
        .idle_timeout = 60,
        .max_backpressure = 16 * 1024 * 1024,
        .close_on_backpressure_limit = false,
        .reset_idle_timeout_on_send = true,
        .send_pings_automatically = false,
        .upgrade = null,
        .open = .init(
            null,
            (struct {
                pub fn call(_: ?*anyopaque, a: std.mem.Allocator, io: std.Io, ws_: *zws.WebSocket(true, true, PerSocketData)) !void {
                    const per_socket_data: *PerSocketData = ws_.getUserData();
                    for (0..32) |i| {
                        var buffer: [128]u8 = undefined;
                        const topic = try a.dupe(u8, try std.fmt.bufPrint(&buffer, "{d}-{d}", .{ @intFromPtr(ws_), i }));
                        try per_socket_data.topics.append(a, topic);
                        _ = try ws_.subscribe(a, io, topic, false);
                    }
                }
            }).call,
            null,
        ),
        .message = .init(
            &app,
            (struct {
                pub fn call(ctx: ?*anyopaque, a: std.mem.Allocator, io: std.Io, ws_: *zws.WebSocket(true, true, PerSocketData), message: []const u8, op_code: zws.OpCode) !void {
                    const per_socket_data: *PerSocketData = ws_.getUserData();
                    const ctx_app: *zws.SslApp = @ptrCast(@alignCast(ctx));
                    per_socket_data.nr += 1;
                    _ = try ctx_app.publish(a, io, per_socket_data.topics.items[per_socket_data.nr % 32], message, op_code, false);
                    per_socket_data.nr += 1;
                    _ = try ws_.publish(a, io, per_socket_data.topics.items[per_socket_data.nr % 32], message, op_code, false);
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
