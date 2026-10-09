const std = @import("std");
const zws = @import("zWebSockets");
const zs = @import("zSockets");

const SharedPtr = @import("helpers/shared_ptr.zig").SharedPtr;

fn crc32(s: []const u8, opts: struct { crc: u32 = 0xFFFFFFFF }) u32 {
    var crc = opts.crc;
    for (0..s.len) |i| {
        var ch = s[i];
        for (0..8) |_| {
            const b = (ch ^ crc) & 1;
            crc >>= 1;
            if (b != 0) crc = crc ^ 0xEDB88320;
            ch >>= 1;
        }
    }
    return crc;
}

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

    _ = try app.post(allocator, "/*", .init(
        null,
        (struct {
            pub fn call(_: ?*anyopaque, a: std.mem.Allocator, _: std.Io, res: *zws.HttpResponse(zws.SslApp.Ssl), req: *zws.HttpRequest) !void {
                std.debug.print(" --- {s} --- \n", .{req.getUrl()});
                var hdr_iterator = req.iterator();
                while (hdr_iterator.next()) |hdr| {
                    std.debug.print("{s}: {s}\n", .{ hdr.key(), hdr.value() });
                }

                const OnDataCtx = struct {
                    const This = @This();
                    rs: *zws.HttpResponse(zws.SslApp.Ssl),
                    crc: u32,
                    is_aborted: *SharedPtr(bool),

                    pub fn create(a_: std.mem.Allocator, rs: *zws.HttpResponse(zws.SslApp.Ssl), crc: u32, is_aborted: bool) !*This {
                        const self = try a_.create(This);
                        self.* = .{
                            .rs = rs,
                            .crc = crc,
                            .is_aborted = try SharedPtr(bool).init(a_, is_aborted),
                        };
                        return self;
                    }

                    pub fn deinit(a_: std.mem.Allocator, ctx: ?*anyopaque) void {
                        const self: *This = @ptrCast(@alignCast(ctx));
                        self.is_aborted.deref(a_);
                        a_.destroy(self);
                    }
                };
                const ctx = try OnDataCtx.create(a, res, 0xFFFFFFFF, false);
                try res.onData(a, .init(
                    ctx,
                    (struct {
                        pub fn call(c: ?*anyopaque, a_: std.mem.Allocator, io_: std.Io, chunk: []const u8, is_fin: bool) !void {
                            const on_data_ctx: *OnDataCtx = @ptrCast(@alignCast(c));
                            if (chunk.len != 0) {
                                on_data_ctx.crc = crc32(chunk, .{ .crc = on_data_ctx.crc });
                            }
                            if (is_fin and !on_data_ctx.is_aborted.value) {
                                var buf: [28]u8 = undefined;
                                const s = try std.fmt.bufPrint(&buf, "{x}\n", .{~on_data_ctx.crc});
                                try on_data_ctx.rs.end(a_, io_, s, false);
                            }
                        }
                    }).call,
                    OnDataCtx.deinit,
                ));

                _ = res.onAborted(a, .init(
                    ctx.is_aborted.ref(),
                    (struct {
                        pub fn call(c: ?*anyopaque, _: std.mem.Allocator, _: std.Io) !void {
                            const shared_bool: *SharedPtr(bool) = @ptrCast(@alignCast(c));
                            shared_bool.value = true;
                        }
                    }).call,
                    (struct {
                        pub fn call(a_: std.mem.Allocator, c: ?*anyopaque) void {
                            const shared_bool: *SharedPtr(bool) = @ptrCast(@alignCast(c));
                            shared_bool.deref(a_);
                        }
                    }).call,
                ));
            }
        }).call,
        null,
    ));

    _ = try app.listen(
        allocator,
        init.io,
        .{ .port = 3000 },
        .init(
            null,
            (struct {
                pub fn call(_: ?*anyopaque, _: std.mem.Allocator, _: std.Io, ls: ?*zs.ListenSocket) !void {
                    if (ls) |_| {
                        std.debug.print("Listening on port: 3000\n", .{});
                    }
                }
            }).call,
            null,
        ),
    );

    _ = try app.run(allocator, init.io);
}
