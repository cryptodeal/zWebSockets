const env = @import("env");
const std = @import("std");
const zs = @import("zSockets");

const full_ptr = @import("http_parser.zig").full_ptr;
const AsyncSocket = @import("async_socket.zig").AsyncSocket;
const AsyncSocketData = @import("async_socket_data.zig").AsyncSocketData;
const HttpContextData = @import("http_context_data.zig").HttpContextData;
const http_error_responses = @import("http_errors.zig").http_error_responses;
const HttpRequest = @import("http_parser.zig").HttpRequest;
const HttpResponse = @import("http_response.zig").HttpResponse;
const HttpResponseData = @import("http_response_data.zig").HttpResponseData;
const HttpRouter = @import("http_router.zig").HttpRouter;
const Lambda = @import("lambda.zig").Lambda;
const Loop = @import("loop.zig").Loop;
const WebSocketData = @import("websocket_data.zig");

pub fn HttpContext(comptime ssl: bool) type {
    return struct {
        const Self = @This();

        const http_idle_timeout_s = 10;
        const http_receive_throughput_bytes = 16 * 1024;

        pub fn getLoop(self: *Self) *zs.Loop {
            return self.getSocketContext().loop;
        }

        fn getSocketContext(self: *Self) *zs.SocketContext {
            return @ptrCast(@alignCast(self));
        }

        fn getSocketContextS(s: *zs.Socket) *zs.SocketContext {
            return s.context;
        }

        pub fn getSocketContextData(self: *Self) *HttpContextData(ssl) {
            // self.getSocketContext().ext[0].print();
            return self.getSocketContext().ext[0].get(HttpContextData(ssl)).?;
        }

        fn getSocketContextDataS(s: *zs.Socket) *HttpContextData(ssl) {
            return s.context.ext[0].get(HttpContextData(ssl)).?;
        }

        fn internalInit(self: *Self) *Self {
            self.getSocketContext().setOnOpen(ssl, (struct {
                pub fn call(allocator: std.mem.Allocator, io: std.Io, s: *zs.Socket, _: bool, ip: []u8) !*zs.Socket {
                    s.setTimeout(ssl, http_idle_timeout_s);
                    s.ext[0].get(HttpResponseData(ssl)).?.* = .{
                        .async_socket_data = .{},
                        .http_parser = .{},
                    };

                    if (comptime env.remote_address_userspace) {
                        const async_socket_data: *AsyncSocketData(ssl) = &s.ext[0].get(HttpResponseData(ssl)).?.async_socket_data;
                        if (ip.len > 0 and ip.len <= 16) {
                            @memcpy(&async_socket_data.remote_address_buffer, ip);
                            async_socket_data.remote_address = async_socket_data.remote_address_buffer[0..ip.len];
                        } else {
                            async_socket_data.remote_address = &.{};
                        }
                    }

                    const http_context_data = getSocketContextDataS(s);
                    for (http_context_data.filter_handlers.items) |*f| {
                        try f.call(.{ allocator, io, @as(*HttpResponse(ssl), @ptrCast(@alignCast(s))), 1 });
                    }
                    return s;
                }
            }).call);

            self.getSocketContext().setOnClose(ssl, (struct {
                pub fn call(allocator: std.mem.Allocator, io: std.Io, s: *zs.Socket, _: i32, _: ?*anyopaque) !*zs.Socket {
                    const http_response_data: *HttpResponseData(ssl) = s.ext[0].get(HttpResponseData(ssl)).?;
                    const http_context_data = getSocketContextDataS(s);
                    for (http_context_data.filter_handlers.items) |*f| {
                        try f.call(.{ allocator, io, @as(*HttpResponse(ssl), @ptrCast(@alignCast(s))), -1 });
                    }
                    if (http_response_data.on_aborted) |*on_aborted| {
                        try on_aborted.call(.{ allocator, io });
                    }
                    http_response_data.deinit(allocator);
                    return s;
                }
            }).call);

            self.getSocketContext().setOnData(ssl, (struct {
                pub fn call(allocator: std.mem.Allocator, io: std.Io, s: *zs.Socket, data: []u8) !*zs.Socket {
                    var http_context_data = getSocketContextDataS(s);
                    if (s.isShutdown(ssl)) {
                        return s;
                    }
                    const http_response_data: *HttpResponseData(ssl) = s.ext[0].get(HttpResponseData(ssl)).?;
                    @as(*AsyncSocket(ssl), @ptrCast(@alignCast(s))).cork();
                    http_context_data.is_parsing_http = true;
                    var proxy_parser: ?*anyopaque = null;
                    if (comptime env.with_proxy) {
                        proxy_parser = &http_response_data.proxy_parser;
                    }
                    const err, var returned_socket = try http_response_data.http_parser.consumePostPadded(
                        allocator,
                        io,
                        data.ptr,
                        @intCast(data.len),
                        s,
                        proxy_parser,
                        http_context_data,
                        (struct {
                            pub fn call(
                                allocator_: std.mem.Allocator,
                                io_: std.Io,
                                http_context_data_: *HttpContextData(ssl),
                                s_: ?*anyopaque,
                                http_request: *HttpRequest,
                            ) !?*anyopaque {
                                @as(*zs.Socket, @ptrCast(@alignCast(s_))).setTimeout(ssl, 0);
                                const http_response_data_: *HttpResponseData(ssl) = @as(*zs.Socket, @ptrCast(@alignCast(s_))).ext[0].get(HttpResponseData(ssl)).?;
                                http_response_data_.offset = 0;
                                if ((http_response_data_.state & @intFromEnum(HttpResponseData(ssl).State.response_pending)) != 0) {
                                    _ = try @as(*zs.Socket, @ptrCast(@alignCast(s_))).close(allocator_, io_, ssl, 0, null);
                                    return null;
                                }
                                http_response_data_.state = @intFromEnum(HttpResponseData(ssl).State.response_pending);
                                if (http_request.isAncient() or blk: {
                                    if (http_request.getHeader("connection")) |hdr| {
                                        break :blk hdr.len == 5;
                                    } else break :blk false;
                                }) {
                                    http_response_data_.state |= @intFromEnum(HttpResponseData(ssl).State.connection_close);
                                }
                                var selected_router = &http_context_data_.router;
                                if (comptime ssl) {
                                    const domain_router = @as(*zs.Socket, @ptrCast(@alignCast(s_))).serverNameUserdata(ssl);
                                    if (domain_router) |dr| {
                                        selected_router = @ptrCast(@alignCast(dr));
                                    }
                                }
                                selected_router.getUserData().* = .{
                                    .http_response = @as(*HttpResponse(ssl), @ptrCast(@alignCast(s_))),
                                    .http_request = http_request,
                                };
                                if (!(try selected_router.route(allocator_, io_, http_request.getCaseSensitiveMethod(), http_request.getUrl()))) {
                                    _ = try @as(*zs.Socket, @ptrCast(@alignCast(s_))).close(allocator_, io_, ssl, 0, null);
                                    return null;
                                }
                                if (http_context_data_.upgraded_websocket) |_| {
                                    return null;
                                }
                                if (@as(*zs.Socket, @ptrCast(@alignCast(s_))).isClosed(ssl)) {
                                    return null;
                                }
                                if (@as(*zs.Socket, @ptrCast(@alignCast(s_))).isShutdown(ssl)) {
                                    return null;
                                }
                                if (!@as(*HttpResponse(ssl), @ptrCast(@alignCast(s_))).hasResponded() and http_response_data_.on_aborted == null) {
                                    std.debug.print("Error: Returning from a request handler without responding or attaching an abort handler is forbidden!\n\tMethod: \"{s}\"\n\tURL: \"{s}\"\n", .{ http_request.getCaseSensitiveMethod(), http_request.getUrl() });
                                    // TODO: maybe `abort`/`terminate` as done in `uWebSockets`
                                    return error.UnhandledRequest;
                                }
                                if (!@as(*HttpResponse(ssl), @ptrCast(@alignCast(s_))).hasResponded() and http_response_data_.in_stream != null) {
                                    @as(*zs.Socket, @ptrCast(@alignCast(s_))).setTimeout(ssl, http_idle_timeout_s);
                                }
                                return s_;
                            }
                        }).call,
                        http_response_data,
                        (struct {
                            pub fn call(a: std.mem.Allocator, io_: std.Io, http_response_data_: *HttpResponseData(ssl), user: ?*anyopaque, data_: []const u8, max_remaining_body_length: u64) !?*anyopaque {
                                if (http_response_data_.in_stream) |*in_stream| {
                                    if (max_remaining_body_length == 0) {
                                        @as(*zs.Socket, @ptrCast(@alignCast(user))).setTimeout(ssl, 0);
                                    } else {
                                        http_response_data_.received_bytes_per_timeout += @intCast(data_.len);
                                        if (http_response_data_.received_bytes_per_timeout >= http_receive_throughput_bytes * http_idle_timeout_s) {
                                            @as(*zs.Socket, @ptrCast(@alignCast(user))).setTimeout(ssl, http_idle_timeout_s);
                                            http_response_data_.received_bytes_per_timeout = 0;
                                        }
                                    }
                                    try in_stream.call(.{ a, io_, data_, max_remaining_body_length });
                                    if (@as(*zs.Socket, @ptrCast(@alignCast(user))).isClosed(ssl)) {
                                        return null;
                                    }
                                    if (@as(*zs.Socket, @ptrCast(@alignCast(user))).isShutdown(ssl)) {
                                        return null;
                                    }
                                    if (max_remaining_body_length == 0) {
                                        in_stream.deinit(a);
                                        http_response_data_.in_stream = null;
                                    }
                                }
                                return user;
                            }
                        }).call,
                    );

                    http_context_data.is_parsing_http = false;
                    if (returned_socket == full_ptr) {
                        _ = s.write(ssl, http_error_responses[err], false);
                        s.shutdown(ssl);
                        _ = try s.close(allocator, io, ssl, 0, null);
                        returned_socket = null;
                    }

                    if (returned_socket) |rs| {
                        _, const failed = try @as(*AsyncSocket(ssl), @ptrCast(@alignCast(rs))).uncork(allocator, null, false);
                        if (failed) {
                            @as(*AsyncSocket(ssl), @ptrCast(@alignCast(s))).timeout(http_idle_timeout_s);
                        }
                        if ((http_response_data.state & @intFromEnum(HttpResponseData(ssl).State.connection_close)) != 0) {
                            if ((http_response_data.state & @intFromEnum(HttpResponseData(ssl).State.response_pending)) == 0) {
                                if (@as(*AsyncSocket(ssl), @ptrCast(@alignCast(s))).getBufferedAmount() == 0) {
                                    @as(*AsyncSocket(ssl), @ptrCast(@alignCast(s))).shutdown();
                                    _ = try @as(*AsyncSocket(ssl), @ptrCast(@alignCast(s))).close(allocator, io);
                                }
                            }
                        }
                        return @ptrCast(@alignCast(rs));
                    }

                    if (http_context_data.upgraded_websocket) |upgraded_websocket| {
                        const async_socket = @as(*AsyncSocket(ssl), @ptrCast(@alignCast(upgraded_websocket)));
                        _, const failed = try async_socket.uncork(allocator, null, false);
                        if (!failed) {
                            // @as(*zs.Socket, @ptrCast(@alignCast(async_socket))).ext[0].print();
                            const websocket_data = @as(*zs.Socket, @ptrCast(@alignCast(async_socket))).ext[0].get(WebSocketData).?;
                            if (websocket_data.is_shutting_down) {
                                async_socket.shutdown();
                            }
                        }
                        http_context_data.upgraded_websocket = null;
                        return @ptrCast(@alignCast(async_socket));
                    }
                    _ = try @as(*AsyncSocket(ssl), @ptrCast(@alignCast(s))).uncork(allocator, null, false);
                    return s;
                }
            }).call);

            self.getSocketContext().setOnWritable(ssl, (struct {
                pub fn call(allocator: std.mem.Allocator, io: std.Io, s: *zs.Socket) !*zs.Socket {
                    const async_socket = @as(*AsyncSocket(ssl), @ptrCast(@alignCast(s)));
                    const http_response_data: *HttpResponseData(ssl) = @alignCast(@fieldParentPtr("async_socket_data", async_socket.getAsyncSocketData()));
                    if (http_response_data.on_writable) |_| {
                        s.setTimeout(ssl, 0);
                        const success = try http_response_data.callOnWritable(allocator, io);
                        if (!success) {
                            return s;
                        }
                        return s;
                    }
                    _ = try async_socket.write(allocator, &.{}, .{ .optionally = true, .next_length = 0 });

                    if ((http_response_data.state & @intFromEnum(HttpResponseData(ssl).State.connection_close)) != 0) {
                        if ((http_response_data.state & @intFromEnum(HttpResponseData(ssl).State.response_pending)) == 0) {
                            if (async_socket.getBufferedAmount() == 0) {
                                async_socket.shutdown();
                                _ = try async_socket.close(allocator, io);
                            }
                        }
                    }
                    async_socket.timeout(http_idle_timeout_s);
                    return s;
                }
            }).call);

            self.getSocketContext().setOnEnd(ssl, (struct {
                pub fn call(allocator: std.mem.Allocator, io: std.Io, s: *zs.Socket) !*zs.Socket {
                    const async_socket = @as(*AsyncSocket(ssl), @ptrCast(@alignCast(s)));
                    return async_socket.close(allocator, io);
                }
            }).call);

            self.getSocketContext().setOnTimeout(ssl, (struct {
                pub fn call(allocator: std.mem.Allocator, io: std.Io, s: *zs.Socket) !*zs.Socket {
                    const async_socket = @as(*AsyncSocket(ssl), @ptrCast(@alignCast(s)));
                    return async_socket.close(allocator, io);
                }
            }).call);

            return self;
        }

        pub fn init(allocator: std.mem.Allocator, loop: *Loop, options: zs.SocketContextOptions) !*Self {
            var http_context: *Self = @ptrCast(@alignCast(try zs.SocketContext.init(allocator, ssl, @ptrCast(@alignCast(loop)), options, &.{HttpContextData(ssl)})));
            try @as(*zs.SocketContext, @ptrCast(@alignCast(http_context))).ext[0].get(HttpContextData(ssl)).?.init(allocator);
            return http_context.internalInit();
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            var http_context_data = self.getSocketContextData();
            http_context_data.deinit(allocator);
            self.getSocketContext().deinit(allocator);
        }

        pub fn filter(self: *Self, allocator: std.mem.Allocator, filter_fn: Lambda(?*anyopaque, &.{ std.mem.Allocator, std.Io, HttpResponse(ssl), i32 }, anyerror!void)) !void {
            try self.getSocketContextData().filter_handlers.append(allocator, filter_fn);
        }

        pub fn onHttp(self: *Self, allocator: std.mem.Allocator, method: []const u8, pattern: []const u8, handler: ?Lambda(?*anyopaque, &.{ std.mem.Allocator, std.Io, *HttpResponse(ssl), *HttpRequest }, anyerror!void), upgrade: bool) !void {
            const http_context_data = self.getSocketContextData();
            var methods = [1][]const u8{method};

            const priority = if (std.mem.eql(u8, methods[0], "*")) @typeInfo(@FieldType(HttpContextData(ssl), "current_router")).pointer.child.Priority.low else (if (upgrade) @typeInfo(@FieldType(HttpContextData(ssl), "current_router")).pointer.child.Priority.high else @typeInfo(@FieldType(HttpContextData(ssl), "current_router")).pointer.child.Priority.medium);
            if (handler == null) {
                _ = try http_context_data.current_router.remove(allocator, methods[0], pattern, priority);
                return;
            }

            const Capture = struct {
                const SelfRef = @This();

                handler: Lambda(?*anyopaque, &.{ std.mem.Allocator, std.Io, *HttpResponse(ssl), *HttpRequest }, anyerror!void),
                parameter_offsets: std.StringHashMapUnmanaged(u16) = .empty,

                pub fn init(a: std.mem.Allocator, func: Lambda(?*anyopaque, &.{ std.mem.Allocator, std.Io, *HttpResponse(ssl), *HttpRequest }, anyerror!void)) !*SelfRef {
                    const res = try a.create(SelfRef);
                    res.* = .{
                        .handler = func,
                    };
                    return res;
                }

                pub fn deinit(a: std.mem.Allocator, s: ?*anyopaque) void {
                    const s_: *SelfRef = @ptrCast(@alignCast(s));
                    // TODO: verify we need to free lambda here
                    s_.handler.deinit(a);
                    var iter = s_.parameter_offsets.keyIterator();
                    while (iter.next()) |key| a.free(key.*);
                    s_.parameter_offsets.deinit(a);
                    a.destroy(s_);
                }
            };

            const capture: *Capture = try Capture.init(allocator, handler.?);
            var offset: u16 = 0;
            var i: u32 = 0;
            while (i < pattern.len) : (i += 1) {
                if (pattern[i] == ':') {
                    i += 1;
                    const start = i;
                    while (i < pattern.len and pattern[i] != '/') {
                        i += 1;
                    }
                    try capture.parameter_offsets.put(allocator, try allocator.dupe(u8, pattern[start..i]), offset);
                    offset += 1;
                }
            }

            try http_context_data.current_router.add(allocator, &methods, pattern, .init(capture, (struct {
                pub fn call(ctx: ?*anyopaque, a: std.mem.Allocator, io_: std.Io, r: *HttpRouter(HttpContextData(ssl).RouterData)) !bool {
                    const ctx_: *Capture = @ptrCast(@alignCast(ctx));
                    const user = r.getUserData();
                    user.http_request.setYield(false);
                    user.http_request.setParameters(r.getParameters());
                    user.http_request.setParameterOffsets(&ctx_.parameter_offsets);
                    if (user.http_request.getHeader("expect")) |expect| {
                        if (std.mem.eql(u8, expect, "100-continue")) {
                            _ = try user.http_response.writeContinue(a);
                        }
                    }
                    try ctx_.handler.call(.{ a, io_, user.http_response, user.http_request });
                    if (user.http_request.getYield()) {
                        return false;
                    }
                    return true;
                }
            }).call, Capture.deinit), priority);
        }

        pub fn listen(self: *Self, allocator: std.mem.Allocator, io: std.Io, host: ?[:0]const u8, port: u32, options: u32) !*zs.ListenSocket {
            return self.getSocketContext().listen(allocator, io, ssl, host, port, options, &.{HttpResponseData(ssl)});
        }

        pub fn listenUnix(self: *Self, allocator: std.mem.Allocator, io: std.Io, path: [:0]const u8, options: u32) !*zs.ListenSocket {
            return self.getSocketContext().listenUnix(allocator, io, ssl, path, options, &.{HttpResponseData(ssl)});
        }

        pub fn onPreOpen(self: *Self, handler: *const fn (std.mem.Allocator, std.Io, *zs.SocketContext, std.posix.fd_t, []u8) anyerror!std.posix.fd_t) void {
            self.getSocketContext().setOnPreOpen(ssl, handler);
        }

        pub fn adoptAcceptedSocket(self: *Self, allocator: std.mem.Allocator, io: std.Io, accepted_fd: std.posix.socket_t, ip: []u8) !*zs.Socket {
            return zs.loop.adoptAcceptedSocketNewExtensions(allocator, io, ssl, self.getSocketContext(), accepted_fd, ip, &.{HttpResponseData(ssl)});
        }
    };
}
