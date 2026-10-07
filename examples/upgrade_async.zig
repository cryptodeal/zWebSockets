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
                    const UpgradeData = struct {
                        const This = @This();
                        sec_websocket_key: []const u8,
                        sec_websocket_protocol: []const u8,
                        sec_websocket_extensions: []const u8,
                        context: *zs.SocketContext,
                        http_res: *zws.HttpResponse(zws.SslApp.Ssl),
                        aborted: bool = false,

                        pub fn create(a_: std.mem.Allocator, sec_websocket_key: []const u8, sec_websocket_protocol: []const u8, sec_websocket_extensions: []const u8, ctx: *zs.SocketContext, http_res: *zws.HttpResponse(zws.SslApp.Ssl)) !*This {
                            const self = try a_.create(This);
                            self.* = .{
                                .sec_websocket_key = try a_.dupe(u8, sec_websocket_key),
                                .sec_websocket_protocol = try a_.dupe(u8, sec_websocket_protocol),
                                .sec_websocket_extensions = try a_.dupe(u8, sec_websocket_extensions),
                                .context = ctx,
                                .http_res = http_res,
                            };
                            return self;
                        }

                        pub fn deinit(self: *This, a_: std.mem.Allocator) void {
                            a_.free(self.sec_websocket_key);
                            a_.free(self.sec_websocket_protocol);
                            a_.free(self.sec_websocket_extensions);
                            a_.destroy(self);
                        }
                    };
                    const upgrade_data = try UpgradeData.create(a, req.getHeader("sec-websocket-key") orelse &.{}, req.getHeader("sec-websocket-protocol") orelse &.{}, req.getHeader("sec-websocket-extensions") orelse &.{}, context, res);
                    _ = res.onAborted(a, .init(upgrade_data, (struct {
                        pub fn call(c: ?*anyopaque, _: std.mem.Allocator, _: std.Io) !void {
                            const upgrade_ctx: *UpgradeData = @ptrCast(@alignCast(c));
                            upgrade_ctx.aborted = true;
                            std.debug.print("HTTP socket was closed before we upgraded it!\n", .{});
                        }
                    }).call, null));

                    const loop = try zws.Loop.get(a, io, null);
                    const delay_timer = try zs.createTimer(a, io, @ptrCast(@alignCast(loop)), false, &.{*UpgradeData});
                    @memcpy(std.mem.asBytes(zs.getTimerExt(delay_timer, 0, *UpgradeData).?), std.mem.asBytes(&upgrade_data));
                    zs.timerSet(delay_timer, (struct {
                        pub fn call(a_: std.mem.Allocator, io_: std.Io, timer: *zs.Timer) !void {
                            var upgrade_data_ctx: *UpgradeData = undefined;
                            @memcpy(std.mem.asBytes(&upgrade_data_ctx), std.mem.asBytes(zs.getTimerExt(timer, 0, *UpgradeData).?));
                            if (!upgrade_data_ctx.aborted) {
                                std.debug.print("Async task done, upgrading to WebSocket now!\n", .{});
                                _ = try upgrade_data_ctx.http_res.cork(a_, io_, .init(upgrade_data_ctx, (struct {
                                    pub fn call(c: ?*anyopaque, _a: std.mem.Allocator, _io: std.Io) !void {
                                        const u_data_ctx: *UpgradeData = @ptrCast(@alignCast(c));
                                        try u_data_ctx.http_res.upgrade(
                                            PerSocketData,
                                            _a,
                                            _io,
                                            .{ .something = 13 },
                                            u_data_ctx.sec_websocket_key,
                                            u_data_ctx.sec_websocket_protocol,
                                            u_data_ctx.sec_websocket_extensions,
                                            u_data_ctx.context,
                                        );
                                    }
                                }).call, null));
                            } else {
                                std.debug.print("Async task done, but the HTTP socket was closed. Skipping upgrade to WebSocket!\n", .{});
                            }
                            upgrade_data_ctx.deinit(a_);
                            zs.timerClose(a_, timer);
                        }
                    }).call, 5000, 0);
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
