const env = @import("env");
const loop = @import("loop.zig");
const std = @import("std");
const zs = @import("zSockets");

const AsyncSocket = @import("async_socket.zig").AsyncSocket;
const CompressOptions = @import("per_message_deflate.zig").CompressOptions;
const DeflationStream = @import("per_message_deflate.zig").DeflationStream;
const HttpCache = @import("http_cache.zig").HttpCache;
const HttpContext = @import("http_context.zig").HttpContext;
const HttpContextData = @import("http_context_data.zig").HttpContextData;
const HttpResponse = @import("http_response.zig").HttpResponse;
const HttpRequest = @import("http_parser.zig").HttpRequest;
const HttpRouter = @import("http_router.zig").HttpRouter;
const InflationStream = @import("per_message_deflate.zig").InflationStream;
const Lambda = @import("lambda.zig").Lambda;
const Loop = loop.Loop;
const LoopData = @import("loop_data.zig");
const OpCode = @import("websocket_protocol.zig").OpCode;
const PreparedMessage = @import("loop.zig").PreparedMessage;
const Subscriber = @import("topic_tree.zig").Subscriber;
const TopicTree = @import("topic_tree.zig").TopicTree;
const TopicTreeMessage = @import("websocket_context_data.zig").TopicTreeMessage;
const TopicTreeBigMessage = @import("websocket_context_data.zig").TopicTreeBigMessage;
const WebSocket = @import("websocket.zig").WebSocket;
const WebSocketContext = @import("websocket_context.zig").WebSocketContext;
const ZLibContext = @import("per_message_deflate.zig").ZlibContext;

inline fn hasBrokenCompression(maybe_user_agent: ?[]const u8) bool {
    if (maybe_user_agent) |user_agent| {
        if (std.mem.find(u8, user_agent, " Version/15.")) |idx| {
            const pos_start = idx + 15;
            if (std.mem.findScalar(u8, user_agent[pos_start..], ' ')) |pos_end| {
                const minor_version = std.fmt.parseUnsigned(u32, user_agent[pos_start..pos_end], 10) catch return false;
                if (minor_version > 3) return false;
                if (std.mem.find(u8, user_agent, " Safari/")) |_| {
                    return true;
                } else return false;
            } else return false;
        } else return false;
    } else return false;
}

pub fn TemplatedApp(comptime ssl: bool) type {
    return struct {
        const Self = @This();

        pub const Ssl = ssl;

        pub const HttpCacheResponse = HttpCache(Self).HttpCacheResponse;

        http_cache: HttpCache(Self) = .{},
        http_context: ?*HttpContext(ssl),
        websocket_context_deleters: std.ArrayList(Lambda(?*anyopaque, &.{std.mem.Allocator}, void)) = .empty,
        websocket_contexts: std.ArrayList(?*anyopaque) = .empty,
        topic_tree: ?*TopicTree(TopicTreeMessage, TopicTreeBigMessage) = null,

        pub fn addServerName(self: *Self, allocator: std.mem.Allocator, hostname_pattern: [:0]const u8, opts: zs.SocketContextOptions) !*Self {
            if (comptime ssl) {
                const domain_router = try allocator.create(HttpRouter(HttpContextData(ssl).RouterData));
                domain_router.* = try HttpRouter(HttpContextData(ssl).RouterData).init(allocator);
                try @as(*zs.SocketContext, @ptrCast(@alignCast(self.http_context))).addServerName(allocator, ssl, hostname_pattern, opts, domain_router);
            }
            // TODO: verify this behavior matches up against `uWebSockets`
            return self;
        }

        pub fn removeServerName(self: *Self, allocator: std.mem.Allocator, hostname_pattern: [:0]const u8) *Self {
            const domain_router = @as(*zs.SocketContext, @ptrCast(@alignCast(self.http_context))).findServerNameUserdata(ssl, hostname_pattern);
            if (domain_router) |dr| {
                @as(*HttpRouter(HttpContextData(ssl).RouterData), @ptrCast(@alignCast(dr))).deinit(allocator);
                allocator.destroy(@as(*HttpRouter(HttpContextData(ssl).RouterData), @ptrCast(@alignCast(dr))));
            }
            @as(*zs.SocketContext, @ptrCast(@alignCast(self.http_context))).removeServerName(allocator, ssl, hostname_pattern);
            return self;
        }

        pub fn missingServerName(self: *Self, handler: Lambda(?*anyopaque, &.{[:0]const u8}, void)) *Self {
            if (!self.constructionFailed()) {
                self.http_context.getSocketContextData().missing_server_name_handler = handler;
                @as(*zs.SocketContext, @ptrCast(@alignCast(self.http_context))).setOnServerName(ssl, (struct {
                    pub fn call(context: *zs.SocketContext, hostname: [:0]const u8) void {
                        const http_context: *HttpContext(ssl) = @ptrCast(@alignCast(context));
                        http_context.getSocketContextData().missing_server_name_handler.call(.{hostname});
                    }
                }).call);
            }
            return self;
        }

        pub fn getNativeHandle(self: *Self) ?*anyopaque {
            return @as(*zs.SocketContext, @ptrCast(@alignCast(self.http_context))).getNativeHandle(ssl);
        }

        pub fn filter(self: *Self, allocator: std.mem.Allocator, filter_handler: Lambda(?*anyopaque, &.{ HttpResponse(ssl), i32 }, void)) !*Self {
            try self.http_context.filter(allocator, filter_handler);
            return self;
        }

        pub fn publishPrepared(self: *Self, allocator: std.mem.Allocator, io: std.Io, topic: []const u8, prepared_message: PreparedMessage) !bool {
            if (self.topic_tree) |topic_tree| {
                return topic_tree.publishAnyBig(allocator, io, null, topic, prepared_message, (struct {
                    pub fn call(a: std.mem.Allocator, io_: std.Io, s: *Subscriber, m: PreparedMessage) !void {
                        const ws_: *WebSocket(ssl, true, i32) = @ptrCast(@alignCast(s.user));
                        _ = try ws_.sendPrepared(a, io_, m);
                    }
                }).call);
            } else return false;
        }

        pub fn publish(self: *Self, allocator: std.mem.Allocator, io: std.Io, topic: []const u8, message: []const u8, op_code: OpCode, compress: bool) !bool {
            if (self.topic_tree) |topic_tree| {
                if (message.len >= LoopData.cork_buffer_size) {
                    return topic_tree.publishBig(allocator, io, null, topic, .{ .message = message, .op_code = @intCast(@intFromEnum(op_code)), .compress = compress }, (struct {
                        pub fn call(a: std.mem.Allocator, io_: std.Io, s: *Subscriber, m: TopicTreeBigMessage) !void {
                            const ws_: *WebSocket(ssl, true, i32) = @ptrCast(@alignCast(s.user));
                            _ = try ws_.send(a, io_, m.message, @enumFromInt(m.op_code), @enumFromInt(@intFromBool(m.compress)), true);
                        }
                    }).call);
                } else {
                    return self.topic_tree.?.publish(allocator, io, null, topic, .{ .message = try self.topic_tree.?.dupe(message), .op_code = @intCast(@intFromEnum(op_code)), .compress = compress });
                }
            } else return false;
        }

        pub fn numSubscribers(self: *Self, topic: []const u8) u32 {
            if (self.topic_tree) |topic_tree| {
                if (topic_tree.lookupTopic(topic)) |t| {
                    return t.subscribers.count();
                }
            }
            return 0;
        }

        pub fn init(allocator: std.mem.Allocator, io: std.Io, opts: zs.SocketContextOptions) !Self {
            var self: Self = .{
                .http_context = try HttpContext(ssl).init(allocator, try Loop.get(allocator, io, null), opts),
            };
            _ = try self.any(
                allocator,
                "/*",
                .init(
                    null,
                    (struct {
                        pub fn call(_: ?*anyopaque, a: std.mem.Allocator, io_: std.Io, res: *HttpResponse(ssl), _: *HttpRequest) !void {
                            _ = try res.writeStatus(a, "404 File Not Found");
                            try res.end(a, io_, "<html><body><h1>File Not Found</h1><hr><i>uWebSockets/20 Server</i></body></html>", false);
                        }
                    }).call,
                    (struct {
                        pub fn call(_: std.mem.Allocator, _: ?*anyopaque) void {}
                    }).call,
                ),
            );
            return self;
        }

        // TODO: need to work out bugs and test to ensure all allocations are freed accordingly
        pub fn deinit(self: *Self, allocator: std.mem.Allocator, io: std.Io) !void {
            if (self.http_context) |http_context| {
                http_context.deinit(allocator);
                for (self.websocket_context_deleters.items) |*deleter| {
                    deleter.call(.{allocator});
                    deleter.deinit(allocator);
                }
            }
            self.websocket_context_deleters.deinit(allocator);
            self.websocket_contexts.deinit(allocator);
            self.http_cache.deinit(allocator);
            if (self.topic_tree) |topic_tree| {
                (try Loop.get(allocator, io, null)).removePostHandler(allocator, topic_tree);
                (try Loop.get(allocator, io, null)).removePreHandler(allocator, topic_tree);
                topic_tree.deinit(allocator);
            }
            (try Loop.get(allocator, io, null)).deinit(allocator);
        }

        pub fn constructionFailed(self: *const Self) bool {
            return self.http_context == null;
        }

        pub fn WebSocketBehavior(comptime UserData: type) type {
            return struct {
                compression: CompressOptions = .disabled,
                max_payload_length: u32 = 16 * 1024,
                idle_timeout: u16 = 120,
                max_backpressure: u32 = 64 * 1024,
                close_on_backpressure_limit: bool = false,
                reset_idle_timeout_on_send: bool = false,
                send_pings_automatically: bool = true,
                max_lifetime: u16 = 0,
                upgrade: ?Lambda(?*anyopaque, &.{ std.mem.Allocator, std.Io, *HttpResponse(ssl), *HttpRequest, *zs.SocketContext }, anyerror!void) = null,
                open: ?Lambda(?*anyopaque, &.{ std.mem.Allocator, std.Io, *WebSocket(ssl, true, UserData) }, anyerror!void) = null,
                message: ?Lambda(?*anyopaque, &.{ std.mem.Allocator, std.Io, *WebSocket(ssl, true, UserData), []const u8, OpCode }, anyerror!void) = null,
                dropped: ?Lambda(?*anyopaque, &.{ std.mem.Allocator, std.Io, *WebSocket(ssl, true, UserData), []const u8, OpCode }, anyerror!void) = null,
                drain: ?Lambda(?*anyopaque, &.{ std.mem.Allocator, std.Io, *WebSocket(ssl, true, UserData) }, anyerror!void) = null,
                ping: ?Lambda(?*anyopaque, &.{ std.mem.Allocator, std.Io, *WebSocket(ssl, true, UserData), []const u8 }, anyerror!void) = null,
                pong: ?Lambda(?*anyopaque, &.{ std.mem.Allocator, std.Io, *WebSocket(ssl, true, UserData), []const u8 }, anyerror!void) = null,
                subscription: ?Lambda(?*anyopaque, &.{ std.mem.Allocator, std.Io, *WebSocket(ssl, true, UserData), []const u8, i32, i32 }, anyerror!void) = null,
                close: ?Lambda(?*anyopaque, &.{ std.mem.Allocator, std.Io, *WebSocket(ssl, true, UserData), i32, []const u8 }, anyerror!void) = null,
            };
        }

        pub fn close(self: *Self, allocator: std.mem.Allocator, io: std.Io) !*Self {
            try @as(*zs.SocketContext, @ptrCast(@alignCast(self.http_context.?))).close(allocator, io, ssl);
            for (self.websocket_contexts.items) |websocket_context| {
                try @as(*zs.SocketContext, @ptrCast(@alignCast(websocket_context.?))).close(allocator, io, ssl);
            }
            return self;
        }

        pub fn ws(self: *Self, allocator: std.mem.Allocator, io: std.Io, comptime UserData: type, pattern: []const u8, behavior: WebSocketBehavior(UserData)) !*Self {
            var behavior_ = behavior;
            if (self.http_context) |http_context| {
                if (behavior_.idle_timeout != 0 and behavior_.idle_timeout < 8) {
                    std.debug.print("Error: idleTimeout must be either 0 or greater than 8!\n", .{});
                    return error.InvalidIdleTimeout;
                }
                if (behavior_.idle_timeout > 240 * 4) {
                    std.debug.print("Error: idleTimeout must not be greater than 960 seconds!\n", .{});
                    return error.InvalidIdleTimeout;
                }
                if (behavior_.max_lifetime > 240) {
                    std.debug.print("Error: maxLifetime must not be greater than 240 minutes!\n", .{});
                    return error.InvalidMaxLifetime;
                }
                if (self.topic_tree == null) {
                    const TopicTreeCtx = struct {
                        const This = @This();
                        needs_uncork: bool = false,

                        pub fn init(a: std.mem.Allocator) !*This {
                            const res = try a.create(This);
                            res.* = .{};
                            return res;
                        }

                        pub fn deinit(a: std.mem.Allocator, s: ?*anyopaque) void {
                            const s_: *This = @ptrCast(@alignCast(s));
                            a.destroy(s_);
                        }
                    };
                    self.topic_tree = try TopicTree(TopicTreeMessage, TopicTreeBigMessage).init(allocator, .init(
                        try TopicTreeCtx.init(allocator),
                        (struct {
                            pub fn call(c: ?*anyopaque, a: std.mem.Allocator, io_: std.Io, s: *Subscriber, message: *TopicTreeMessage, flags: TopicTree(TopicTreeMessage, TopicTreeBigMessage).IteratorFlags) !bool {
                                const ctx: *TopicTreeCtx = @ptrCast(@alignCast(c));
                                const ws_: *WebSocket(ssl, true, UserData) = @ptrCast(@alignCast(s.user));
                                if ((@intFromEnum(flags) & @intFromEnum(TopicTree(TopicTreeMessage, TopicTreeBigMessage).IteratorFlags.first)) != 0) {
                                    if (ws_.canCork() and !ws_.isCorked()) {
                                        @as(*AsyncSocket(ssl), @ptrCast(@alignCast(ws_))).cork();
                                        ctx.needs_uncork = true;
                                    }
                                }
                                if (WebSocket(ssl, true, UserData).SendStatus.dropped == try ws_.send(a, io_, message.message, @enumFromInt(message.op_code), @enumFromInt(@intFromBool(message.compress)), true)) {
                                    if (ctx.needs_uncork) {
                                        _ = try @as(*AsyncSocket(ssl), @ptrCast(@alignCast(ws_))).uncork(a, null, false);
                                        ctx.needs_uncork = false;
                                    }
                                    return true;
                                }
                                if ((@intFromEnum(flags) & @intFromEnum(TopicTree(TopicTreeMessage, TopicTreeBigMessage).IteratorFlags.last)) != 0) {
                                    if (ctx.needs_uncork) {
                                        _ = try @as(*AsyncSocket(ssl), @ptrCast(@alignCast(ws_))).uncork(a, null, false);
                                    }
                                }
                                return false;
                            }
                        }).call,
                        TopicTreeCtx.deinit,
                    ));
                    try (try Loop.get(allocator, io, null)).addPostHandler(allocator, self.topic_tree, .init(
                        self.topic_tree,
                        (struct {
                            pub fn call(ctx: ?*anyopaque, a: std.mem.Allocator, io_: std.Io, _: *Loop) !void {
                                var t: *TopicTree(TopicTreeMessage, TopicTreeBigMessage) = @ptrCast(@alignCast(ctx));
                                try t.drain(a, io_);
                            }
                        }).call,
                        null,
                    ));
                    try (try Loop.get(allocator, io, null)).addPreHandler(allocator, self.topic_tree, .init(
                        self.topic_tree,
                        (struct {
                            pub fn call(ctx: ?*anyopaque, a: std.mem.Allocator, io_: std.Io, _: *Loop) !void {
                                var t: *TopicTree(TopicTreeMessage, TopicTreeBigMessage) = @ptrCast(@alignCast(ctx));
                                try t.drain(a, io_);
                            }
                        }).call,
                        null,
                    ));
                }
                const websocket_context = try WebSocketContext(ssl, true, UserData).init(allocator, try Loop.get(allocator, io, null), @ptrCast(@alignCast(http_context)), self.topic_tree.?);
                try self.websocket_context_deleters.append(allocator, .init(
                    websocket_context,
                    (struct {
                        pub fn call(c: ?*anyopaque, a: std.mem.Allocator) void {
                            @as(*WebSocketContext(ssl, true, UserData), @ptrCast(@alignCast(c))).deinit(a);
                        }
                    }).call,
                    null,
                ));
                try self.websocket_contexts.append(allocator, websocket_context);
                if (!env.with_zlib) {
                    behavior_.compression = .disabled;
                }
                if (behavior_.compression != .disabled) {
                    const loop_data: *LoopData = websocket_context.getSocketContext().loop.ext[0].get(LoopData).?;
                    if (loop_data.zlib_context == null) {
                        loop_data.zlib_context = try ZLibContext.init(allocator);
                        loop_data.inflation_stream = try InflationStream.init(allocator, @enumFromInt(CompressOptions.dedicated_decompressor));
                        loop_data.deflation_stream = try DeflationStream.init(allocator, @enumFromInt(CompressOptions.dedicated_compressor));
                    }
                }
                websocket_context.getExt().open_handler = behavior_.open;
                websocket_context.getExt().message_handler = behavior_.message;
                websocket_context.getExt().dropped_handler = behavior_.dropped;
                websocket_context.getExt().drain_handler = behavior_.drain;
                websocket_context.getExt().subscription_handler = behavior_.subscription;
                websocket_context.getExt().close_handler = behavior_.close;
                websocket_context.getExt().ping_handler = behavior_.ping;
                websocket_context.getExt().pong_handler = behavior_.pong;
                websocket_context.getExt().max_payload_length = behavior_.max_payload_length;
                websocket_context.getExt().max_backpressure = behavior_.max_backpressure;
                websocket_context.getExt().close_on_backpressure_limit = behavior_.close_on_backpressure_limit;
                websocket_context.getExt().reset_idle_timeout_on_send = behavior_.reset_idle_timeout_on_send;
                websocket_context.getExt().send_pings_automatically = behavior_.send_pings_automatically;
                websocket_context.getExt().max_lifetime = behavior_.max_lifetime;
                websocket_context.getExt().compression = behavior_.compression;
                websocket_context.getExt().calculateIdleTimeoutComponents(behavior_.idle_timeout);
                const GetCtx = struct {
                    const This = @This();
                    websocket_ctx: *WebSocketContext(ssl, true, UserData),
                    behavior: WebSocketBehavior(UserData),

                    pub fn init(a: std.mem.Allocator, ws_ctx: *WebSocketContext(ssl, true, UserData), bhvr: WebSocketBehavior(UserData)) !*This {
                        const res = try a.create(This);
                        res.* = .{ .websocket_ctx = ws_ctx, .behavior = bhvr };
                        return res;
                    }

                    pub fn deinit(a: std.mem.Allocator, s: ?*anyopaque) void {
                        const res: *This = @ptrCast(@alignCast(s));
                        a.destroy(res);
                    }
                };
                try http_context.onHttp(
                    allocator,
                    "GET",
                    pattern,
                    .init(
                        try GetCtx.init(allocator, websocket_context, behavior_),
                        (struct {
                            pub fn call(c: ?*anyopaque, a: std.mem.Allocator, io_: std.Io, res: *HttpResponse(ssl), req: *HttpRequest) !void {
                                const ctx: *GetCtx = @ptrCast(@alignCast(c));
                                const sec_websocket_key = req.getHeader("sec-websocket-key");
                                if (sec_websocket_key != null and sec_websocket_key.?.len == 24) {
                                    if (ctx.behavior.upgrade) |*upgrade| {
                                        if (hasBrokenCompression(req.getHeader("user-agent"))) {
                                            // TODO: might need to modify so this isn't returned as `const`
                                            const sec_websocket_extensions = req.getHeader("sec-websocket-extensions").?;
                                            @memset(@constCast(sec_websocket_extensions.ptr)[0..sec_websocket_extensions.len], ' ');
                                        }
                                        try upgrade.call(.{ a, io_, res, req, @as(*zs.SocketContext, @ptrCast(@alignCast(ctx.websocket_ctx))) });
                                    } else {
                                        const sec_websocket_protocol = req.getHeader("sec-websocket-protocol") orelse &.{};
                                        var sec_websocket_extensions = req.getHeader("sec-websocket-extensions") orelse &.{};
                                        if (hasBrokenCompression(req.getHeader("user-agent"))) {
                                            sec_websocket_extensions = "";
                                        }
                                        try res.upgrade(UserData, a, io_, blk: {
                                            var value: UserData = undefined;
                                            inline for (std.meta.fields(UserData)) |field| {
                                                @field(value, field.name) = undefined;
                                            }
                                            break :blk value;
                                        }, sec_websocket_key.?, sec_websocket_protocol, sec_websocket_extensions, @as(*zs.SocketContext, @ptrCast(@alignCast(ctx.websocket_ctx))));
                                    }
                                } else {
                                    req.setYield(true);
                                }
                            }
                        }).call,
                        GetCtx.deinit,
                    ),
                    true,
                );
            }
            return self;
        }

        pub fn domain(self: *Self, server_name: [:0]const u8) *Self {
            const http_context_data: *HttpContextData(ssl) = self.http_context.?.getSocketContextData();
            if (@as(*zs.SocketContext, @ptrCast(@alignCast(self.http_context))).findServerNameUserdata(ssl, server_name)) |domain_router| {
                std.debug.print("Browsed to SNI: {s}\n", .{server_name});
                http_context_data.current_router = @ptrCast(@alignCast(domain_router));
            } else {
                std.debug.print("Cannot browse to SNI: {s}\n", .{server_name});
                http_context_data.current_router = &http_context_data.router;
            }
            return self;
        }

        pub fn get(self: *Self, allocator: std.mem.Allocator, pattern: []const u8, handler: Lambda(?*anyopaque, &.{ std.mem.Allocator, std.Io, *HttpResponse(ssl), *HttpRequest }, anyerror!void)) !*Self {
            if (self.http_context) |http_context| {
                try http_context.onHttp(allocator, "GET", pattern, handler, false);
            }
            return self;
        }

        pub fn post(self: *Self, allocator: std.mem.Allocator, pattern: []const u8, handler: Lambda(?*anyopaque, &.{ std.mem.Allocator, std.Io, *HttpResponse(ssl), *HttpRequest }, anyerror!void)) !*Self {
            if (self.http_context) |http_context| {
                try http_context.onHttp(allocator, "POST", pattern, handler, false);
            }
            return self;
        }

        pub fn options(self: *Self, allocator: std.mem.Allocator, pattern: []u8, handler: Lambda(?*anyopaque, &.{ std.mem.Allocator, std.Io, *HttpResponse(ssl), *HttpRequest }, anyerror!void)) !*Self {
            if (self.http_context) |http_context| {
                try http_context.onHttp(allocator, "OPTIONS", pattern, handler, false);
            }
            return self;
        }

        pub fn del(self: *Self, allocator: std.mem.Allocator, pattern: []u8, handler: Lambda(?*anyopaque, &.{ std.mem.Allocator, std.Io, *HttpResponse(ssl), *HttpRequest }, anyerror!void)) !*Self {
            if (self.http_context) |http_context| {
                try http_context.onHttp(allocator, "DELETE", pattern, handler, false);
            }
            return self;
        }

        pub fn patch(self: *Self, allocator: std.mem.Allocator, pattern: []u8, handler: Lambda(?*anyopaque, &.{ std.mem.Allocator, std.Io, *HttpResponse(ssl), *HttpRequest }, anyerror!void)) !*Self {
            if (self.http_context) |http_context| {
                try http_context.onHttp(allocator, "PATCH", pattern, handler, false);
            }
            return self;
        }

        pub fn put(self: *Self, allocator: std.mem.Allocator, pattern: []u8, handler: Lambda(?*anyopaque, &.{ std.mem.Allocator, std.Io, *HttpResponse(ssl), *HttpRequest }, anyerror!void)) !*Self {
            if (self.http_context) |http_context| {
                try http_context.onHttp(allocator, "PUT", pattern, handler, false);
            }
            return self;
        }

        pub fn head(self: *Self, allocator: std.mem.Allocator, pattern: []u8, handler: Lambda(?*anyopaque, &.{ std.mem.Allocator, std.Io, *HttpResponse(ssl), *HttpRequest }, anyerror!void)) !*Self {
            if (self.http_context) |http_context| {
                try http_context.onHttp(allocator, "HEAD", pattern, handler, false);
            }
            return self;
        }

        pub fn connect(self: *Self, allocator: std.mem.Allocator, pattern: []u8, handler: Lambda(?*anyopaque, &.{ std.mem.Allocator, std.Io, *HttpResponse(ssl), *HttpRequest }, anyerror!void)) !*Self {
            if (self.http_context) |http_context| {
                try http_context.onHttp(allocator, "CONNECT", pattern, handler, false);
            }
            return self;
        }

        pub fn trace(self: *Self, allocator: std.mem.Allocator, pattern: []u8, handler: Lambda(?*anyopaque, &.{ std.mem.Allocator, std.Io, *HttpResponse(ssl), *HttpRequest }, anyerror!void)) !*Self {
            if (self.http_context) |http_context| {
                try http_context.onHttp(allocator, "TRACE", pattern, handler, false);
            }
            return self;
        }

        pub fn any(self: *Self, allocator: std.mem.Allocator, pattern: []const u8, handler: Lambda(?*anyopaque, &.{ std.mem.Allocator, std.Io, *HttpResponse(ssl), *HttpRequest }, anyerror!void)) !*Self {
            if (self.http_context) |http_context| {
                try http_context.onHttp(allocator, "*", pattern, handler, false);
            }
            return self;
        }

        pub fn listen(
            self: *Self,
            allocator: std.mem.Allocator,
            io: std.Io,
            args: struct {
                host: ?[:0]const u8 = null,
                port: ?u32 = null,
                options: u32 = 0,
                path: ?[:0]const u8 = null,
            },
            handler: Lambda(?*anyopaque, &.{ std.mem.Allocator, std.Io, ?*zs.ListenSocket }, anyerror!void),
        ) !*Self {
            if (args.host != null and args.port != null) {
                if (args.host.?.len == 0) {
                    return self.listen(allocator, io, .{ .port = args.port }, handler);
                }
                try handler.call(.{ allocator, io, if (self.http_context) |http_context| try http_context.listen(allocator, io, args.host.?, args.port.?, args.options) else null });
                return self;
            } else if (args.port) |port| {
                try handler.call(.{ allocator, io, if (self.http_context) |http_context| try http_context.listen(allocator, io, null, port, args.options) else null });
                return self;
            } else if (args.path) |path| {
                try handler.call(.{ allocator, io, if (self.http_context) |http_context| try http_context.listenUnix(allocator, io, path, args.options) else null });
                return self;
            } else {
                return error.InvalidArguments;
            }
        }

        pub fn onPreOpen(self: *Self, handler: *const fn (std.mem.Allocator, std.Io, *zs.SocketContext, std.posix.fd_t, []u8) anyerror!std.posix.fd_t) *Self {
            self.http_context.?.onPreOpen(handler);
            return self;
        }

        pub fn removeChildApp(self: *Self, allocator: std.mem.Allocator, io: std.Io, app: *Self) !*Self {
            var child_apps = &self.http_context.?.getSocketContextData().child_apps;
            if (std.mem.findScalar(?*anyopaque, child_apps.items, app)) |idx| {
                const child_app: *Self = @ptrCast(@alignCast(child_apps.orderedRemove(idx)));
                try child_app.deinit(allocator, io);
            }
            self.http_context.?.getSocketContextData().round_robin = 0;
            return self;
        }

        pub fn addChildApp(self: *Self, allocator: std.mem.Allocator, app: *Self) !*Self {
            try self.http_context.?.getSocketContextData().child_apps.append(allocator, app);
            self.http_context.?.onPreOpen((struct {
                pub fn call(_: std.mem.Allocator, context: *zs.SocketContext, fd: std.posix.fd_t, ip: []u8) !std.posix.fd_t {
                    var http_context: *HttpContext(ssl) = @ptrCast(@alignCast(context));
                    if (http_context.getSocketContextData().child_apps.items.len == 0) {
                        return fd;
                    }
                    const round_robin = &http_context.getSocketContextData().round_robin;
                    const receiving_app: *Self = @ptrCast(@alignCast(http_context.getSocketContextData().child_apps.items[round_robin.*]));
                    const DeferCtx = struct {
                        const This = @This();
                        handle: std.posix.fd_t,
                        ip_store: []const u8,
                        rapp: *Self,
                        pub fn init(a_: std.mem.Allocator, handle: std.posix.fd_t, ip_store: []const u8, rapp: *Self) !*This {
                            const res = try a_.create(This);
                            res.* = .{
                                .handle = handle,
                                .ip_store = ip_store,
                                .rapp = rapp,
                            };
                            return res;
                        }

                        pub fn deinit(a_: std.mem.Allocator, s: ?*anyopaque) void {
                            const res: *This = @ptrCast(@alignCast(s));
                            a_.destroy(res);
                        }
                    };
                    try receiving_app.getLoop().@"defer"(allocator, .init(
                        try DeferCtx.init(allocator, fd, ip),
                        (struct {
                            pub fn call(c: ?*anyopaque, a_: std.mem.Allocator) !void {
                                const ctx: *DeferCtx = @ptrCast(@alignCast(c));
                                _ = try ctx.rapp.adoptSocket(a_, ctx.handle, ctx.ip_store);
                            }
                        }).call,
                        DeferCtx.deinit,
                    ));
                    round_robin.* += 1;
                    if (@as(usize, @intCast(round_robin.*)) == http_context.getSocketContextData().child_apps.items.len) {
                        round_robin.* = 0;
                    }
                    return fd + 1;
                }
            }).call);
            return self;
        }

        pub fn adoptSocket(self: *Self, allocator: std.mem.Allocator, io: std.Io, accepted_fd: std.posix.socket_t, ip: []u8) !*Self {
            _ = try self.http_context.?.adoptAcceptedSocket(allocator, io, accepted_fd, ip);
            return self;
        }

        pub fn run(self: *Self, allocator: std.mem.Allocator, io: std.Io) !*Self {
            try loop.run(allocator, io);
            return self;
        }

        pub fn getLoop(self: *Self) *Loop {
            return @ptrCast(@alignCast(self.http_context.?.getLoop()));
        }
    };
}
