const std = @import("std");
const zws = @import("zWebSockets");
const zs = @import("zSockets");

pub fn main(init: std.process.Init) !void {
    // var gpa = std.heap.DebugAllocator(.{}){};
    // defer std.debug.assert(gpa.deinit() == .ok);
    // const allocator = gpa.allocator();

    const allocator = std.heap.smp_allocator;

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
                try res.end(a, io, &.{}, false);
            }
        }).call,
        null,
    ));

    _ = try app.any(allocator, "/*", .init(
        null,
        (struct {
            pub fn call(_: ?*anyopaque, a: std.mem.Allocator, _: std.Io, res: *zws.HttpResponse(zws.SslApp.Ssl), _: *zws.HttpRequest) !void {
                const AnyCtx = struct {
                    const This = @This();
                    rs: *zws.HttpResponse(zws.SslApp.Ssl),
                    buffer: ?std.ArrayList(u8) = null,

                    pub fn create(a_: std.mem.Allocator, rs: *zws.HttpResponse(zws.SslApp.Ssl)) !*This {
                        const self = try a_.create(This);
                        self.* = .{ .rs = rs };
                        return self;
                    }

                    pub fn deinit(a_: std.mem.Allocator, ctx: ?*anyopaque) void {
                        const self: *This = @ptrCast(@alignCast(ctx));
                        if (self.buffer) |*buffer| buffer.deinit(a_);
                        a_.destroy(self);
                    }
                };
                try res.onData(a, .init(
                    try AnyCtx.create(a, res),
                    (struct {
                        pub fn call(ctx: ?*anyopaque, a_: std.mem.Allocator, io_: std.Io, chunk: []const u8, is_fin: bool) !void {
                            const any_ctx: *AnyCtx = @ptrCast(@alignCast(ctx));
                            if (is_fin) {
                                @branchHint(.likely);
                                if (any_ctx.buffer) |*buffer| {
                                    @branchHint(.unlikely);
                                    try buffer.appendSlice(a_, chunk);
                                    try any_ctx.rs.end(a_, io_, buffer.items, false);
                                } else {
                                    try any_ctx.rs.end(a_, io_, chunk, false);
                                }
                            } else {
                                if (any_ctx.buffer) |*buffer| {
                                    try buffer.appendSlice(a_, chunk);
                                } else {
                                    any_ctx.buffer = std.ArrayList(u8).fromOwnedSlice(try a_.dupe(u8, chunk));
                                }
                            }
                        }
                    }).call,
                    AnyCtx.deinit,
                ));
                _ = res.onAborted(a, .init(
                    null,
                    (struct {
                        pub fn call(_: ?*anyopaque, _: std.mem.Allocator, _: std.Io) !void {}
                    }).call,
                    null,
                ));
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
