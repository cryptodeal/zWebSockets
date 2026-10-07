const std = @import("std");
const zs = @import("zSockets");

const AsyncSocket = @import("async_socket.zig").AsyncSocket;
const BackPressure = @import("async_socket_data.zig").BackPressure;
const CompressOptions = @import("per_message_deflate.zig").CompressOptions;
const Lambda = @import("lambda.zig").Lambda;
const LoopData = @import("loop_data.zig");
const OpCode = @import("websocket_protocol.zig").OpCode;
const PreparedMessage = @import("loop.zig").PreparedMessage;
const Protocol = @import("websocket_protocol.zig").Protocol;
const Subscriber = @import("topic_tree.zig").Subscriber;
const TopicTreeBigMessage = @import("websocket_context_data.zig").TopicTreeBigMessage;
const WebSocketContextData = @import("websocket_context_data.zig").WebSocketContextData;
const WebSocketData = @import("websocket_data.zig");

pub const CompressFlags = enum(i32) {
    no_action,
    compress,
    already_compressed,
};

pub fn WebSocket(comptime ssl: bool, comptime is_server: bool, comptime UserData: type) type {
    return struct {
        const Self = @This();

        pub const Super = AsyncSocket(ssl);

        pub fn init(self: *Self, allocator: std.mem.Allocator, per_message_deflate: bool, compress_options: CompressOptions, backpressure: *BackPressure) !*Self {
            @as(*zs.Socket, @ptrCast(@alignCast(self))).ext[0].get(WebSocketData).?.* = try WebSocketData.init(allocator, per_message_deflate, compress_options, backpressure);
            return self;
        }

        pub fn getUserData(self: *Self) *UserData {
            return @as(*zs.Socket, @ptrCast(@alignCast(self))).ext[1].get(UserData).?;
        }

        pub fn getBufferedAmount(self: *Self) usize {
            return @as(*Super, @ptrCast(@alignCast(self))).getBufferedAmount();
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

        pub fn close(self: *Self, allocator: std.mem.Allocator) !?*zs.Socket {
            if (@as(*zs.Socket, @ptrCast(@alignCast(self))).isClosed(ssl)) {
                return null;
            }
            const websocket_data = @as(*zs.Socket, @ptrCast(@alignCast(self))).ext[0].get(WebSocketData).?;
            if (websocket_data.is_shutting_down) {
                return null;
            }
            return @as(*zs.Socket, @ptrCast(@alignCast(self))).close(allocator, ssl, 0, null);
        }

        pub const SendStatus = enum(i32) {
            backpressure,
            success,
            dropped,
        };

        // TODO: verify we handle `compress` as enum correctly for various `send` methods
        pub fn sendFirstFragment(self: *Self, allocator: std.mem.Allocator, message: []const u8, op_code: OpCode, compress: bool) !SendStatus {
            return self.send(allocator, message, op_code, if (compress) .compress else .no_action, false);
        }

        pub fn sendFragment(self: *Self, allocator: std.mem.Allocator, message: []const u8, compress: bool) !SendStatus {
            return self.send(allocator, message, .continuation, if (compress) .compress else .no_action, false);
        }

        pub fn sendLastFragment(self: *Self, allocator: std.mem.Allocator, message: []const u8, compress: bool) !SendStatus {
            return self.send(allocator, message, .continuation, if (compress) .compress else .no_action, true);
        }

        pub fn hasNegotiatedCompression(self: *Self) bool {
            const websocket_data = @as(*zs.Socket, @ptrCast(@alignCast(self))).ext[0].get(WebSocketData).?;
            return websocket_data.compression_status == .enabled;
        }

        pub fn sendPrepared(self: *Self, allocator: std.mem.Allocator, io: std.Io, prepared_message: PreparedMessage) !SendStatus {
            if (prepared_message.compressed and self.hasNegotiatedCompression() and prepared_message.compressed_message.len < prepared_message.original_message.len) {
                return self.send(allocator, io, prepared_message.compressed_message, @enumFromInt(prepared_message.op_code), .already_compressed, true);
            }
            return self.send(allocator, io, prepared_message.original_message, @enumFromInt(prepared_message.op_code), .no_action, true);
        }

        pub fn send(self: *Self, allocator: std.mem.Allocator, io: std.Io, message: []const u8, op_code: OpCode, compress: CompressFlags, fin: bool) !SendStatus {
            var message_ = message;
            var compress_ = compress;
            const websocket_context_data = @as(*zs.Socket, @ptrCast(@alignCast(self))).context.ext[0].get(WebSocketContextData(ssl, UserData)).?;
            if (websocket_context_data.max_backpressure != 0 and websocket_context_data.max_backpressure < self.getBufferedAmount()) {
                if (websocket_context_data.close_on_backpressure_limit) {
                    @as(*zs.Socket, @ptrCast(@alignCast(self))).shutdownRead(ssl);
                }
                if (websocket_context_data.dropped_handler) |dropped_handler| {
                    try dropped_handler.call(.{ allocator, io, self, message_, op_code });
                }
                return .dropped;
            }
            var websocket_data: *WebSocketData = @as(*zs.Socket, @ptrCast(@alignCast(self))).ext[0].get(WebSocketData).?;
            if (message_.len >= 16 * 1024 and compress_ == .no_action and !ssl and websocket_data.subscriber == null and self.getBufferedAmount() == 0 and @as(*Super, @ptrCast(@alignCast(self))).getLoopData().cork_offset == 0) {
                var header: [10]u8 = undefined;
                const header_len = Protocol.formatMessage(is_server, &header, "", op_code, message_.len, compress_ != .no_action, fin);
                const written = @as(*zs.Socket, @ptrCast(@alignCast(self))).write2(false, header[0..header_len], message_);
                if (written != header_len + message_.len) {
                    if (written > header_len) {
                        try websocket_data.async_socket_data.buffer.append(allocator, message_[written - header_len ..]);
                    } else {
                        try websocket_data.async_socket_data.buffer.append(allocator, header[written..]);
                        try websocket_data.async_socket_data.buffer.append(allocator, message_);
                    }
                    @as(*Super, @ptrCast(@alignCast(self))).uncorkWithoutSending();
                    return .backpressure;
                }
            } else {
                if (websocket_data.subscriber) |subscriber| {
                    try websocket_context_data.topic_tree.drainSubscriber(allocator, io, subscriber);
                }
                if (compress_ != .no_action) {
                    websocket_data = @as(*zs.Socket, @ptrCast(@alignCast(self))).ext[0].get(WebSocketData).?;
                    if (message_.len != 0 and @intFromEnum(op_code) < 3 and websocket_data.compression_status == .enabled) {
                        if (compress_ != .already_compressed) {
                            const loop_data = @as(*Super, @ptrCast(@alignCast(self))).getLoopData();
                            if (websocket_data.deflation_stream) |deflation_stream| {
                                message_ = try deflation_stream.deflate(allocator, loop_data.zlib_context.?, message_, false);
                            } else {
                                message_ = try loop_data.deflation_stream.?.deflate(allocator, loop_data.zlib_context.?, message_, true);
                            }
                        }
                    } else {
                        compress_ = .no_action;
                    }
                }
                const message_frame_size = Protocol.messageFrameSize(message_.len);
                const send_buffer, const send_buffer_attribute = try @as(*Super, @ptrCast(@alignCast(self))).getSendBuffer(allocator, message_frame_size);
                _ = Protocol.formatMessage(is_server, send_buffer, message_, op_code, message_.len, compress_ != .no_action, fin);
                if (send_buffer_attribute == .needs_drain) {
                    _, const failed = try @as(*Super, @ptrCast(@alignCast(self))).write(allocator, &.{}, .{});
                    if (failed) {
                        return .backpressure;
                    }
                } else if (send_buffer_attribute == .needs_uncork) {
                    _, const failed = try @as(*Super, @ptrCast(@alignCast(self))).uncork(allocator, null, false);
                    if (failed) {
                        return .backpressure;
                    }
                }
            }
            if (websocket_context_data.reset_idle_timeout_on_send) {
                std.debug.print("set timeout @ websocket.zig:165\n", .{});
                @as(*Super, @ptrCast(@alignCast(self))).timeout(websocket_context_data.idle_timeout_components[0]);
                websocket_data = @as(*zs.Socket, @ptrCast(@alignCast(self))).ext[0].get(WebSocketData).?;
                websocket_data.has_timed_out = false;
            }
            return .success;
        }

        pub fn end(self: *Self, allocator: std.mem.Allocator, io: std.Io, code: i32, message: []const u8) !void {
            const websocket_data: *WebSocketData = @as(*zs.Socket, @ptrCast(@alignCast(self))).ext[0].get(WebSocketData).?;
            if (websocket_data.is_shutting_down) {
                return;
            }
            websocket_data.is_shutting_down = true;
            const max_close_payload = 123;
            const length = @min(max_close_payload, message.len);
            var close_payload: [max_close_payload + 2]u8 = undefined;
            const close_payload_length = Protocol.formatClosePayload(&close_payload, @intCast(code), message[0..length]);
            const ok = try self.send(allocator, io, close_payload[0..close_payload_length], .close, .no_action, true);
            if (!self.isCorked()) {
                if (ok != .backpressure) {
                    @as(*Super, @ptrCast(@alignCast(self))).shutdown();
                }
            }
            const websocket_context_data: *WebSocketContextData(ssl, UserData) = @as(*zs.Socket, @ptrCast(@alignCast(self))).context.ext[0].get(WebSocketContextData(ssl, UserData)).?;
            std.debug.print("set timeout @ websocket.zig:190\n", .{});
            @as(*Super, @ptrCast(@alignCast(self))).timeout(websocket_context_data.idle_timeout_components[1]);
            if (websocket_data.subscriber) |subscriber| {
                if (websocket_context_data.subscription_handler) |*sub_handler| {
                    var iter = subscriber.topics.keyIterator();
                    while (iter.next()) |t| {
                        try sub_handler.call(.{ allocator, io, self, t.*.name, @as(i32, @intCast(t.*.subscribers.count() - 1)), @as(i32, @intCast(t.*.subscribers.count())) });
                    }
                }
            }
            websocket_context_data.topic_tree.freeSubscriber(allocator, websocket_data.subscriber);
            websocket_data.subscriber = null;
            if (websocket_context_data.close_handler) |*close_handler| {
                try close_handler.call(.{ allocator, io, self, code, message });
            }
            // TODO: need to add compile time check that `UserData` has a `deinit` method
            if (@hasDecl(UserData, "deinit")) {
                self.getUserData().deinit(allocator);
            }
        }

        pub fn canCork(self: *Self) bool {
            return @as(*Super, @ptrCast(@alignCast(self))).canCork();
        }

        pub fn isCorked(self: *Self) bool {
            return @as(*Super, @ptrCast(@alignCast(self))).isCorked();
        }

        pub fn cork(self: *Self, allocator: std.mem.Allocator, handler: Lambda(?*anyopaque, &.{}, void)) !void {
            if (!@as(*Super, @ptrCast(@alignCast(self))).isCorked() and @as(*Super, @ptrCast(@alignCast(self))).canCork()) {
                @as(*Super, @ptrCast(@alignCast(self))).cork();
                handler.call(.{});
                _, _ = try @as(*Super, @ptrCast(@alignCast(self))).uncork(allocator, null, false);
            } else {
                handler.call(.{});
            }
        }

        pub fn subscribe(self: *Self, allocator: std.mem.Allocator, io: std.Io, topic: []const u8, _: bool) !bool {
            const websocket_context_data: *WebSocketContextData(ssl, UserData) = @as(*zs.Socket, @ptrCast(@alignCast(self))).context.ext[0].get(WebSocketContextData(ssl, UserData)).?;
            const websocket_data: *WebSocketData = @as(*zs.Socket, @ptrCast(@alignCast(self))).ext[0].get(WebSocketData).?;
            if (websocket_data.subscriber == null) {
                websocket_data.subscriber = try websocket_context_data.topic_tree.createSubscriber(allocator);
                websocket_data.subscriber.?.user = self;
            }
            const topic_or_null = try websocket_context_data.topic_tree.subscribe(allocator, websocket_data.subscriber.?, topic);
            if (topic_or_null) |t| {
                if (websocket_context_data.subscription_handler) |sub_handler| {
                    try sub_handler.call(.{ allocator, io, self, topic, @as(i32, @intCast(t.subscribers.count())), @as(i32, @intCast(t.subscribers.count() - 1)) });
                }
            }
            return true;
        }

        pub fn unsubscribe(self: *Self, allocator: std.mem.Allocator, io: std.Io, topic: []const u8, _: bool) !bool {
            const websocket_context_data: *WebSocketContextData(ssl, UserData) = @as(*zs.Socket, @ptrCast(@alignCast(self))).context.ext[0].get(WebSocketContextData(ssl, UserData)).?;
            const websocket_data: *WebSocketData = @as(*zs.Socket, @ptrCast(@alignCast(self))).ext[0].get(WebSocketData).?;
            if (websocket_data.subscriber) |subscriber| {
                const ok, _, const new_count = websocket_context_data.topic_tree.unsubscribe(subscriber, topic);
                if (ok) {
                    if (websocket_context_data.subscription_handler) |sub_handler| {
                        try sub_handler.call(.{ allocator, io, self, topic, new_count, new_count + 1 });
                    }
                }
                return ok;
            } else return false;
        }

        pub fn isSubscribed(self: *Self, topic: []const u8) bool {
            const websocket_context_data: *WebSocketContextData(ssl, UserData) = @as(*zs.Socket, @ptrCast(@alignCast(self))).context.ext[0].get(WebSocketContextData(ssl, UserData)).?;
            const websocket_data: *WebSocketData = @as(*zs.Socket, @ptrCast(@alignCast(self))).ext[0].get(WebSocketData).?;
            if (websocket_data.subscriber) |subscriber| {
                const topic_ptr = websocket_context_data.topic_tree.lookupTopic(topic);
                if (topic_ptr) |t| {
                    return t.subscribers.contains(subscriber);
                } else return false;
            } else return false;
        }

        pub fn iterateTopics(self: *Self, cb: Lambda(?*anyopaque, &.{[]const u8}, void)) void {
            const websocket_context_data: *WebSocketContextData(ssl, UserData) = @as(*zs.Socket, @ptrCast(@alignCast(self))).context.ext[0].get(WebSocketContextData(ssl, UserData)).?;
            const websocket_data: *WebSocketData = @as(*zs.Socket, @ptrCast(@alignCast(self))).ext[0].get(WebSocketData).?;
            if (websocket_data.subscriber) |subscriber| {
                websocket_context_data.topic_tree.iterating_subscriber = subscriber;
                var iter = subscriber.topics.keyIterator();
                while (iter.next()) |t| {
                    cb.call(.{t.*.name});
                }
                websocket_context_data.topic_tree.iterating_subscriber = null;
            }
        }

        pub fn publish(self: *Self, allocator: std.mem.Allocator, io: std.Io, topic: []const u8, message: []const u8, op_code: OpCode, compress: bool) !bool {
            const websocket_context_data: *WebSocketContextData(ssl, UserData) = @as(*zs.Socket, @ptrCast(@alignCast(self))).context.ext[0].get(WebSocketContextData(ssl, UserData)).?;
            const websocket_data: *WebSocketData = @as(*zs.Socket, @ptrCast(@alignCast(self))).ext[0].get(WebSocketData).?;
            if (websocket_data.subscriber) |subscriber| {
                if (message.len >= LoopData.cork_buffer_size) {
                    return websocket_context_data.topic_tree.publishBig(
                        allocator,
                        io,
                        subscriber,
                        topic,
                        .{ .message = message, .op_code = @intFromEnum(op_code), .compress = compress },
                        (struct {
                            pub fn call(a: std.mem.Allocator, io_: std.Io, s: *Subscriber, m: TopicTreeBigMessage) !void {
                                const ws: *WebSocket(ssl, true, i32) = @ptrCast(@alignCast(s.user));
                                _ = try ws.send(a, io_, m.message, @enumFromInt(m.op_code), @enumFromInt(@intFromBool(m.compress)), true);
                            }
                        }).call,
                    );
                } else {
                    return websocket_context_data.topic_tree.publish(allocator, io, subscriber, topic, .{ .message = try websocket_context_data.topic_tree.dupe(message), .op_code = @intFromEnum(op_code), .compress = compress });
                }
            } else return false;
        }
    };
}
