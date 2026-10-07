const env = @import("env");
const std = @import("std");
const utils = @import("utilities.zig");
const zs = @import("zSockets");

const AsyncSocket = @import("async_socket.zig").AsyncSocket;
const CompressOptions = @import("per_message_deflate.zig").CompressOptions;
const HttpContext = @import("http_context.zig").HttpContext;
const HttpResponseData = @import("http_response_data.zig").HttpResponseData;
const Lambda = @import("lambda.zig").Lambda;
const LoopData = @import("loop_data.zig");
const negotiateCompression = @import("websocket_extensions.zig").negotiateCompression;
const WebSocket = @import("websocket.zig").WebSocket;
const WebSocketContextData = @import("websocket_context_data.zig").WebSocketContextData;
const WebSocketData = @import("websocket_data.zig");
const WebSocketHandshake = @import("websocket_handshake.zig");

pub const http_200_ok = "200 OK";
pub const http_timeout_s = 10;

pub fn HttpResponseImpl(comptime ssl: bool) type {
    return struct {
        const Super = AsyncSocket(ssl);

        pub inline fn getHttpResponseData(self: *HttpResponse(ssl)) *HttpResponseData(ssl) {
            return @alignCast(@fieldParentPtr("async_socket_data", @as(*Super, @ptrCast(@alignCast(self))).getAsyncSocketData()));
        }

        pub inline fn writeU32Hex(allocator: std.mem.Allocator, self: *HttpResponse(ssl), value: u32) !void {
            var buf: [16]u8 = undefined;
            const length = utils.u32toaHex(value, &buf);
            _ = try @as(*Super, @ptrCast(@alignCast(self))).write(allocator, buf[0..length], .{});
        }

        pub inline fn writeU64(allocator: std.mem.Allocator, self: *HttpResponse(ssl), value: u64) !void {
            var buf: [20]u8 = undefined;
            const length = utils.u64toa(value, &buf);
            _ = try @as(*Super, @ptrCast(@alignCast(self))).write(allocator, buf[0..length], .{});
        }
    };
}

pub fn HttpResponse(comptime ssl: bool) type {
    if (env.with_proxy) {
        return struct {
            const Self = @This();

            const Super = AsyncSocket(ssl);
            const Impl = HttpResponseImpl(ssl);

            fn getHttpResponseData(self: *Self) *HttpResponseData(ssl) {
                return Impl.getHttpResponseData(self);
            }

            fn writeU32Hex(self: *Self, allocator: std.mem.Allocator, value: u32) !void {
                return Impl.writeU32Hex(allocator, self, value);
            }

            fn writeU64(self: *Self, allocator: std.mem.Allocator, value: u64) !void {
                return Impl.writeU64(allocator, self, value);
            }

            fn ensureChunkedBodyStarted(self: *Self, allocator: std.mem.Allocator) !void {
                const http_response_data = self.getHttpResponseData();
                if ((http_response_data.state & @intFromEnum(HttpResponseData(ssl).State.write_called)) == 0) {
                    try self.writeMark(allocator);
                    _ = try self.writeHeader(allocator, "Transfer-Encoding", "chunked");
                    http_response_data.state |= @intFromEnum(HttpResponseData(ssl).State.write_called);
                    _ = try @as(*Super, @ptrCast(@alignCast(self))).write(allocator, "\r\n", .{});
                }
            }

            fn writeChunk(self: *Self, allocator: std.mem.Allocator, data: []const u8) !bool {
                try self.writeU32Hex(allocator, @intCast(data.len));
                _ = try @as(*Super, @ptrCast(@alignCast(self))).write(allocator, "\r\n", .{});
                _ = try @as(*Super, @ptrCast(@alignCast(self))).write(allocator, data, .{});
                return !(try @as(*Super, @ptrCast(@alignCast(self))).write(allocator, "\r\n", .{}))[1];
            }

            fn writeMark(self: *Self, allocator: std.mem.Allocator) !void {
                _ = try self.writeHeader(allocator, "Date", @as(*zs.Socket, @ptrCast(@alignCast(self))).context.loop.ext[0].get(LoopData).?.date[0..29]);
                if (comptime !env.httpresponse_no_writemark) {
                    if (!@as(*Super, @ptrCast(@alignCast(self))).getLoopData().no_mark) {
                        _ = try self.writeHeader(allocator, "zWebSockets", "20");
                    }
                }
            }

            fn internalEnd(self: *Self, allocator: std.mem.Allocator, io: std.Io, data: []const u8, total_size: usize, optional: bool, allow_content_length: bool, close_connection: bool) !bool {
                var total_size_ = total_size;
                _ = try self.writeStatus(allocator, http_200_ok);
                if (total_size_ == 0) {
                    total_size_ = data.len;
                }
                var http_response_data = self.getHttpResponseData();
                if (close_connection) {
                    if ((http_response_data.state & @intFromEnum(HttpResponseData(ssl).State.connection_close)) == 0) {
                        _ = try self.writeHeader(allocator, "Connection", "close");
                    }
                    http_response_data.state |= @intFromEnum(HttpResponseData(ssl).State.connection_close);
                }
                if ((http_response_data.state & @intFromEnum(HttpResponseData(ssl).State.write_called)) != 0) {
                    if (data.len != 0) {
                        _ = try self.writeChunk(allocator, data);
                    }
                    _ = try @as(*Super, @ptrCast(@alignCast(self))).write(allocator, "0\r\n\r\n", .{});
                    http_response_data.markDone();
                    if (!@as(*Super, @ptrCast(@alignCast(self))).isCorked()) {
                        if ((http_response_data.state & @intFromEnum(HttpResponseData(ssl).State.connection_close)) != 0) {
                            if ((http_response_data.state & @intFromEnum(HttpResponseData(ssl).State.response_pending)) == 0) {
                                if (@as(*Super, @ptrCast(@alignCast(self))).getBufferedAmount() == 0) {
                                    @as(*Super, @ptrCast(@alignCast(self))).shutdown();
                                    _ = try @as(*Super, @ptrCast(@alignCast(self))).close(allocator, io);
                                    return true;
                                }
                            }
                        }
                    }
                    @as(*Super, @ptrCast(@alignCast(self))).timeout(http_timeout_s);
                    return true;
                } else {
                    if ((http_response_data.state & @intFromEnum(HttpResponseData(ssl).State.end_called)) == 0) {
                        _ = try self.writeMark(allocator);
                        if (allow_content_length) {
                            _ = try @as(*Super, @ptrCast(@alignCast(self))).write(allocator, "Content-Length: ", .{});
                            try self.writeU64(allocator, total_size_);
                            _ = try @as(*Super, @ptrCast(@alignCast(self))).write(allocator, "\r\n\r\n", .{});
                        } else {
                            _ = try @as(*Super, @ptrCast(@alignCast(self))).write(allocator, "\r\n", .{});
                        }
                        http_response_data.state |= @intFromEnum(HttpResponseData(ssl).State.end_called);
                    }
                    var written: usize = 0;
                    var failed = false;
                    while (written < data.len and !failed) {
                        const written_failed = try @as(*Super, @ptrCast(@alignCast(self))).write(allocator, data[written .. written + @min(data.len - written, std.math.maxInt(usize))], .{ .optionally = optional });
                        written += written_failed[0];
                        failed = written_failed[1];
                    }
                    http_response_data.offset += written;
                    const success = written == data.len and !failed;
                    if (!success or http_response_data.offset == total_size_) {
                        @as(*Super, @ptrCast(@alignCast(self))).timeout(http_timeout_s);
                    }
                    if (http_response_data.offset == total_size_ or data.len == 0) {
                        http_response_data.markDone();
                        if (!@as(*Super, @ptrCast(@alignCast(self))).isCorked()) {
                            if ((http_response_data.state & @intFromEnum(HttpResponseData(ssl).State.connection_close)) != 0) {
                                if ((http_response_data.state & @intFromEnum(HttpResponseData(ssl).State.response_pending)) == 0) {
                                    if (@as(*Super, @ptrCast(@alignCast(self))).getBufferedAmount() == 0) {
                                        @as(*Super, @ptrCast(@alignCast(self))).shutdown();
                                        _ = try @as(*Super, @ptrCast(@alignCast(self))).close(allocator, io);
                                    }
                                }
                            }
                        }
                    }
                    return success;
                }
            }

            pub fn getProxiedRemoteAddress(self: *Self) []const u8 {
                return self.getHttpResponseData().proxy_parser.getSourceAddress();
            }

            pub fn getProxiedRemoteAddressAsText(self: *Self) []const u8 {
                return @as(*Super, @ptrCast(@alignCast(self))).addressAsText(self.getProxiedRemoteAddress());
            }

            pub fn getProxiedRemotePort(self: *Self) u32 {
                return self.getHttpResponseData().proxy_parser.getSourcePort();
            }

            pub fn upgrade(
                self: *Self,
                comptime UserData: type,
                allocator: std.mem.Allocator,
                io: std.Io,
                user_data: UserData,
                sec_websocket_key: []const u8,
                sec_websocket_protocol: []const u8,
                sec_websocket_extensions: []const u8,
                websocket_context: *zs.SocketContext,
            ) !void {
                const websocket_context_data: *WebSocketContextData(ssl, UserData) = websocket_context.ext[0].get(WebSocketContextData(ssl, UserData)).?;
                var sec_websocket_accept: [28]u8 = undefined;
                WebSocketHandshake.generate(sec_websocket_key, &sec_websocket_accept);
                _ = try self.writeStatus(allocator, "101 Switching Protocols");
                _ = try self.writeHeader(allocator, "Upgrade", "websocket");
                _ = try self.writeHeader(allocator, "Connection", "Upgrade");
                _ = try self.writeHeader(allocator, "Sec-WebSocket-Accept", &sec_websocket_accept);
                if (sec_websocket_protocol.len != 0) {
                    _ = try self.writeHeader(allocator, "Sec-WebSocket-Protocol", sec_websocket_protocol[0 .. std.mem.findScalar(u8, sec_websocket_protocol, ',') orelse sec_websocket_protocol.len]);
                }
                var per_message_deflate = false;
                var compress_options: CompressOptions = .disabled;
                if (sec_websocket_extensions.len != 0 and websocket_context_data.compression != .disabled) {
                    var wanted_inflation_window: i32 = 0;
                    if (@intFromEnum(websocket_context_data.compression) & CompressOptions.decompressor_mask != @intFromEnum(CompressOptions.shared_decompressor)) {
                        wanted_inflation_window = @intFromEnum(websocket_context_data.compression) & CompressOptions.decompressor_mask >> 8;
                    }
                    const wanted_compression_window = @intFromEnum(websocket_context_data.compression) & CompressOptions.compressor_mask >> 4;
                    const neg_compression, const neg_compression_window, const neg_inflation_window, const neg_response = negotiateCompression(true, wanted_compression_window, wanted_inflation_window, sec_websocket_extensions, .{});
                    if (neg_compression) {
                        per_message_deflate = true;
                        if (neg_compression_window == 0) {
                            compress_options = .shared_compressor;
                        } else {
                            compress_options = @enumFromInt(@as(i32, @intCast(@as(u32, @intCast(neg_compression_window << 4)) | @as(u32, @intCast(neg_compression_window - 7)))));
                            if ((@intFromEnum(websocket_context_data.compression) & CompressOptions.compressor_mask) == @intFromEnum(CompressOptions.dedicated_compressor_3kb)) {
                                compress_options = .dedicated_compressor_3kb;
                            }
                        }
                        if (neg_inflation_window == 0) {
                            compress_options = @enumFromInt(@intFromEnum(compress_options) | @intFromEnum(CompressOptions.shared_decompressor));
                        } else {
                            compress_options = @enumFromInt(@intFromEnum(compress_options) | neg_inflation_window << 8);
                        }
                        _ = try self.writeHeader(allocator, "Sec-WebSocket-Extensions", neg_response);
                    }
                }

                _ = try self.internalEnd(allocator, io, &.{}, 0, false, false, false);
                const http_context: *HttpContext(ssl) = @ptrCast(@alignCast(@as(*zs.Socket, @ptrCast(@alignCast(self))).context));
                var backpressure = self.getHttpResponseData().async_socket_data.buffer.move();
                self.getHttpResponseData().deinit(allocator);
                const was_corked = @as(*Super, @ptrCast(@alignCast(self))).isCorked();
                const websocket: *WebSocket(ssl, true, UserData) = @ptrCast(@alignCast(try websocket_context.adoptSocket(allocator, ssl, @ptrCast(@alignCast(self)), &.{ WebSocketData, UserData })));
                if (was_corked) {
                    @as(*WebSocket(ssl, true, UserData).Super, @ptrCast(@alignCast(websocket))).corkUnchecked();
                }
                _ = try websocket.init(allocator, per_message_deflate, compress_options, &backpressure);
                const http_context_data = http_context.getSocketContextData();
                if (http_context_data.is_parsing_http) {
                    http_context_data.upgraded_websocket = websocket;
                }
                @as(*zs.Socket, @ptrCast(@alignCast(websocket))).setLongTimeout(ssl, websocket_context_data.max_lifetime);
                @as(*zs.Socket, @ptrCast(@alignCast(websocket))).setTimeout(ssl, websocket_context_data.idle_timeout_components[0]);
                websocket.getUserData().* = user_data;
                if (websocket_context_data.open_handler) |*open_handler| {
                    try open_handler.call(.{ allocator, websocket });
                }
            }

            pub fn close(self: *Self, allocator: std.mem.Allocator, io: std.Io) !*zs.Socket {
                return @as(*Super, @ptrCast(@alignCast(self))).close(allocator, io);
            }

            pub fn getRemoteAddress(self: *Self) []const u8 {
                return @as(*Super, @ptrCast(@alignCast(self))).getRemoteAddress();
            }

            pub fn getRemoteAddressAsText(self: *Self) []const u8 {
                return @as(*Super, @ptrCast(@alignCast(self))).getRemoteAddressAsText();
            }

            pub fn getRemotePort(self: *Self) !u32 {
                return @as(*Super, @ptrCast(@alignCast(self))).getRemotePort();
            }

            pub fn getNativeHandle(self: *Self) ?*anyopaque {
                return @as(*Super, @ptrCast(@alignCast(self))).getNativeHandle();
            }

            pub fn pause(self: *Self) *Self {
                try @as(*Super, @ptrCast(@alignCast(self))).pause();
                try @as(*Super, @ptrCast(@alignCast(self))).timeout(0);
                return self;
            }

            pub fn @"resume"(self: *Self) *Self {
                try @as(*Super, @ptrCast(@alignCast(self))).@"resume"();
                try @as(*Super, @ptrCast(@alignCast(self))).timeout(http_timeout_s);
                return self;
            }

            pub fn writeContinue(self: *Self, allocator: std.mem.Allocator) !*Self {
                _ = try @as(*Super, @ptrCast(@alignCast(self))).write(allocator, "HTTP/1.1 100 Continue\r\n\r\n", .{});
                return self;
            }

            pub fn writeStatus(self: *Self, allocator: std.mem.Allocator, status: []const u8) !*Self {
                const http_response_data = self.getHttpResponseData();
                if ((http_response_data.state & @intFromEnum(HttpResponseData(ssl).State.status_called)) != 0) {
                    return self;
                }
                http_response_data.state |= @intFromEnum(HttpResponseData(ssl).State.status_called);
                _ = try @as(*Super, @ptrCast(@alignCast(self))).write(allocator, "HTTP/1.1 ", .{});
                _ = try @as(*Super, @ptrCast(@alignCast(self))).write(allocator, status, .{});
                _ = try @as(*Super, @ptrCast(@alignCast(self))).write(allocator, "\r\n", .{});
                return self;
            }

            pub fn writeHeader(self: *Self, allocator: std.mem.Allocator, key: []const u8, value: []const u8) !*Self {
                try self.writeStatus(allocator, http_200_ok);
                _ = try @as(*Super, @ptrCast(@alignCast(self))).write(allocator, key, .{});
                _ = try @as(*Super, @ptrCast(@alignCast(self))).write(allocator, ": ", .{});
                _ = try @as(*Super, @ptrCast(@alignCast(self))).write(allocator, value, .{});
                _ = try @as(*Super, @ptrCast(@alignCast(self))).write(allocator, "\r\n", .{});
                return self;
            }

            pub fn writeHeaderU64(self: *Self, allocator: std.mem.Allocator, key: []const u8, value: u64) !*Self {
                try self.writeStatus(allocator, http_200_ok);
                _ = try @as(*Super, @ptrCast(@alignCast(self))).write(allocator, key, .{});
                _ = try @as(*Super, @ptrCast(@alignCast(self))).write(allocator, ": ", .{});
                try self.writeU64(allocator, value);
                _ = try @as(*Super, @ptrCast(@alignCast(self))).write(allocator, "\r\n", .{});
                return self;
            }

            pub fn beginWrite(self: *Self, allocator: std.mem.Allocator) !void {
                _ = try self.writeStatus(allocator, http_200_ok);
                try self.ensureChunkedBodyStarted(allocator);
            }

            pub fn endWithoutBody(self: *Self, allocator: std.mem.Allocator, io: std.Io, reported_content_length: ?usize, close_connection: bool) !void {
                if (reported_content_length) |rcl| {
                    _ = try self.internalEnd(allocator, io, &.{}, rcl, false, true, close_connection);
                } else {
                    _ = try self.internalEnd(allocator, io, &.{}, 0, false, false, close_connection);
                }
            }

            pub fn end(self: *Self, allocator: std.mem.Allocator, io: std.Io, data: []const u8, close_connection: bool) !void {
                _ = try self.internalEnd(allocator, io, data, data.len, false, true, close_connection);
            }

            pub fn tryEnd(self: *Self, allocator: std.mem.Allocator, io: std.Io, data: []const u8, total_size: usize, close_connection: bool) !@Tuple(&.{ bool, bool }) {
                const ok = try self.internalEnd(allocator, io, data, total_size, true, true, close_connection);
                return .{ ok, self.hasResponded() };
            }

            pub fn write(self: *Self, allocator: std.mem.Allocator, data: []const u8) !bool {
                _ = try self.writeStatus(allocator, http_200_ok);
                if (data.len == 0) {
                    return true;
                }
                try self.ensureChunkedBodyStarted(allocator);
                const ok = try self.writeChunk(allocator, data);
                if (!ok) {
                    @as(*Super, @ptrCast(@alignCast(self))).timeout(http_timeout_s);
                }
                return ok;
            }

            pub fn getWriteOffset(self: *Self) u128 {
                return self.getHttpResponseData().offset;
            }

            // TODO: this function is currently broken in `uWebSockets`; fix
            // pub fn maxRemainingBodyLength(self: *Self) u64 {
            //   return self.getHttpResponseData().async_socket_data.maxRemainingBodyLength();
            // }

            pub fn overrideWriteOffset(self: *Self, offset: u128) void {
                self.getHttpResponseData().offset = offset;
            }

            pub fn hasResponded(self: *Self) bool {
                const http_response_data = self.getHttpResponseData();
                return (http_response_data.state & @intFromEnum(HttpResponseData(ssl).State.response_pending)) == 0;
            }

            pub fn cork(self: *Self, allocator: std.mem.Allocator, io: std.Io, handler: Lambda(?*anyopaque, &.{ std.mem.Allocator, std.Io }, anyerror!void)) !*Self {
                if (!@as(*Super, @ptrCast(@alignCast(self))).isCorked() and @as(*Super, @ptrCast(@alignCast(self))).canCork()) {
                    const loop_data = @as(*Super, @ptrCast(@alignCast(self))).getLoopData();
                    const pre_cork_context = @as(*zs.Socket, @ptrCast(@alignCast(self))).context;
                    @as(*Super, @ptrCast(@alignCast(self))).cork();
                    handler.call(.{ allocator, io });
                    if (loop_data.corked_socket) |new_corked_socket| {
                        _, const failed = try @as(*Super, @ptrCast(@alignCast(new_corked_socket))).uncork(allocator, null, false);
                        if (@intFromPtr(self) != @intFromPtr(new_corked_socket) or @intFromPtr(@as(*zs.Socket, @ptrCast(@alignCast(new_corked_socket))).context) != @intFromPtr(pre_cork_context)) {
                            return @ptrCast(@alignCast(new_corked_socket));
                        }
                        if (failed) {
                            @as(*Super, @ptrCast(@alignCast(self))).timeout(http_timeout_s);
                        }
                        const http_response_data = self.getHttpResponseData();
                        if ((http_response_data.state & @intFromEnum(HttpResponseData(ssl).State.connection_close)) != 0) {
                            if ((http_response_data.state & @intFromEnum(HttpResponseData(ssl).State.response_pending)) == 0) {
                                if (@as(*Super, @ptrCast(@alignCast(self))).getBufferedAmount() == 0) {
                                    @as(*Super, @ptrCast(@alignCast(self))).shutdown();
                                    _ = try @as(*Super, @ptrCast(@alignCast(self))).close(allocator, io);
                                }
                            }
                        }
                    } else {
                        return self;
                    }
                } else {
                    try handler.call(.{ allocator, io });
                }
                return self;
            }

            pub fn onWritable(self: *Self, allocator: std.mem.Allocator, handler: ?Lambda(?*anyopaque, &.{ std.mem.Allocator, std.Io, u128 }, anyerror!bool)) *Self {
                const http_response_data = self.getHttpResponseData();
                if (http_response_data.on_writable) |*on_writable| {
                    on_writable.deinit(allocator);
                }
                http_response_data.on_writable = handler;
                return self;
            }

            pub fn onAborted(self: *Self, allocator: std.mem.Allocator, handler: ?Lambda(?*anyopaque, &.{ std.mem.Allocator, std.Io }, anyerror!void)) *Self {
                const http_response_data = self.getHttpResponseData();
                if (http_response_data.on_aborted) |*on_aborted| {
                    on_aborted.deinit(allocator);
                }
                http_response_data.on_aborted = handler;
                return self;
            }

            pub fn onData(self: *Self, allocator: std.mem.Allocator, handler: ?Lambda(?*anyopaque, &.{ std.mem.Allocator, std.Io, []const u8, bool }, anyerror!void)) !void {
                if (handler) |h| {
                    const InternalInStream = struct {
                        const This = @This();
                        handler: Lambda(?*anyopaque, &.{ std.mem.Allocator, std.Io, []const u8, bool }, anyerror!void),

                        pub fn init(a: std.mem.Allocator, h_: Lambda(?*anyopaque, &.{ std.mem.Allocator, std.Io, []const u8, bool }, anyerror!void)) !*This {
                            const s = try a.create(This);
                            s.handler = h_;
                            return s;
                        }

                        pub fn deinit(a: std.mem.Allocator, s_: ?*anyopaque) void {
                            const s: *This = @ptrCast(@alignCast(s_));
                            s.handler.deinit(a);
                            a.destroy(s);
                        }
                    };
                    self.onDataV2(allocator, .init(try InternalInStream.init(allocator, h), (struct {
                        pub fn call(a: std.mem.Allocator, io: std.Io, ctx: ?*anyopaque, chunk: []const u8, max_remaining_body_length: u64) !void {
                            const context: *InternalInStream = @ptrCast(@alignCast(ctx));
                            try context.handler.call(.{ a, io, chunk, max_remaining_body_length == 0 });
                        }
                    }).call, InternalInStream.deinit));
                } else {
                    self.onDataV2(allocator, null);
                }
            }

            pub fn onDataV2(self: *Self, allocator: std.mem.Allocator, handler: ?Lambda(?*anyopaque, &.{ std.mem.Allocator, std.Io, []const u8, u64 }, anyerror!void)) void {
                const data: *HttpResponseData(ssl) = self.getHttpResponseData();
                // free any existing lambda (might not be necessary)
                if (data.in_stream) |in_stream| {
                    in_stream.deinit(allocator);
                }
                data.in_stream = handler;
                data.received_bytes_per_timeout = 0;
            }
        };
    } else {
        return struct {
            const Self = @This();

            const Super = AsyncSocket(ssl);
            const Impl = HttpResponseImpl(ssl);

            fn getHttpResponseData(self: *Self) *HttpResponseData(ssl) {
                return Impl.getHttpResponseData(self);
            }

            fn writeU32Hex(self: *Self, allocator: std.mem.Allocator, value: u32) !void {
                return Impl.writeU32Hex(allocator, self, value);
            }

            fn writeU64(self: *Self, allocator: std.mem.Allocator, value: u64) !void {
                return Impl.writeU64(allocator, self, value);
            }

            fn ensureChunkedBodyStarted(self: *Self, allocator: std.mem.Allocator) !void {
                const http_response_data = self.getHttpResponseData();
                if ((http_response_data.state & @intFromEnum(HttpResponseData(ssl).State.write_called)) == 0) {
                    try self.writeMark(allocator);
                    _ = try self.writeHeader(allocator, "Transfer-Encoding", "chunked");
                    http_response_data.state |= @intFromEnum(HttpResponseData(ssl).State.write_called);
                    _ = try @as(*Super, @ptrCast(@alignCast(self))).write(allocator, "\r\n", .{});
                }
            }

            fn writeChunk(self: *Self, allocator: std.mem.Allocator, data: []const u8) !bool {
                try self.writeU32Hex(allocator, @intCast(data.len));
                _ = try @as(*Super, @ptrCast(@alignCast(self))).write(allocator, "\r\n", .{});
                _ = try @as(*Super, @ptrCast(@alignCast(self))).write(allocator, data, .{});
                return !(try @as(*Super, @ptrCast(@alignCast(self))).write(allocator, "\r\n", .{}))[1];
            }

            fn writeMark(self: *Self, allocator: std.mem.Allocator) !void {
                _ = try self.writeHeader(allocator, "Date", @as(*zs.Socket, @ptrCast(@alignCast(self))).context.loop.ext[0].get(LoopData).?.date[0..29]);
                if (comptime !env.httpresponse_no_writemark) {
                    if (!@as(*Super, @ptrCast(@alignCast(self))).getLoopData().no_mark) {
                        _ = try self.writeHeader(allocator, "zWebSockets", "20");
                    }
                }
            }

            fn internalEnd(self: *Self, allocator: std.mem.Allocator, io: std.Io, data: []const u8, total_size: usize, optional: bool, allow_content_length: bool, close_connection: bool) !bool {
                var total_size_ = total_size;
                _ = try self.writeStatus(allocator, http_200_ok);
                if (total_size_ == 0) {
                    total_size_ = data.len;
                }
                var http_response_data = self.getHttpResponseData();
                if (close_connection) {
                    if ((http_response_data.state & @intFromEnum(HttpResponseData(ssl).State.connection_close)) == 0) {
                        _ = try self.writeHeader(allocator, "Connection", "close");
                    }
                    http_response_data.state |= @intFromEnum(HttpResponseData(ssl).State.connection_close);
                }
                if ((http_response_data.state & @intFromEnum(HttpResponseData(ssl).State.write_called)) != 0) {
                    if (data.len != 0) {
                        _ = try self.writeChunk(allocator, data);
                    }
                    _ = try @as(*Super, @ptrCast(@alignCast(self))).write(allocator, "0\r\n\r\n", .{});
                    http_response_data.markDone(allocator);
                    if (!@as(*Super, @ptrCast(@alignCast(self))).isCorked()) {
                        if ((http_response_data.state & @intFromEnum(HttpResponseData(ssl).State.connection_close)) != 0) {
                            if ((http_response_data.state & @intFromEnum(HttpResponseData(ssl).State.response_pending)) == 0) {
                                if (@as(*Super, @ptrCast(@alignCast(self))).getBufferedAmount() == 0) {
                                    @as(*Super, @ptrCast(@alignCast(self))).shutdown();
                                    _ = try @as(*Super, @ptrCast(@alignCast(self))).close(allocator, io);
                                    return true;
                                }
                            }
                        }
                    }
                    @as(*Super, @ptrCast(@alignCast(self))).timeout(http_timeout_s);
                    return true;
                } else {
                    if ((http_response_data.state & @intFromEnum(HttpResponseData(ssl).State.end_called)) == 0) {
                        _ = try self.writeMark(allocator);
                        if (allow_content_length) {
                            _ = try @as(*Super, @ptrCast(@alignCast(self))).write(allocator, "Content-Length: ", .{});
                            try self.writeU64(allocator, total_size_);
                            _ = try @as(*Super, @ptrCast(@alignCast(self))).write(allocator, "\r\n\r\n", .{});
                        } else {
                            _ = try @as(*Super, @ptrCast(@alignCast(self))).write(allocator, "\r\n", .{});
                        }
                        http_response_data.state |= @intFromEnum(HttpResponseData(ssl).State.end_called);
                    }
                    var written: usize = 0;
                    var failed = false;
                    while (written < data.len and !failed) {
                        const written_failed = try @as(*Super, @ptrCast(@alignCast(self))).write(allocator, data[written .. written + @min(data.len - written, std.math.maxInt(u32))], .{ .optionally = optional });
                        written += written_failed[0];
                        failed = written_failed[1];
                    }
                    http_response_data.offset += written;
                    const success = written == data.len and !failed;
                    if (!success or http_response_data.offset == total_size_) {
                        @as(*Super, @ptrCast(@alignCast(self))).timeout(http_timeout_s);
                    }
                    if (http_response_data.offset == total_size_ or data.len == 0) {
                        http_response_data.markDone(allocator);
                        if (!@as(*Super, @ptrCast(@alignCast(self))).isCorked()) {
                            if ((http_response_data.state & @intFromEnum(HttpResponseData(ssl).State.connection_close)) != 0) {
                                if ((http_response_data.state & @intFromEnum(HttpResponseData(ssl).State.response_pending)) == 0) {
                                    if (@as(*Super, @ptrCast(@alignCast(self))).getBufferedAmount() == 0) {
                                        @as(*Super, @ptrCast(@alignCast(self))).shutdown();
                                        _ = try @as(*Super, @ptrCast(@alignCast(self))).close(allocator, io);
                                    }
                                }
                            }
                        }
                    }
                    return success;
                }
            }

            pub fn upgrade(
                self: *Self,
                comptime UserData: type,
                allocator: std.mem.Allocator,
                io: std.Io,
                user_data: UserData,
                sec_websocket_key: []const u8,
                sec_websocket_protocol: []const u8,
                sec_websocket_extensions: []const u8,
                websocket_context: *zs.SocketContext,
            ) !void {
                const websocket_context_data: *WebSocketContextData(ssl, UserData) = websocket_context.ext[0].get(WebSocketContextData(ssl, UserData)).?;
                var sec_websocket_accept: [28]u8 = undefined;
                WebSocketHandshake.generate(sec_websocket_key, &sec_websocket_accept);
                _ = try self.writeStatus(allocator, "101 Switching Protocols");
                _ = try self.writeHeader(allocator, "Upgrade", "websocket");
                _ = try self.writeHeader(allocator, "Connection", "Upgrade");
                _ = try self.writeHeader(allocator, "Sec-WebSocket-Accept", &sec_websocket_accept);
                if (sec_websocket_protocol.len != 0) {
                    _ = try self.writeHeader(allocator, "Sec-WebSocket-Protocol", sec_websocket_protocol[0 .. std.mem.findScalar(u8, sec_websocket_protocol, ',') orelse sec_websocket_protocol.len]);
                }
                var per_message_deflate = false;
                var compress_options: CompressOptions = .disabled;
                if (sec_websocket_extensions.len != 0 and websocket_context_data.compression != .disabled) {
                    var wanted_inflation_window: i32 = 0;
                    if (@intFromEnum(websocket_context_data.compression) & CompressOptions.decompressor_mask != @intFromEnum(CompressOptions.shared_decompressor)) {
                        wanted_inflation_window = @intFromEnum(websocket_context_data.compression) & CompressOptions.decompressor_mask >> 8;
                    }
                    const wanted_compression_window = @intFromEnum(websocket_context_data.compression) & CompressOptions.compressor_mask >> 4;
                    const neg_compression, const neg_compression_window, const neg_inflation_window, const neg_response = negotiateCompression(true, wanted_compression_window, wanted_inflation_window, sec_websocket_extensions, .{});
                    if (neg_compression) {
                        per_message_deflate = true;
                        if (neg_compression_window == 0) {
                            compress_options = .shared_compressor;
                        } else {
                            compress_options = @enumFromInt(@as(i32, @intCast(@as(u32, @intCast(neg_compression_window << 4)) | @as(u32, @intCast(neg_compression_window - 7)))));
                            if ((@intFromEnum(websocket_context_data.compression) & CompressOptions.compressor_mask) == @intFromEnum(CompressOptions.dedicated_compressor_3kb)) {
                                compress_options = .dedicated_compressor_3kb;
                            }
                        }
                        if (neg_inflation_window == 0) {
                            compress_options = @enumFromInt(@intFromEnum(compress_options) | @intFromEnum(CompressOptions.shared_decompressor));
                        } else {
                            compress_options = @enumFromInt(@intFromEnum(compress_options) | neg_inflation_window << 8);
                        }
                        _ = try self.writeHeader(allocator, "Sec-WebSocket-Extensions", neg_response);
                    }
                }

                _ = try self.internalEnd(allocator, io, &.{}, 0, false, false, false);
                const http_context: *HttpContext(ssl) = @ptrCast(@alignCast(@as(*zs.Socket, @ptrCast(@alignCast(self))).context));
                var backpressure = self.getHttpResponseData().async_socket_data.buffer.move();
                self.getHttpResponseData().deinit(allocator);
                const was_corked = @as(*Super, @ptrCast(@alignCast(self))).isCorked();
                const websocket: *WebSocket(ssl, true, UserData) = @ptrCast(@alignCast(try websocket_context.adoptSocket(allocator, ssl, @ptrCast(@alignCast(self)), &.{ WebSocketData, UserData })));
                if (was_corked) {
                    @as(*WebSocket(ssl, true, UserData).Super, @ptrCast(@alignCast(websocket))).corkUnchecked();
                }
                _ = try websocket.init(allocator, per_message_deflate, compress_options, &backpressure);
                const http_context_data = http_context.getSocketContextData();
                if (http_context_data.is_parsing_http) {
                    http_context_data.upgraded_websocket = websocket;
                }
                @as(*zs.Socket, @ptrCast(@alignCast(websocket))).setLongTimeout(ssl, websocket_context_data.max_lifetime);
                @as(*zs.Socket, @ptrCast(@alignCast(websocket))).setTimeout(ssl, websocket_context_data.idle_timeout_components[0]);
                websocket.getUserData().* = user_data;
                if (websocket_context_data.open_handler) |*open_handler| {
                    try open_handler.call(.{ allocator, io, websocket });
                }
            }

            pub fn close(self: *Self, allocator: std.mem.Allocator, io: std.Io) !*zs.Socket {
                return @as(*Super, @ptrCast(@alignCast(self))).close(allocator, io);
            }

            pub fn getRemoteAddress(self: *Self) []const u8 {
                return @as(*Super, @ptrCast(@alignCast(self))).getRemoteAddress();
            }

            pub fn getRemoteAddressAsText(self: *Self) []const u8 {
                return @as(*Super, @ptrCast(@alignCast(self))).getRemoteAddressAsText();
            }

            pub fn getRemotePort(self: *Self) !u32 {
                return @as(*Super, @ptrCast(@alignCast(self))).getRemotePort();
            }

            pub fn getNativeHandle(self: *Self) ?*anyopaque {
                return @as(*Super, @ptrCast(@alignCast(self))).getNativeHandle();
            }

            pub fn pause(self: *Self) *Self {
                try @as(*Super, @ptrCast(@alignCast(self))).pause();
                try @as(*Super, @ptrCast(@alignCast(self))).timeout(0);
                return self;
            }

            pub fn @"resume"(self: *Self) *Self {
                try @as(*Super, @ptrCast(@alignCast(self))).@"resume"();
                try @as(*Super, @ptrCast(@alignCast(self))).timeout(http_timeout_s);
                return self;
            }

            pub fn writeContinue(self: *Self, allocator: std.mem.Allocator) !*Self {
                _ = try @as(*Super, @ptrCast(@alignCast(self))).write(allocator, "HTTP/1.1 100 Continue\r\n\r\n", .{});
                return self;
            }

            pub fn writeStatus(self: *Self, allocator: std.mem.Allocator, status: []const u8) !*Self {
                const http_response_data = self.getHttpResponseData();
                if ((http_response_data.state & @intFromEnum(HttpResponseData(ssl).State.status_called)) != 0) {
                    return self;
                }
                http_response_data.state |= @intFromEnum(HttpResponseData(ssl).State.status_called);
                _ = try @as(*Super, @ptrCast(@alignCast(self))).write(allocator, "HTTP/1.1 ", .{});
                _ = try @as(*Super, @ptrCast(@alignCast(self))).write(allocator, status, .{});
                _ = try @as(*Super, @ptrCast(@alignCast(self))).write(allocator, "\r\n", .{});
                return self;
            }

            pub fn writeHeader(self: *Self, allocator: std.mem.Allocator, key: []const u8, value: []const u8) !*Self {
                _ = try self.writeStatus(allocator, http_200_ok);
                _ = try @as(*Super, @ptrCast(@alignCast(self))).write(allocator, key, .{});
                _ = try @as(*Super, @ptrCast(@alignCast(self))).write(allocator, ": ", .{});
                _ = try @as(*Super, @ptrCast(@alignCast(self))).write(allocator, value, .{});
                _ = try @as(*Super, @ptrCast(@alignCast(self))).write(allocator, "\r\n", .{});
                return self;
            }

            pub fn writeHeaderU64(self: *Self, allocator: std.mem.Allocator, key: []const u8, value: u64) !*Self {
                try self.writeStatus(allocator, http_200_ok);
                _ = try @as(*Super, @ptrCast(@alignCast(self))).write(allocator, key, .{});
                _ = try @as(*Super, @ptrCast(@alignCast(self))).write(allocator, ": ", .{});
                try self.writeU64(allocator, value);
                _ = try @as(*Super, @ptrCast(@alignCast(self))).write(allocator, "\r\n", .{});
                return self;
            }

            pub fn beginWrite(self: *Self, allocator: std.mem.Allocator) !void {
                _ = try self.writeStatus(allocator, http_200_ok);
                try self.ensureChunkedBodyStarted(allocator);
            }

            pub fn endWithoutBody(self: *Self, allocator: std.mem.Allocator, io: std.Io, reported_content_length: ?usize, close_connection: bool) !void {
                if (reported_content_length) |rcl| {
                    _ = try self.internalEnd(allocator, io, &.{}, rcl, false, true, close_connection);
                } else {
                    _ = try self.internalEnd(allocator, io, &.{}, 0, false, false, close_connection);
                }
            }

            pub fn end(self: *Self, allocator: std.mem.Allocator, io: std.Io, data: []const u8, close_connection: bool) !void {
                _ = try self.internalEnd(allocator, io, data, data.len, false, true, close_connection);
            }

            pub fn tryEnd(self: *Self, allocator: std.mem.Allocator, io: std.Io, data: []const u8, total_size: usize, close_connection: bool) !@Tuple(&.{ bool, bool }) {
                const ok = try self.internalEnd(allocator, io, data, total_size, true, true, close_connection);
                return .{ ok, self.hasResponded() };
            }

            pub fn write(self: *Self, allocator: std.mem.Allocator, data: []const u8) !bool {
                _ = try self.writeStatus(allocator, http_200_ok);
                if (data.len == 0) {
                    return true;
                }
                try self.ensureChunkedBodyStarted(allocator);
                const ok = try self.writeChunk(allocator, data);
                if (!ok) {
                    @as(*Super, @ptrCast(@alignCast(self))).timeout(http_timeout_s);
                }
                return ok;
            }

            pub fn getWriteOffset(self: *Self) u128 {
                return self.getHttpResponseData().offset;
            }

            // TODO: this function is currently broken in `uWebSockets`; fix
            // pub fn maxRemainingBodyLength(self: *Self) u64 {
            //   return self.getHttpResponseData().async_socket_data.maxRemainingBodyLength();
            // }

            pub fn overrideWriteOffset(self: *Self, offset: u128) void {
                self.getHttpResponseData().offset = offset;
            }

            pub fn hasResponded(self: *Self) bool {
                const http_response_data = self.getHttpResponseData();
                return (http_response_data.state & @intFromEnum(HttpResponseData(ssl).State.response_pending)) == 0;
            }

            pub fn cork(self: *Self, allocator: std.mem.Allocator, io: std.Io, handler: Lambda(?*anyopaque, &.{ std.mem.Allocator, std.Io }, anyerror!void)) !*Self {
                if (!@as(*Super, @ptrCast(@alignCast(self))).isCorked() and @as(*Super, @ptrCast(@alignCast(self))).canCork()) {
                    const loop_data = @as(*Super, @ptrCast(@alignCast(self))).getLoopData();
                    const pre_cork_context = @as(*zs.Socket, @ptrCast(@alignCast(self))).context;
                    @as(*Super, @ptrCast(@alignCast(self))).cork();
                    try handler.call(.{ allocator, io });
                    if (loop_data.corked_socket) |new_corked_socket| {
                        _, const failed = try @as(*Super, @ptrCast(@alignCast(new_corked_socket))).uncork(allocator, null, false);
                        if (@intFromPtr(self) != @intFromPtr(new_corked_socket) or @intFromPtr(@as(*zs.Socket, @ptrCast(@alignCast(new_corked_socket))).context) != @intFromPtr(pre_cork_context)) {
                            return @ptrCast(@alignCast(new_corked_socket));
                        }
                        if (failed) {
                            @as(*Super, @ptrCast(@alignCast(self))).timeout(http_timeout_s);
                        }
                        const http_response_data = self.getHttpResponseData();
                        if ((http_response_data.state & @intFromEnum(HttpResponseData(ssl).State.connection_close)) != 0) {
                            if ((http_response_data.state & @intFromEnum(HttpResponseData(ssl).State.response_pending)) == 0) {
                                if (@as(*Super, @ptrCast(@alignCast(self))).getBufferedAmount() == 0) {
                                    @as(*Super, @ptrCast(@alignCast(self))).shutdown();
                                    _ = try @as(*Super, @ptrCast(@alignCast(self))).close(allocator, io);
                                }
                            }
                        }
                    } else {
                        return self;
                    }
                } else {
                    try handler.call(.{ allocator, io });
                }
                return self;
            }

            pub fn onWritable(self: *Self, allocator: std.mem.Allocator, handler: ?Lambda(?*anyopaque, &.{ std.mem.Allocator, std.Io, u128 }, anyerror!bool)) *Self {
                const http_response_data = self.getHttpResponseData();
                if (http_response_data.on_writable) |*on_writable| {
                    on_writable.deinit(allocator);
                }
                http_response_data.on_writable = handler;
                return self;
            }

            pub fn onAborted(self: *Self, allocator: std.mem.Allocator, handler: ?Lambda(?*anyopaque, &.{ std.mem.Allocator, std.Io }, anyerror!void)) *Self {
                const http_response_data = self.getHttpResponseData();
                if (http_response_data.on_aborted) |*on_aborted| {
                    on_aborted.deinit(allocator);
                }
                http_response_data.on_aborted = handler;
                return self;
            }

            pub fn onData(self: *Self, allocator: std.mem.Allocator, handler: ?Lambda(?*anyopaque, &.{ std.mem.Allocator, std.Io, []const u8, bool }, anyerror!void)) !void {
                if (handler) |h| {
                    const InternalInStream = struct {
                        const This = @This();
                        handler: Lambda(?*anyopaque, &.{ std.mem.Allocator, std.Io, []const u8, bool }, anyerror!void),

                        pub fn init(a: std.mem.Allocator, h_: Lambda(?*anyopaque, &.{ std.mem.Allocator, std.Io, []const u8, bool }, anyerror!void)) !*This {
                            const s = try a.create(This);
                            s.handler = h_;
                            return s;
                        }

                        pub fn deinit(a: std.mem.Allocator, s_: ?*anyopaque) void {
                            const s: *This = @ptrCast(@alignCast(s_));
                            s.handler.deinit(a);
                            a.destroy(s);
                        }
                    };
                    self.onDataV2(allocator, .init(try InternalInStream.init(allocator, h), (struct {
                        pub fn call(ctx: ?*anyopaque, a: std.mem.Allocator, io: std.Io, chunk: []const u8, max_remaining_body_length: u64) !void {
                            const context: *InternalInStream = @ptrCast(@alignCast(ctx));
                            try context.handler.call(.{ a, io, chunk, max_remaining_body_length == 0 });
                        }
                    }).call, InternalInStream.deinit));
                } else {
                    self.onDataV2(allocator, null);
                }
            }

            pub fn onDataV2(self: *Self, allocator: std.mem.Allocator, handler: ?Lambda(?*anyopaque, &.{ std.mem.Allocator, std.Io, []const u8, u64 }, anyerror!void)) void {
                const data: *HttpResponseData(ssl) = self.getHttpResponseData();
                // free any existing lambda (might not be necessary)
                if (data.in_stream) |*in_stream| {
                    in_stream.deinit(allocator);
                }
                data.in_stream = handler;
                data.received_bytes_per_timeout = 0;
            }
        };
    }
}

// test helpers
const inaddr_loopback: u32 = 0x7f000001;

fn dump(s: []const u8) void {
    for (s) |c| {
        if (c == '\r') {
            std.log.err("\\r", .{});
        } else if (c == '\n') {
            std.log.err("\\n", .{});
        } else {
            std.log.err("{s}", .{&.{c}});
        }
    }
}

fn request(allocator: std.mem.Allocator, io: std.Io, port: u32, path: []const u8) ![]u8 {
    var fd = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
    defer _ = std.c.close(fd);
    std.testing.expect(!(fd < 0)) catch |e| {
        std.log.err("socket failed: {s}\n", .{std.c.gai_strerror(@enumFromInt(std.c._errno().*))});
        return e;
    };
    var addr: std.c.sockaddr.in = .{
        .family = std.c.AF.INET,
        .port = std.mem.nativeToBig(u16, @intCast(port)),
        .addr = std.mem.nativeToBig(u32, inaddr_loopback),
    };
    var connected: i32 = -1;
    for (0..50) |_| {
        connected = std.c.connect(fd, @ptrCast(@alignCast(&addr)), @sizeOf(std.c.sockaddr.in));
        if (connected == 0) break;
        _ = std.c.close(fd);
        fd = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
        try std.Io.sleep(io, .fromMicroseconds(10000), .real);
    }

    std.testing.expect(connected == 0) catch |e| {
        std.log.err("connect failed: {s}\n", .{std.c.gai_strerror(@enumFromInt(std.c._errno().*))});
        return e;
    };

    var tv: std.c.timeval = .{ .sec = 2, .usec = 0 };
    _ = std.c.setsockopt(fd, std.c.SOL.SOCKET, std.c.SO.RCVTIMEO, &tv, @sizeOf(std.c.timeval));
    var req: std.ArrayList(u8) = .empty;
    defer req.deinit(allocator);
    try req.appendSlice(allocator, "GET ");
    try req.appendSlice(allocator, path);
    try req.appendSlice(allocator, " HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n");
    std.testing.expect(std.c.send(fd, req.items.ptr, req.items.len, 0) == @as(isize, @intCast(req.items.len))) catch |e| {
        std.log.err("send failed: {s}\n", .{std.c.gai_strerror(@enumFromInt(std.c._errno().*))});
        return e;
    };
    var response: std.ArrayList(u8) = .empty;
    errdefer response.deinit(allocator);
    var buf: [2048]u8 = undefined;
    while (true) {
        const n = std.c.recv(fd, &buf, buf.len, 0);
        if (n > 0) {
            try response.appendSlice(allocator, buf[0..@intCast(n)]);
            continue;
        }
        if (n == 0) break;
        if (std.c._errno().* == @as(c_int, @intCast(@intFromEnum(std.c.E.INTR)))) continue;
        std.log.err("recv failed: {s}\n", .{std.c.gai_strerror(@enumFromInt(std.c._errno().*))});
        std.log.err("partial response: ", .{});
        dump(response.items);
        std.log.err("\n", .{});
        try std.testing.expect(false);
    }
    return response.toOwnedSlice(allocator);
}

fn requestAfterBackpressure(allocator: std.mem.Allocator, io: std.Io, port: u32, path: []const u8, written: *std.atomic.Value(bool)) ![]u8 {
    var fd = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
    defer _ = std.c.close(fd);
    std.testing.expect(!(fd < 0)) catch |e| {
        std.log.err("socket failed: {s}\n", .{std.c.gai_strerror(@enumFromInt(std.c._errno().*))});
        return e;
    };
    const rcv: i32 = 4096;
    _ = std.c.setsockopt(fd, std.c.SOL.SOCKET, std.c.SO.RCVBUF, &rcv, @sizeOf(i32));
    var addr: std.c.sockaddr.in = .{
        .family = std.c.AF.INET,
        .port = std.mem.nativeToBig(u16, @intCast(port)),
        .addr = std.mem.nativeToBig(u32, inaddr_loopback),
    };
    var connected: i32 = -1;
    for (0..50) |_| {
        connected = std.c.connect(fd, @ptrCast(@alignCast(&addr)), @sizeOf(std.c.sockaddr.in));
        if (connected == 0) break;
        _ = std.c.close(fd);
        fd = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
        _ = std.c.setsockopt(fd, std.c.SOL.SOCKET, std.c.SO.RCVBUF, &rcv, @sizeOf(i32));
        try std.Io.sleep(io, .fromMicroseconds(10000), .real);
    }
    std.testing.expect(connected == 0) catch |e| {
        std.log.err("connect failed: {s}\n", .{std.c.gai_strerror(@enumFromInt(std.c._errno().*))});
        return e;
    };
    var req: std.ArrayList(u8) = .empty;
    defer req.deinit(allocator);
    try req.appendSlice(allocator, "GET ");
    try req.appendSlice(allocator, path);
    try req.appendSlice(allocator, " HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n");
    std.testing.expect(std.c.send(fd, req.items.ptr, req.items.len, 0) == @as(isize, @intCast(req.items.len))) catch |e| {
        std.log.err("send failed: {s}\n", .{std.c.gai_strerror(@enumFromInt(std.c._errno().*))});
        return e;
    };
    var i: usize = 0;
    while (i < 500 and !written.load(.seq_cst)) : (i += 1) {
        try std.Io.sleep(io, .fromMicroseconds(10000), .real);
    }
    std.testing.expect(written.load(.seq_cst)) catch |e| {
        std.log.err("server did not finish backpressure writes\n", .{});
        return e;
    };
    var tv: std.c.timeval = .{ .sec = 10, .usec = 0 };
    _ = std.c.setsockopt(fd, std.c.SOL.SOCKET, std.c.SO.RCVTIMEO, &tv, @sizeOf(std.c.timeval));
    var response: std.ArrayList(u8) = .empty;
    errdefer response.deinit(allocator);
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = std.c.recv(fd, &buf, buf.len, 0);
        if (n > 0) {
            try response.appendSlice(allocator, buf[0..@intCast(n)]);
            continue;
        }
        if (n == 0) break;
        if (std.c._errno().* == @as(c_int, @intCast(@intFromEnum(std.c.E.INTR)))) continue;
        std.log.err("recv failed: {s}\n", .{std.c.gai_strerror(@enumFromInt(std.c._errno().*))});
        try std.testing.expect(false);
    }
    return response.toOwnedSlice(allocator);
}

fn bodyOf(response: []const u8) ![]const u8 {
    if (std.mem.find(u8, response, "\r\n\r\n")) |pos| {
        return response[pos + 4 ..];
    } else {
        std.log.err("missing header terminator in: ", .{});
        dump(response);
        std.log.err("\n", .{});
        try std.testing.expect(false);
        unreachable;
    }
}

fn decodeChunk(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < body.len) {
        if (std.mem.findPos(u8, body, i, "\r\n")) |line_end| {
            var size: usize = 0;
            for (i..line_end) |j| {
                const c = body[j];
                size <<= 4;
                if (c >= '0' and c <= '9') {
                    size += @intCast(c - '0');
                } else if (c >= 'a' and c <= 'f') {
                    size += @intCast(c - 'a' + 10);
                } else {
                    std.log.err("invalid chunk-size hex at offset {d}\n", .{j});
                    try std.testing.expect(false);
                }
            }
            i = line_end + 2;
            if (size == 0) {
                std.testing.expectEqualStrings("\r\n", body[i..]) catch |e| {
                    std.log.err("bad last-chunk trailer: ", .{});
                    dump(body[i..]);
                    std.log.err("\n", .{});
                    return e;
                };
                return out.toOwnedSlice(allocator);
            }
            std.testing.expect(i + size + 2 <= body.len) catch |e| {
                std.log.err("truncated chunk of size {d} at offset {d}\n", .{ size, i });
                return e;
            };
            std.testing.expect(body[i + size] == '\r' and body[i + size + 1] == '\n') catch |e| {
                std.log.err("missing chunk-data CRLF after {d} byte chunk (backpressure write skipped the trailer)\nnext bytes: ", .{size});
                dump(body[i + size .. i + size + 16]);
                std.log.err("\n", .{});
                return e;
            };
            try out.appendSlice(allocator, body[i .. i + size]);
            i += size + 2;
        } else {
            std.log.err("chunk-size line not terminated at offset {d}\nbody tail: ", .{i});
            dump(body[i .. i + 32]);
            std.log.err("\n", .{});
            try std.testing.expect(false);
        }
    }

    std.log.err("missing terminating 0 chunk\n", .{});
    try std.testing.expect(false);
    unreachable;
}

fn expectChunked(allocator: std.mem.Allocator, io: std.Io, port: u32, path: []const u8, expected_body: []const u8) !void {
    const response = try request(allocator, io, port, path);
    defer allocator.free(response);
    std.testing.expect(std.mem.find(u8, response, "Transfer-Encoding: chunked\r\n") != null) catch |e| {
        std.log.err("{s} missing Transfer-Encoding: chunked\n", .{path});
        dump(response);
        std.log.err("\n", .{});
        return e;
    };
    const body = try bodyOf(response);
    std.testing.expectEqualStrings(expected_body, body) catch |e| {
        std.log.err("{s} unexpected chunked body\nexpected: ", .{path});
        dump(expected_body);
        std.log.err("\nactual:   ", .{});
        dump(body);
        std.log.err("\n", .{});
        return e;
    };
}

test "Http Response" {
    const App = @import("root.zig").App;
    const HttpRequest = @import("http_parser.zig").HttpRequest;
    const Loop = @import("loop.zig").Loop;

    var app = try App.init(std.testing.allocator, std.testing.io, .{});
    defer app.deinit(std.testing.allocator, std.testing.io) catch unreachable;
    const loop = try Loop.get(std.testing.allocator, std.testing.io, null);
    var port: u32 = 0;
    var backpressure_written: std.atomic.Value(bool) = .init(false);
    const chunk_size = 64 * 1024;
    const max_fill_chunks = 512;

    _ = try app.get(std.testing.allocator, "/write-end", .init(null, (struct {
        pub fn call(_: ?*anyopaque, allocator: std.mem.Allocator, io: std.Io, res: *HttpResponse(App.Ssl), _: *HttpRequest) !void {
            _ = res.onAborted(allocator, .init(null, (struct {
                pub fn call(_: ?*anyopaque, _: std.mem.Allocator, _: std.Io) !void {}
            }).call, null));
            _ = try res.cork(allocator, io, .init(res, (struct {
                pub fn call(ctx: ?*anyopaque, allocator_: std.mem.Allocator, io_: std.Io) !void {
                    const res_: *HttpResponse(App.Ssl) = @ptrCast(@alignCast(ctx));
                    _ = try res_.writeHeader(allocator_, "Content-Type", "text/plain");
                    _ = try res_.write(allocator_, "foo");
                    _ = try res_.end(allocator_, io_, &.{}, false);
                }
            }).call, null));
        }
    }).call, null));

    _ = try app.get(std.testing.allocator, "/begin-write-end", .init(null, (struct {
        pub fn call(_: ?*anyopaque, allocator: std.mem.Allocator, io: std.Io, res: *HttpResponse(App.Ssl), _: *HttpRequest) !void {
            _ = res.onAborted(allocator, .init(null, (struct {
                pub fn call(_: ?*anyopaque, _: std.mem.Allocator, _: std.Io) !void {}
            }).call, null));
            _ = try res.cork(allocator, io, .init(res, (struct {
                pub fn call(ctx: ?*anyopaque, allocator_: std.mem.Allocator, io_: std.Io) !void {
                    const res_: *HttpResponse(App.Ssl) = @ptrCast(@alignCast(ctx));
                    _ = try res_.writeHeader(allocator_, "Content-Type", "text/plain");
                    try res_.beginWrite(allocator_);
                    _ = try res_.write(allocator_, "foo");
                    _ = try res_.end(allocator_, io_, &.{}, false);
                }
            }).call, null));
        }
    }).call, null));

    _ = try app.get(std.testing.allocator, "/begin-end", .init(null, (struct {
        pub fn call(_: ?*anyopaque, allocator: std.mem.Allocator, io: std.Io, res: *HttpResponse(App.Ssl), _: *HttpRequest) !void {
            _ = res.onAborted(allocator, .init(null, (struct {
                pub fn call(_: ?*anyopaque, _: std.mem.Allocator, _: std.Io) !void {}
            }).call, null));
            _ = try res.cork(allocator, io, .init(res, (struct {
                pub fn call(ctx: ?*anyopaque, allocator_: std.mem.Allocator, io_: std.Io) !void {
                    const res_: *HttpResponse(App.Ssl) = @ptrCast(@alignCast(ctx));
                    _ = try res_.writeHeader(allocator_, "Content-Type", "text/plain");
                    try res_.beginWrite(allocator_);
                    _ = try res_.end(allocator_, io_, &.{}, false);
                }
            }).call, null));
        }
    }).call, null));

    _ = try app.get(std.testing.allocator, "/begin-end-data", .init(null, (struct {
        pub fn call(_: ?*anyopaque, allocator: std.mem.Allocator, io: std.Io, res: *HttpResponse(App.Ssl), _: *HttpRequest) !void {
            _ = res.onAborted(allocator, .init(null, (struct {
                pub fn call(_: ?*anyopaque, _: std.mem.Allocator, _: std.Io) !void {}
            }).call, null));
            _ = try res.cork(allocator, io, .init(res, (struct {
                pub fn call(ctx: ?*anyopaque, allocator_: std.mem.Allocator, io_: std.Io) !void {
                    const res_: *HttpResponse(App.Ssl) = @ptrCast(@alignCast(ctx));
                    _ = try res_.writeHeader(allocator_, "Content-Type", "text/plain");
                    try res_.beginWrite(allocator_);
                    _ = try res_.end(allocator_, io_, "foo", false);
                }
            }).call, null));
        }
    }).call, null));

    _ = try app.get(std.testing.allocator, "/write-write-end", .init(null, (struct {
        pub fn call(_: ?*anyopaque, allocator: std.mem.Allocator, io: std.Io, res: *HttpResponse(App.Ssl), _: *HttpRequest) !void {
            _ = res.onAborted(allocator, .init(null, (struct {
                pub fn call(_: ?*anyopaque, _: std.mem.Allocator, _: std.Io) !void {}
            }).call, null));
            _ = try res.cork(allocator, io, .init(res, (struct {
                pub fn call(ctx: ?*anyopaque, allocator_: std.mem.Allocator, io_: std.Io) !void {
                    const res_: *HttpResponse(App.Ssl) = @ptrCast(@alignCast(ctx));
                    _ = try res_.writeHeader(allocator_, "Content-Type", "text/plain");
                    _ = try res_.write(allocator_, "foo");
                    _ = try res_.write(allocator_, "bar");
                    _ = try res_.end(allocator_, io_, &.{}, false);
                }
            }).call, null));
        }
    }).call, null));

    _ = try app.get(std.testing.allocator, "/begin-write-write-end", .init(null, (struct {
        pub fn call(_: ?*anyopaque, allocator: std.mem.Allocator, io: std.Io, res: *HttpResponse(App.Ssl), _: *HttpRequest) !void {
            _ = res.onAborted(allocator, .init(null, (struct {
                pub fn call(_: ?*anyopaque, _: std.mem.Allocator, _: std.Io) !void {}
            }).call, null));
            _ = try res.cork(allocator, io, .init(res, (struct {
                pub fn call(ctx: ?*anyopaque, allocator_: std.mem.Allocator, io_: std.Io) !void {
                    const res_: *HttpResponse(App.Ssl) = @ptrCast(@alignCast(ctx));
                    _ = try res_.writeHeader(allocator_, "Content-Type", "text/plain");
                    try res_.beginWrite(allocator_);
                    _ = try res_.write(allocator_, "foo");
                    _ = try res_.write(allocator_, "bar");
                    _ = try res_.end(allocator_, io_, &.{}, false);
                }
            }).call, null));
        }
    }).call, null));

    _ = try app.get(std.testing.allocator, "/write-end-data", .init(null, (struct {
        pub fn call(_: ?*anyopaque, allocator: std.mem.Allocator, io: std.Io, res: *HttpResponse(App.Ssl), _: *HttpRequest) !void {
            _ = res.onAborted(allocator, .init(null, (struct {
                pub fn call(_: ?*anyopaque, _: std.mem.Allocator, _: std.Io) !void {}
            }).call, null));
            _ = try res.cork(allocator, io, .init(res, (struct {
                pub fn call(ctx: ?*anyopaque, allocator_: std.mem.Allocator, io_: std.Io) !void {
                    const res_: *HttpResponse(App.Ssl) = @ptrCast(@alignCast(ctx));
                    _ = try res_.writeHeader(allocator_, "Content-Type", "text/plain");
                    _ = try res_.write(allocator_, "foo");
                    _ = try res_.end(allocator_, io_, "bar", false);
                }
            }).call, null));
        }
    }).call, null));

    _ = try app.get(std.testing.allocator, "/empty-write", .init(null, (struct {
        pub fn call(_: ?*anyopaque, allocator: std.mem.Allocator, io: std.Io, res: *HttpResponse(App.Ssl), _: *HttpRequest) !void {
            _ = res.onAborted(allocator, .init(null, (struct {
                pub fn call(_: ?*anyopaque, _: std.mem.Allocator, _: std.Io) !void {}
            }).call, null));
            _ = try res.cork(allocator, io, .init(res, (struct {
                pub fn call(ctx: ?*anyopaque, allocator_: std.mem.Allocator, io_: std.Io) !void {
                    const res_: *HttpResponse(App.Ssl) = @ptrCast(@alignCast(ctx));
                    _ = try res_.writeHeader(allocator_, "Content-Type", "text/plain");
                    try res_.beginWrite(allocator_);
                    _ = try res_.write(allocator_, "");
                    _ = try res_.end(allocator_, io_, &.{}, false);
                }
            }).call, null));
        }
    }).call, null));

    _ = try app.get(std.testing.allocator, "/hex-size", .init(null, (struct {
        pub fn call(_: ?*anyopaque, allocator: std.mem.Allocator, io: std.Io, res: *HttpResponse(App.Ssl), _: *HttpRequest) !void {
            _ = res.onAborted(allocator, .init(null, (struct {
                pub fn call(_: ?*anyopaque, _: std.mem.Allocator, _: std.Io) !void {}
            }).call, null));
            _ = try res.cork(allocator, io, .init(res, (struct {
                pub fn call(ctx: ?*anyopaque, allocator_: std.mem.Allocator, io_: std.Io) !void {
                    const res_: *HttpResponse(App.Ssl) = @ptrCast(@alignCast(ctx));
                    _ = try res_.writeHeader(allocator_, "Content-Type", "text/plain");
                    try res_.beginWrite(allocator_);
                    _ = try res_.write(allocator_, "hello world");
                    _ = try res_.end(allocator_, io_, &.{}, false);
                }
            }).call, null));
        }
    }).call, null));

    _ = try app.get(std.testing.allocator, "/backpressure", .init(&backpressure_written, (struct {
        pub fn call(bw_ctx: ?*anyopaque, allocator: std.mem.Allocator, io: std.Io, res: *HttpResponse(App.Ssl), _: *HttpRequest) !void {
            const bw: *std.atomic.Value(bool) = @ptrCast(@alignCast(bw_ctx));
            _ = res.onAborted(allocator, .init(null, (struct {
                pub fn call(_: ?*anyopaque, _: std.mem.Allocator, _: std.Io) !void {}
            }).call, null));
            _ = try res.cork(allocator, io, .init(res, (struct {
                pub fn call(ctx: ?*anyopaque, allocator_: std.mem.Allocator, io_: std.Io) !void {
                    const res_: *HttpResponse(App.Ssl) = @ptrCast(@alignCast(ctx));
                    _ = try res_.writeHeader(allocator_, "Content-Type", "text/plain");
                    var chunk: [chunk_size]u8 = @splat('a');
                    var filled: usize = 0;
                    while (try res_.write(allocator_, &chunk)) {
                        filled += 1;
                        std.testing.expect(filled < max_fill_chunks) catch |e| {
                            std.log.err("did not hit backpressure after {d} writes\n", .{filled});
                            return e;
                        };
                    }
                    _ = try res_.write(allocator_, "foo");
                    _ = try res_.end(allocator_, io_, &.{}, false);
                }
            }).call, null));
            bw.store(true, .seq_cst);
        }
    }).call, null));

    _ = try app.listen(
        std.testing.allocator,
        std.testing.io,
        .{ .port = 0 },
        .init(&port, (struct {
            pub fn call(ctx: ?*anyopaque, _: std.mem.Allocator, _: std.Io, listen_socket: ?*zs.ListenSocket) !void {
                if (listen_socket) |ls| {
                    const port_ctx: *u32 = @ptrCast(@alignCast(ctx));
                    port_ctx.* = try ls.s.localPort(false);
                } else {
                    std.log.err("Failed to listen\n", .{});
                    try std.testing.expect(listen_socket != null);
                }
            }
        }).call, null),
    );

    const client = try std.Thread.spawn(.{ .allocator = std.testing.allocator }, (struct {
        pub fn call(allocator: std.mem.Allocator, io: std.Io, loop_: *Loop, app_: *App, port_: u32, backpressure_written_: *std.atomic.Value(bool)) !void {
            try expectChunked(allocator, io, port_, "/write-end", "3\r\nfoo\r\n0\r\n\r\n");
            try expectChunked(allocator, io, port_, "/begin-write-end", "3\r\nfoo\r\n0\r\n\r\n");
            try expectChunked(allocator, io, port_, "/begin-end", "0\r\n\r\n");
            try expectChunked(allocator, io, port_, "/begin-end-data", "3\r\nfoo\r\n0\r\n\r\n");
            try expectChunked(allocator, io, port_, "/write-write-end", "3\r\nfoo\r\n3\r\nbar\r\n0\r\n\r\n");
            try expectChunked(allocator, io, port_, "/begin-write-write-end", "3\r\nfoo\r\n3\r\nbar\r\n0\r\n\r\n");
            try expectChunked(allocator, io, port_, "/write-end-data", "3\r\nfoo\r\n3\r\nbar\r\n0\r\n\r\n");
            try expectChunked(allocator, io, port_, "/empty-write", "0\r\n\r\n");
            try expectChunked(allocator, io, port_, "/hex-size", "b\r\nhello world\r\n0\r\n\r\n");

            const response = try requestAfterBackpressure(allocator, io, port_, "/backpressure", backpressure_written_);
            defer allocator.free(response);
            std.testing.expect(std.mem.find(u8, response, "Transfer-Encoding: chunked\r\n") != null) catch |e| {
                std.log.err("/backpressure missing Transfer-Encoding: chunked\n", .{});
                return e;
            };
            const decoded = try decodeChunk(allocator, try bodyOf(response));
            defer allocator.free(decoded);
            if (decoded.len < chunk_size + 3 or !std.mem.eql(u8, decoded[decoded.len - 3 ..], "foo")) {
                std.log.err("/backpressure decoded body should be N*'a' + \"foo\", got size {d}\n", .{decoded.len});
                try std.testing.expect(false);
            }
            var i: usize = 0;
            while (i + 3 < decoded.len) : (i += 1) {
                std.testing.expect(decoded[i] == 'a') catch |e| {
                    std.log.err("/backpressure unexpected byte at {d}\n", .{i});
                    return e;
                };
            }
            try loop_.@"defer"(allocator, io, .init(app_, (struct {
                pub fn call(ctx: ?*anyopaque, allocator_: std.mem.Allocator, io_: std.Io) !void {
                    const app_ctx: *App = @ptrCast(@alignCast(ctx));
                    _ = try app_ctx.close(allocator_, io_);
                }
            }).call, null));
        }
    }).call, .{ std.testing.allocator, std.testing.io, loop, &app, port, &backpressure_written });

    _ = try app.run(std.testing.allocator, std.testing.io);
    client.join();
}
