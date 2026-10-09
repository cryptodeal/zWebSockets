const std = @import("std");
const websocket_protocol = @import("websocket_protocol.zig");
const zs = @import("zSockets");

const AsyncSocket = @import("async_socket.zig").AsyncSocket;
const Loop = @import("loop.zig").Loop;
const LoopData = @import("loop_data.zig");
const OpCode = websocket_protocol.OpCode;
const Protocol = websocket_protocol.Protocol;
const TopicTree = @import("topic_tree.zig").TopicTree;
const TopicTreeBigMessage = @import("websocket_context_data.zig").TopicTreeBigMessage;
const TopicTreeMessage = @import("websocket_context_data.zig").TopicTreeMessage;
const WebSocket = @import("websocket.zig").WebSocket;
const WebSocketContextData = @import("websocket_context_data.zig").WebSocketContextData;
const WebSocketData = @import("websocket_data.zig");
const WebSocketProtocol = websocket_protocol.WebSocketProtocol;
const WebSocketState = @import("websocket_protocol.zig").WebSocketState;

pub fn WebSocketContext(comptime ssl: bool, comptime is_server: bool, comptime UserData: type) type {
    return struct {
        const Self = @This();

        pub fn getSocketContext(self: *Self) *zs.SocketContext {
            return @ptrCast(@alignCast(self));
        }

        pub fn getExt(self: *Self) *WebSocketContextData(ssl, UserData) {
            return self.getSocketContext().ext[0].get(WebSocketContextData(ssl, UserData)).?;
        }

        pub fn setCompressed(_: *WebSocketState(is_server), s: ?*anyopaque) bool {
            const websocket_data: *WebSocketData = @as(*zs.Socket, @ptrCast(@alignCast(s))).ext[0].get(WebSocketData).?;
            if (websocket_data.compression_status == .enabled) {
                websocket_data.compression_status = .compressed_frame;
                return true;
            } else {
                return false;
            }
        }

        pub fn forceClose(allocator: std.mem.Allocator, io: std.Io, _: ?*WebSocketState(is_server), s: ?*anyopaque, reason: []const u8) !void {
            _ = try @as(*zs.Socket, @ptrCast(@alignCast(s))).close(allocator, io, ssl, @intCast(reason.len), @constCast(reason.ptr));
        }

        pub fn handleFragment(allocator: std.mem.Allocator, io: std.Io, data: []u8, remaining_bytes: u32, op_code: i32, fin: bool, websocket_state: *WebSocketState(is_server), s: ?*anyopaque) !bool {
            var data_ = data;
            const websocket_context_data: *WebSocketContextData(ssl, UserData) = @as(*zs.Socket, @ptrCast(@alignCast(s))).context.ext[0].get(WebSocketContextData(ssl, UserData)).?;
            const websocket_data: *WebSocketData = @as(*zs.Socket, @ptrCast(@alignCast(s))).ext[0].get(WebSocketData).?;
            if (op_code < 3) {
                if (remaining_bytes == 0 and fin and websocket_data.fragment_buffer.items.len == 0) {
                    if (websocket_data.compression_status == .compressed_frame) {
                        websocket_data.compression_status = .enabled;
                        const loop_data: *LoopData = @as(*zs.Socket, @ptrCast(@alignCast(s))).context.loop.ext[0].get(LoopData).?;
                        var inflated_frame: ?[]u8 = null;
                        if (websocket_data.inflation_stream) |inflation_stream| {
                            inflated_frame = try inflation_stream.inflate(allocator, loop_data.zlib_context.?, data_, websocket_context_data.max_payload_length, false);
                        } else {
                            inflated_frame = try loop_data.inflation_stream.?.inflate(allocator, loop_data.zlib_context.?, data_, websocket_context_data.max_payload_length, true);
                        }
                        if (inflated_frame) |frame| {
                            data_ = frame;
                        } else {
                            try forceClose(allocator, io, websocket_state, s, websocket_protocol.err_too_big_message_inflation);
                            return true;
                        }
                    }
                    if (op_code == 1 and !Protocol.isValidUtf8(data_)) {
                        try forceClose(allocator, io, websocket_state, s, websocket_protocol.err_invalid_text);
                        return true;
                    }
                    if (websocket_context_data.message_handler) |*message_handler| {
                        try message_handler.call(.{ allocator, io, @as(*WebSocket(ssl, is_server, UserData), @ptrCast(@alignCast(s))), data_, @as(OpCode, @enumFromInt(op_code)) });
                        if (@as(*zs.Socket, @ptrCast(@alignCast(s))).isClosed(ssl) or websocket_data.is_shutting_down) {
                            return true;
                        }
                    }
                } else {
                    if (websocket_data.fragment_buffer.items.len == 0) {
                        try websocket_data.fragment_buffer.ensureTotalCapacity(allocator, data_.len + remaining_bytes);
                    }
                    if (refusePayloadLength(data_.len + websocket_data.fragment_buffer.items.len, websocket_state, s)) {
                        try forceClose(allocator, io, websocket_state, s, websocket_protocol.err_too_big_message);
                        return true;
                    }
                    try websocket_data.fragment_buffer.appendSlice(allocator, data_);
                    if (remaining_bytes == 0 and fin) {
                        if (websocket_data.compression_status == .compressed_frame) {
                            websocket_data.compression_status = .enabled;
                            try websocket_data.fragment_buffer.appendSlice(allocator, "123456789");
                            const loop_data: *LoopData = @as(*zs.Socket, @ptrCast(@alignCast(s))).context.loop.ext[0].get(LoopData).?;
                            var inflated_frame: ?[]u8 = null;
                            if (websocket_data.inflation_stream) |inflation_stream| {
                                inflated_frame = try inflation_stream.inflate(allocator, loop_data.zlib_context.?, websocket_data.fragment_buffer.items[0 .. websocket_data.fragment_buffer.items.len - 9], websocket_context_data.max_payload_length, false);
                            } else {
                                inflated_frame = try loop_data.inflation_stream.?.inflate(allocator, loop_data.zlib_context.?, websocket_data.fragment_buffer.items[0 .. websocket_data.fragment_buffer.items.len - 9], websocket_context_data.max_payload_length, true);
                            }
                            if (inflated_frame) |frame| {
                                data_ = frame;
                            } else {
                                try forceClose(allocator, io, websocket_state, s, websocket_protocol.err_too_big_message_inflation);
                                return true;
                            }
                        } else {
                            data_ = websocket_data.fragment_buffer.items;
                        }
                        if (op_code == 1 and !Protocol.isValidUtf8(data_)) {
                            try forceClose(allocator, io, websocket_state, s, websocket_protocol.err_invalid_text);
                            return true;
                        }
                        if (websocket_context_data.message_handler) |*message_handler| {
                            try message_handler.call(.{ allocator, io, @as(*WebSocket(ssl, is_server, UserData), @ptrCast(@alignCast(s))), data_, @as(OpCode, @enumFromInt(op_code)) });
                            if (@as(*zs.Socket, @ptrCast(@alignCast(s))).isClosed(ssl) or websocket_data.is_shutting_down) {
                                return true;
                            }
                        }
                        websocket_data.fragment_buffer.clearRetainingCapacity();
                    }
                }
            } else {
                const websocket: *WebSocket(ssl, is_server, UserData) = @ptrCast(@alignCast(s));
                if (remaining_bytes == 0 and fin and websocket_data.control_tip_length == 0) {
                    if (op_code == @intFromEnum(OpCode.close)) {
                        const close_frame = Protocol.parseClosePayload(data_);
                        try websocket.end(allocator, io, @intCast(close_frame.code), close_frame.message);
                        return true;
                    } else {
                        if (op_code == @intFromEnum(OpCode.ping)) {
                            _ = try websocket.send(allocator, io, data_, .pong, .no_action, true);
                            if (websocket_context_data.ping_handler) |*ping_handler| {
                                try ping_handler.call(.{ allocator, io, websocket, data_ });
                                if (@as(*zs.Socket, @ptrCast(@alignCast(s))).isClosed(ssl) or websocket_data.is_shutting_down) {
                                    return true;
                                }
                            }
                        } else if (op_code == @intFromEnum(OpCode.pong)) {
                            if (websocket_context_data.pong_handler) |*pong_handler| {
                                try pong_handler.call(.{ allocator, io, websocket, data_ });
                                if (@as(*zs.Socket, @ptrCast(@alignCast(s))).isClosed(ssl) or websocket_data.is_shutting_down) {
                                    return true;
                                }
                            }
                        }
                    }
                } else {
                    try websocket_data.fragment_buffer.appendSlice(allocator, data_);
                    websocket_data.control_tip_length += @intCast(data_.len);
                    if (remaining_bytes == 0 and fin) {
                        const control_buffer = websocket_data.fragment_buffer.items[websocket_data.fragment_buffer.items.len - websocket_data.control_tip_length ..];
                        if (op_code == @intFromEnum(OpCode.close)) {
                            const close_frame = Protocol.parseClosePayload(control_buffer);
                            try websocket.end(allocator, io, @intCast(close_frame.code), close_frame.message);
                            return true;
                        } else {
                            if (op_code == @intFromEnum(OpCode.ping)) {
                                _ = try websocket.send(allocator, io, control_buffer, .pong, .no_action, true);
                                if (websocket_context_data.ping_handler) |*ping_handler| {
                                    try ping_handler.call(.{ allocator, io, websocket, control_buffer });
                                    if (@as(*zs.Socket, @ptrCast(@alignCast(s))).isClosed(ssl) or websocket_data.is_shutting_down) {
                                        return true;
                                    }
                                }
                            } else if (op_code == @intFromEnum(OpCode.pong)) {
                                if (websocket_context_data.pong_handler) |*pong_handler| {
                                    try pong_handler.call(.{ allocator, io, websocket, control_buffer });
                                    if (@as(*zs.Socket, @ptrCast(@alignCast(s))).isClosed(ssl) or websocket_data.is_shutting_down) {
                                        return true;
                                    }
                                }
                            }
                        }
                        try websocket_data.fragment_buffer.resize(allocator, websocket_data.fragment_buffer.items.len - websocket_data.control_tip_length);
                        websocket_data.control_tip_length = 0;
                    }
                }
            }
            return false;
        }

        pub fn refusePayloadLength(length: usize, _: *WebSocketState(is_server), s: ?*anyopaque) bool {
            const websocket_context_data: *WebSocketContextData(ssl, UserData) = @as(*zs.Socket, @ptrCast(@alignCast(s))).context.ext[0].get(WebSocketContextData(ssl, UserData)).?;
            return websocket_context_data.max_payload_length < length;
        }

        fn setup(self: *Self) *Self {
            self.getSocketContext().setOnClose(
                ssl,
                (struct {
                    pub fn call(a: std.mem.Allocator, io: std.Io, s: *zs.Socket, code: i32, reason: ?*anyopaque) !*zs.Socket {
                        const websocket_data: *WebSocketData = s.ext[0].get(WebSocketData).?;
                        if (!websocket_data.is_shutting_down) {
                            const websocket_context_data: *WebSocketContextData(ssl, UserData) = s.context.ext[0].get(WebSocketContextData(ssl, UserData)).?;
                            if (websocket_data.subscriber) |subscriber| {
                                if (websocket_context_data.subscription_handler) |*subscription_handler| {
                                    var iter = subscriber.topics.keyIterator();
                                    while (iter.next()) |t| {
                                        try subscription_handler.call(.{ a, io, @as(*WebSocket(ssl, is_server, UserData), @ptrCast(@alignCast(s))), t.*.name, @as(i32, @intCast(t.*.subscribers.count() - 1)), @as(i32, @intCast(t.*.subscribers.count())) });
                                    }
                                }
                            }
                            websocket_context_data.topic_tree.freeSubscriber(a, websocket_data.subscriber);
                            websocket_data.subscriber = null;
                            const ws: *WebSocket(ssl, is_server, UserData) = @ptrCast(@alignCast(s));
                            if (websocket_context_data.close_handler) |*close_handler| {
                                try close_handler.call(.{ a, io, ws, 1006, if (reason) |r| @as([*]u8, @ptrCast(@alignCast(r)))[0..@intCast(code)] else &.{} });
                            }
                            if (@hasDecl(UserData, "deinit")) {
                                ws.getUserData().deinit(a);
                            }
                        }
                        websocket_data.deinit(a);
                        return s;
                    }
                }).call,
            );
            self.getSocketContext().setOnData(
                ssl,
                (struct {
                    pub fn call(a: std.mem.Allocator, io: std.Io, s: *zs.Socket, data: []u8) !*zs.Socket {
                        const websocket_data: *WebSocketData = s.ext[0].get(WebSocketData).?;
                        if (websocket_data.is_shutting_down) {
                            return s;
                        }
                        const websocket_context_data: *WebSocketContextData(ssl, UserData) = s.context.ext[0].get(WebSocketContextData(ssl, UserData)).?;
                        const async_socket: *AsyncSocket(ssl) = @ptrCast(@alignCast(s));
                        async_socket.timeout(websocket_context_data.idle_timeout_components[0]);
                        websocket_data.has_timed_out = false;
                        async_socket.cork();
                        try WebSocketProtocol(is_server, WebSocketContext(ssl, is_server, UserData)).consume(a, io, data, &websocket_data.websocket_state, s);
                        _ = try async_socket.uncork(a, null, false);
                        if (async_socket.getBufferedAmount() == 0) {
                            if (websocket_data.is_shutting_down) {
                                async_socket.shutdown();
                            }
                        }
                        return s;
                    }
                }).call,
            );
            self.getSocketContext().setOnWritable(
                ssl,
                (struct {
                    pub fn call(a: std.mem.Allocator, io: std.Io, s: *zs.Socket) !*zs.Socket {
                        if (s.isShutdown(ssl)) {
                            return s;
                        }
                        const async_socket: *AsyncSocket(ssl) = @ptrCast(@alignCast(s));
                        const websocket_data: *WebSocketData = s.ext[0].get(WebSocketData).?;
                        const backpressure = async_socket.getBufferedAmount();
                        _ = try async_socket.write(a, &.{}, .{});
                        if (backpressure == 0 or backpressure > async_socket.getBufferedAmount()) {
                            const websocket_context_data: *WebSocketContextData(ssl, UserData) = s.context.ext[0].get(WebSocketContextData(ssl, UserData)).?;
                            async_socket.timeout(websocket_context_data.idle_timeout_components[0]);
                            websocket_data.has_timed_out = false;
                        }
                        if (websocket_data.is_shutting_down) {
                            if (async_socket.getBufferedAmount() == 0) {
                                async_socket.shutdown();
                            }
                        } else if (backpressure == 0 or backpressure > async_socket.getBufferedAmount()) {
                            const websocket_context_data: *WebSocketContextData(ssl, UserData) = s.context.ext[0].get(WebSocketContextData(ssl, UserData)).?;
                            if (websocket_context_data.drain_handler) |*drain_handler| {
                                try drain_handler.call(.{ a, io, @as(*WebSocket(ssl, true, UserData), @ptrCast(@alignCast(s))) });
                            }
                        }
                        return s;
                    }
                }).call,
            );
            self.getSocketContext().setOnEnd(
                ssl,
                (struct {
                    pub fn call(a: std.mem.Allocator, io: std.Io, s: *zs.Socket) !*zs.Socket {
                        _ = try s.close(a, io, ssl, websocket_protocol.err_tcp_fin.len, @constCast(websocket_protocol.err_tcp_fin.ptr));
                        return s;
                    }
                }).call,
            );
            self.getSocketContext().setOnLongTimeout(
                ssl,
                (struct {
                    pub fn call(a: std.mem.Allocator, io: std.Io, s: *zs.Socket) !*zs.Socket {
                        try @as(*WebSocket(ssl, is_server, UserData), @ptrCast(@alignCast(s))).end(a, io, 1000, "please reconnect");
                        return s;
                    }
                }).call,
            );
            self.getSocketContext().setOnTimeout(
                ssl,
                (struct {
                    pub fn call(a: std.mem.Allocator, io: std.Io, s: *zs.Socket) !*zs.Socket {
                        const websocket_data: *WebSocketData = s.ext[0].get(WebSocketData).?;
                        const websocket_context_data: *WebSocketContextData(ssl, UserData) = s.context.ext[0].get(WebSocketContextData(ssl, UserData)).?;
                        if (websocket_context_data.send_pings_automatically and !websocket_data.is_shutting_down and !websocket_data.has_timed_out) {
                            websocket_data.has_timed_out = true;
                            s.setTimeout(ssl, websocket_context_data.idle_timeout_components[0]);
                            _ = try @as(*AsyncSocket(ssl), @ptrCast(@alignCast(s))).write(a, "\x89\x00", .{});
                            return s;
                        }
                        try forceClose(a, io, null, s, websocket_protocol.err_websocket_timeout);
                        return s;
                    }
                }).call,
            );
            return self;
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            const websocket_context_data: *WebSocketContextData(ssl, UserData) = @as(*zs.SocketContext, @ptrCast(@alignCast(self))).ext[0].get(WebSocketContextData(ssl, UserData)).?;
            websocket_context_data.deinit(allocator);
            @as(*zs.SocketContext, @ptrCast(@alignCast(self))).deinit(allocator);
        }

        pub fn init(allocator: std.mem.Allocator, _: *Loop, parent_socket_context: *zs.SocketContext, topic_tree: *TopicTree(TopicTreeMessage, TopicTreeBigMessage)) !*Self {
            const websocket_context: *Self = @ptrCast(@alignCast(try parent_socket_context.createChildContext(allocator, ssl, &.{WebSocketContextData(ssl, UserData)})));
            const websocket_context_data: *WebSocketContextData(ssl, UserData) = @as(*zs.SocketContext, @ptrCast(@alignCast(websocket_context))).ext[0].get(WebSocketContextData(ssl, UserData)).?;
            websocket_context_data.init(topic_tree);
            return websocket_context.setup();
        }
    };
}
