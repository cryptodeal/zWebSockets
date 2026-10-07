const std = @import("std");

const CompressOptions = @import("per_message_deflate.zig").CompressOptions;
const Lambda = @import("lambda.zig").Lambda;
const OpCode = @import("websocket_protocol.zig").OpCode;
const TopicTree = @import("topic_tree.zig").TopicTree;
const WebSocket = @import("websocket.zig").WebSocket;

pub const TopicTreeMessage = struct {
    message: []const u8,
    op_code: i32,
    compress: bool,
};

pub const TopicTreeBigMessage = struct {
    message: []const u8,
    op_code: i32,
    compress: bool,
};

pub fn WebSocketContextData(comptime ssl: bool, comptime UserData: type) type {
    return struct {
        const Self = @This();

        topic_tree: *TopicTree(TopicTreeMessage, TopicTreeBigMessage),
        open_handler: ?Lambda(?*anyopaque, &.{ std.mem.Allocator, std.Io, *WebSocket(ssl, true, UserData) }, anyerror!void) = null,
        message_handler: ?Lambda(?*anyopaque, &.{ std.mem.Allocator, std.Io, *WebSocket(ssl, true, UserData), []const u8, OpCode }, anyerror!void) = null,
        dropped_handler: ?Lambda(?*anyopaque, &.{ std.mem.Allocator, std.Io, *WebSocket(ssl, true, UserData), []const u8, OpCode }, anyerror!void) = null,
        drain_handler: ?Lambda(?*anyopaque, &.{ std.mem.Allocator, std.Io, *WebSocket(ssl, true, UserData) }, anyerror!void) = null,
        subscription_handler: ?Lambda(?*anyopaque, &.{ std.mem.Allocator, std.Io, *WebSocket(ssl, true, UserData), []const u8, i32, i32 }, anyerror!void) = null,
        close_handler: ?Lambda(?*anyopaque, &.{ std.mem.Allocator, std.Io, *WebSocket(ssl, true, UserData), i32, []const u8 }, anyerror!void) = null,
        ping_handler: ?Lambda(?*anyopaque, &.{ std.mem.Allocator, std.Io, *WebSocket(ssl, true, UserData), []const u8 }, anyerror!void) = null,
        pong_handler: ?Lambda(?*anyopaque, &.{ std.mem.Allocator, std.Io, *WebSocket(ssl, true, UserData), []const u8 }, anyerror!void) = null,
        max_payload_length: usize = 0,
        compression: CompressOptions = undefined,
        max_backpressure: usize = 0,
        close_on_backpressure_limit: bool = undefined,
        reset_idle_timeout_on_send: bool = undefined,
        send_pings_automatically: bool = undefined,
        max_lifetime: u16 = undefined,
        idle_timeout_components: @Tuple(&.{ u16, u16 }) = undefined,

        pub fn init(self: *Self, topic_tree: *TopicTree(TopicTreeMessage, TopicTreeBigMessage)) void {
            self.* = .{ .topic_tree = topic_tree };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            if (self.open_handler) |*oh| oh.deinit(allocator);
            if (self.message_handler) |*mh| mh.deinit(allocator);
            if (self.dropped_handler) |*dh| dh.deinit(allocator);
            if (self.drain_handler) |*dh| dh.deinit(allocator);
            if (self.subscription_handler) |*sh| sh.deinit(allocator);
            if (self.close_handler) |*ch| ch.deinit(allocator);
            if (self.ping_handler) |*ph| ph.deinit(allocator);
            if (self.pong_handler) |*ph| ph.deinit(allocator);
        }

        pub fn calculateIdleTimeoutComponents(self: *Self, idle_timeout: u16) void {
            var margin: u16 = 4;
            while (@as(i32, @intCast(idle_timeout)) - margin * 2 >= @as(i32, @intCast(margin * 2)) and margin < 16) {
                margin = margin << 1;
            }
            self.idle_timeout_components = .{
                idle_timeout - (if (self.send_pings_automatically) margin else 0),
                margin,
            };
        }

        pub fn format(self: Self, w: *std.Io.Writer) std.Io.Writer.Error!void {
            return w.print("WebSocketContextData({any}, {s}){{ max_payload_length: {d}, compression: {s}, max_backpressure: {d}, close_on_backpressure_limit: {any}, reset_idle_timeout_on_send: {any}, send_pings_automatically: {any}, max_lifetime: {d}, idle_timeout_components: .{{ {d}, {d} }}}}", .{
                ssl,
                @typeName(UserData),
                self.max_payload_length,
                @tagName(self.compression),
                self.max_backpressure,
                self.close_on_backpressure_limit,
                self.reset_idle_timeout_on_send,
                self.send_pings_automatically,
                self.max_lifetime,
                self.idle_timeout_components[0],
                self.idle_timeout_components[1],
            });
        }
    };
}
