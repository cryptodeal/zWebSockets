const std = @import("std");
const zs = @import("zSockets");

const Lambda = @import("lambda.zig").Lambda;
const SslApp = @import("app.zig").TemplatedApp(true);
const App = @import("app.zig").TemplatedApp(false);

pub fn LocalCluster(comptime AppType: type) type {
    if (AppType != SslApp and AppType != App) @compileError("LocalCluster requires `AppType` be either `SslApp` or `App`");
    return struct {
        const Self = @This();

        pub const AppT = AppType;
        pub const ssl = AppType == SslApp;

        const DeferCtx = struct {
            const This = @This();

            fd: std.posix.fd_t,
            ip_store: []u8,
            receiving_app: *AppType,

            pub fn init(allocator: std.mem.Allocator, fd: std.posix.fd_t, ip: []const u8, receiving_app: *AppType) !*This {
                const self = try allocator.create(This);
                self.* = .{
                    .fd = fd,
                    .ip_store = try allocator.dupe(u8, ip),
                    .receiving_app = receiving_app,
                };
                return self;
            }

            pub fn deinit(allocator: std.mem.Allocator, ctx: ?*anyopaque) void {
                const self: *This = @ptrCast(@alignCast(ctx));
                allocator.free(self.ip_store);
                allocator.destroy(self);
            }

            pub fn cb(ctx: ?*anyopaque, allocator: std.mem.Allocator, io: std.Io) !void {
                const self: *This = @ptrCast(@alignCast(ctx));
                _ = try self.receiving_app.adoptSocket(allocator, io, self.fd, self.ip_store);
            }
        };

        var round_robin: usize = 0;
        var hardware_concurrency: usize = undefined;
        var threads: std.ArrayList(std.Thread) = .empty;
        var apps: std.ArrayList(*AppType) = .empty;
        var m: std.Io.Mutex = .init;

        fn onPreOpen(allocator: std.mem.Allocator, io: std.Io, _: *zs.SocketContext, fd: std.posix.fd_t, ip: []u8) !std.posix.fd_t {
            const receiving_app = apps.items[round_robin];
            try apps.items[round_robin].getLoop().@"defer"(allocator, io, .init(
                try DeferCtx.init(allocator, fd, ip, receiving_app),
                DeferCtx.cb,
                DeferCtx.deinit,
            ));
            round_robin = (round_robin + 1) % hardware_concurrency;
            return fd - 1;
        }

        fn spawn(allocator: std.mem.Allocator, io: std.Io, opts: zs.SocketContextOptions, cb: Lambda(?*anyopaque, &.{ std.mem.Allocator, std.Io, *AppType }, anyerror!void)) !void {
            try m.lock(io);
            const app = try allocator.create(AppType);
            defer allocator.destroy(app);
            app.* = try AppType.init(allocator, io, opts);
            defer app.deinit(allocator, io) catch unreachable;
            try apps.append(allocator, app);
            try cb.call(.{ allocator, io, app });
            _ = app.onPreOpen(onPreOpen);
            m.unlock(io);
            _ = try app.run(allocator, io);
            std.debug.print("Fallthrough!\n", .{});
        }

        pub fn init(allocator: std.mem.Allocator, io: std.Io, options: zs.SocketContextOptions, cb: Lambda(?*anyopaque, &.{ std.mem.Allocator, std.Io, *AppType }, anyerror!void)) !void {
            hardware_concurrency = try std.Thread.getCpuCount();
            try threads.ensureTotalCapacity(allocator, hardware_concurrency);
            threads.expandToCapacity();
            for (threads.items) |*thread| {
                thread.* = try std.Thread.spawn(.{ .allocator = allocator }, spawn, .{ allocator, io, options, cb });
            }
            for (threads.items) |thread| thread.join();
        }

        pub fn deinit(allocator: std.mem.Allocator) void {
            threads.deinit(allocator);
            apps.deinit(allocator);
        }
    };
}
