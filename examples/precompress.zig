const std = @import("std");
const zws = @import("zWebSockets");
const zs = @import("zSockets");

const PerSocketData = struct {};

const MessageCtx = struct {
    const Self = @This();
    m: *std.Io.Mutex,
    prepared_message: *zws.PreparedMessage,
    app: *zws.App,

    pub fn init(allocator: std.mem.Allocator, m: *std.Io.Mutex, prepared_message: *zws.PreparedMessage, app: *zws.App) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .m = m,
            .prepared_message = prepared_message,
            .app = app,
        };
        return self;
    }

    pub fn deinit(allocator: std.mem.Allocator, ctx: ?*anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        allocator.destroy(self);
    }
};

fn spawnThread(allocator: std.mem.Allocator, io: std.Io, m: *std.Io.Mutex, prepared_message: *zws.PreparedMessage) !void {
    var counter: usize = 1;
    var buffer: [128]u8 = undefined;
    while (true) : (counter += 1) {
        try m.lock(io);
        const new_message = try std.fmt.bufPrint(&buffer, "Hello you are looking at message number {d} and this text should be precompressed", .{counter});
        prepared_message.* = try (try zws.Loop.get(allocator, io, null)).prepareMessage(allocator, new_message, @intFromEnum(zws.OpCode.text), true);
        m.unlock(io);
        try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(500), .real);
    }
}

pub fn main(init: std.process.Init) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    // const allocator = std.heap.smp_allocator;

    var prepared_message: zws.PreparedMessage = undefined;
    var m: std.Io.Mutex = .init;

    var t2 = try std.Thread.spawn(.{ .allocator = allocator }, spawnThread, .{ allocator, init.io, &m, &prepared_message });

    var app = try zws.App.init(allocator, init.io, .{});
    defer app.deinit(allocator, init.io) catch unreachable;

    _ = try app.ws(allocator, init.io, PerSocketData, "/*", .{
        .compression = @enumFromInt(@intFromEnum(zws.CompressOptions.shared_compressor) | zws.CompressOptions.dedicated_decompressor),
        .upgrade = null,
        .open = .init(
            null,
            (struct {
                pub fn call(_: ?*anyopaque, _: std.mem.Allocator, _: std.Io, _: *zws.WebSocket(false, true, PerSocketData)) !void {}
            }).call,
            null,
        ),
        .message = .init(
            try MessageCtx.init(allocator, &m, &prepared_message, &app),
            (struct {
                pub fn call(ctx: ?*anyopaque, a: std.mem.Allocator, io: std.Io, ws_: *zws.WebSocket(false, true, PerSocketData), message: []const u8, op_code: zws.OpCode) !void {
                    const message_ctx: *MessageCtx = @ptrCast(@alignCast(ctx));
                    _ = try ws_.send(a, io, message, op_code, .no_action, true);
                    try message_ctx.m.lock(io);
                    _ = try ws_.sendPrepared(a, io, message_ctx.prepared_message.*);
                    _ = try ws_.subscribe(a, io, "test", false);
                    _ = try message_ctx.app.publishPrepared(a, io, "test", message_ctx.prepared_message.*);
                    _ = try ws_.unsubscribe(a, io, "test", false);
                    message_ctx.m.unlock(io);
                }
            }).call,
            MessageCtx.deinit,
        ),
        .dropped = .init(
            null,
            (struct {
                pub fn call(_: ?*anyopaque, _: std.mem.Allocator, _: std.Io, _: *zws.WebSocket(false, true, PerSocketData), _: []const u8, _: zws.OpCode) !void {}
            }).call,
            null,
        ),
        .drain = .init(
            null,
            (struct {
                pub fn call(_: ?*anyopaque, _: std.mem.Allocator, _: std.Io, _: *zws.WebSocket(false, true, PerSocketData)) !void {}
            }).call,
            null,
        ),
        .ping = .init(
            null,
            (struct {
                pub fn call(_: ?*anyopaque, _: std.mem.Allocator, _: std.Io, _: *zws.WebSocket(false, true, PerSocketData), _: []const u8) !void {}
            }).call,
            null,
        ),
        .pong = .init(
            null,
            (struct {
                pub fn call(_: ?*anyopaque, _: std.mem.Allocator, _: std.Io, _: *zws.WebSocket(false, true, PerSocketData), _: []const u8) !void {}
            }).call,
            null,
        ),
        .close = .init(
            null,
            (struct {
                pub fn call(_: ?*anyopaque, _: std.mem.Allocator, _: std.Io, _: *zws.WebSocket(false, true, PerSocketData), _: i32, _: []const u8) !void {}
            }).call,
            null,
        ),
    });

    _ = try app.listen(allocator, init.io, .{ .port = 9001 }, .init(
        &t2,
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
