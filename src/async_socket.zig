const env = @import("env");
const std = @import("std");
const zs = @import("zSockets");

const AsyncSocketData = @import("async_socket_data.zig").AsyncSocketData;
const BackPressure = @import("async_socket_data.zig").BackPressure;
const HttpResponseData = @import("http_response_data.zig").HttpResponseData;
const LoopData = @import("loop_data.zig");
const WebSocketData = @import("websocket_data.zig");

pub const SendBufferAttribute = enum {
    needs_nothing,
    needs_drain,
    needs_uncork,
};

pub fn AsyncSocket(comptime ssl: bool) type {
    return struct {
        const Self = @This();

        threadlocal var zs_events: [2]i32 = @splat(0);
        threadlocal var address_text_buf: [64]u8 = undefined;
        threadlocal var remote_address_buf: [16]u8 = undefined;

        fn throttleHelper(self: *Self, toggle: i32) void {
            const p: *zs.Poll = &@as(*zs.Socket, @ptrCast(@alignCast(self))).p;
            const loop: *zs.Loop = @as(*zs.Socket, @ptrCast(@alignCast(self))).context.loop;
            if (toggle != 0) {
                const events = p.events();
                if (events != 0) {
                    zs_events[if (self.getBufferedAmount() != 0) 1 else 0] = events;
                }
                p.change(loop, 0);
            } else {
                const events = zs_events[if (self.getBufferedAmount() != 0) 1 else 0];
                p.change(loop, events);
            }
        }

        pub fn getNativeHandle(self: *Self) ?*anyopaque {
            return @as(*zs.Socket, @ptrCast(@alignCast(self))).getNativeHandle(ssl);
        }

        pub fn getLoopData(self: *Self) *LoopData {
            return @as(*zs.Socket, @ptrCast(@alignCast(self))).context.loop.ext[0].get(LoopData).?;
        }

        pub fn getAsyncSocketData(self: *Self) *AsyncSocketData(ssl) {
            return @as(*zs.Socket, @ptrCast(@alignCast(self))).ext[0].getAsyncSocketData(AsyncSocketData(ssl)).?;
        }

        pub fn timeout(self: *Self, seconds: u32) void {
            @as(*zs.Socket, @ptrCast(@alignCast(self))).setTimeout(ssl, seconds);
        }

        pub fn shutdown(self: *Self) void {
            @as(*zs.Socket, @ptrCast(@alignCast(self))).shutdown(ssl);
        }

        pub fn pause(self: *Self) *zs.Socket {
            throttleHelper(1);
            return @ptrCast(@alignCast(self));
        }

        pub fn @"resume"(self: *Self) *zs.Socket {
            throttleHelper(0);
            return @ptrCast(@alignCast(self));
        }

        pub fn close(self: *Self, allocator: std.mem.Allocator, io: std.Io) !*zs.Socket {
            return @as(*zs.Socket, @ptrCast(@alignCast(self))).close(allocator, io, ssl, 0, null);
        }

        pub fn corkUnchecked(self: *Self) void {
            self.getLoopData().corked_socket = self;
        }

        pub fn uncorkWithoutSending(self: *Self) void {
            if (self.isCorked()) {
                self.getLoopData().corked_socket = null;
            }
        }

        pub fn cork(self: *Self) void {
            if (self.getLoopData().cork_offset != 0 and self.getLoopData().corked_socket != @as(?*anyopaque, @ptrCast(@alignCast(self)))) {
                std.process.fatal("Error: Cork buffer must not be acquired without checking canCork!", .{});
            }
            self.getLoopData().corked_socket = self;
        }

        pub fn isCorked(self: *Self) bool {
            return self.getLoopData().corked_socket == @as(?*anyopaque, @ptrCast(@alignCast(self)));
        }

        pub fn canCork(self: *Self) bool {
            return self.getLoopData().corked_socket == null;
        }

        pub fn getSendBuffer(self: *Self, allocator: std.mem.Allocator, size: usize) !@Tuple(&.{ [*]u8, SendBufferAttribute }) {
            const loop_data = self.getLoopData();
            const backpressure: *BackPressure = &self.getAsyncSocketData().buffer;
            const existing_backpressure = backpressure.len();
            if ((existing_backpressure == 0) and (self.isCorked() or self.canCork()) and (@as(usize, @intCast(loop_data.cork_offset)) + size < LoopData.cork_buffer_size)) {
                if (self.isCorked()) {
                    const send_buffer = loop_data.cork_buffer.ptr + loop_data.cork_offset;
                    loop_data.cork_offset += @intCast(size);
                    return .{ send_buffer, .needs_nothing };
                } else {
                    self.cork();
                    const send_buffer = loop_data.cork_buffer.ptr + loop_data.cork_offset;
                    loop_data.cork_offset += @intCast(size);
                    return .{ send_buffer, .needs_uncork };
                }
            } else {
                var our_cork_offset: u32 = 0;
                if (self.isCorked() and loop_data.cork_offset != 0) {
                    our_cork_offset = loop_data.cork_offset;
                    loop_data.cork_offset = 0;
                }
                try backpressure.resize(allocator, our_cork_offset + existing_backpressure + size);
                @memcpy((backpressure.asSlice().ptr + existing_backpressure)[0..our_cork_offset], loop_data.cork_buffer[0..our_cork_offset]);
                return .{ backpressure.asSlice().ptr + our_cork_offset + existing_backpressure, .needs_drain };
            }
        }

        pub fn getBufferedAmount(self: *Self) usize {
            return self.getAsyncSocketData().buffer.totalLength();
        }

        pub fn addressAsText(_: *const Self, binary: []const u8) ![]const u8 {
            if (binary.len == 0) {
                return &.{};
            }
            if (binary.len == 4) {
                return std.fmt.bufPrint(&address_text_buf, "{d}.{d}.{d}.{d}", .{ binary[0], binary[1], binary[2], binary[3] });
            } else {
                return std.fmt.bufPrint(&address_text_buf, "{x:0>2}{x:>02}:{x:0>2}{x:>02}:{x:0>2}{x:>02}:{x:0>2}{x:>02}:{x:0>2}{x:>02}:{x:0>2}{x:>02}:{x:0>2}{x:>02}:{x:0>2}{x:>02}", .{ binary[0], binary[1], binary[2], binary[3], binary[4], binary[5], binary[6], binary[7], binary[8], binary[9], binary[10], binary[11], binary[12], binary[13], binary[14], binary[15] });
            }
        }

        pub fn getRemoteAddress(self: *Self) []const u8 {
            if (env.remote_address_userspace) {
                return self.getAsyncSocketData().remote_address;
            } else {
                return @as(*zs.Socket, @ptrCast(@alignCast(self))).remoteAddress(ssl, &remote_address_buf);
            }
        }

        pub fn getRemoteAddressAsText(self: *Self) []const u8 {
            return self.addressAsText(self.getRemoteAddress());
        }

        pub fn getRemotePort(self: *Self) !u32 {
            return @as(*zs.Socket, @ptrCast(@alignCast(self))).remotePort();
        }

        pub fn write(self: *Self, allocator: std.mem.Allocator, src: []const u8, opts: struct { optionally: bool = false, next_length: u32 = 0 }) std.mem.Allocator.Error!@Tuple(&.{ usize, bool }) {
            if (@as(*zs.Socket, @ptrCast(@alignCast(self))).isClosed(ssl)) {
                return .{ src.len, false };
            }

            const loop_data: *LoopData = self.getLoopData();
            const async_socket_data: *AsyncSocketData(ssl) = self.getAsyncSocketData();
            if (async_socket_data.buffer.len() != 0) {
                const written = @as(*zs.Socket, @ptrCast(@alignCast(self))).write(ssl, async_socket_data.buffer.asSlice(), src.len != 0);
                if (written < async_socket_data.buffer.len()) {
                    async_socket_data.buffer.erase(written);
                    if (opts.optionally) {
                        return .{ 0, true };
                    } else {
                        try async_socket_data.buffer.append(allocator, src);
                        return .{ src.len, true };
                    }
                }

                async_socket_data.buffer.clear(allocator);
            }

            if (src.len != 0) {
                if (loop_data.corked_socket == @as(?*anyopaque, @ptrCast(@alignCast(self)))) {
                    if (LoopData.cork_buffer_size - loop_data.cork_offset >= @as(u32, @intCast(src.len))) {
                        @memcpy((loop_data.cork_buffer.ptr + loop_data.cork_offset)[0..src.len], src);
                        loop_data.cork_offset += @intCast(src.len);
                    } else {
                        if (false) {
                            const stripped = LoopData.cork_buffer_size - loop_data.cork_offset;
                            @memcpy((loop_data.cork_buffer.ptr + loop_data.cork_offset)[0..stripped], src.ptr[0..stripped]);
                            loop_data.cork_offset = LoopData.cork_buffer_size;
                            const written, const failed = try self.uncork(allocator, src[stripped..], opts.optionally);
                            return .{ written + stripped, failed };
                        }
                        return self.uncork(allocator, src, opts.optionally);
                    }
                } else {
                    const written = @as(*zs.Socket, @ptrCast(@alignCast(self))).write(ssl, src, opts.next_length != 0);
                    if (written < src.len) {
                        if (opts.optionally) {
                            return .{ written, true };
                        }
                        if (opts.next_length != 0) {
                            try async_socket_data.buffer.reserve(allocator, async_socket_data.buffer.len() + (src.len - written + opts.next_length));
                        }
                        try async_socket_data.buffer.append(allocator, src[written..]);
                        return .{ src.len, true };
                    }
                }
            }
            return .{ src.len, false };
        }

        pub fn uncork(self: *Self, allocator: std.mem.Allocator, src: ?[]const u8, optionally: bool) std.mem.Allocator.Error!@Tuple(&.{ usize, bool }) {
            const src_ = src orelse &.{};
            const loop_data = self.getLoopData();
            if (loop_data.corked_socket == @as(?*anyopaque, @ptrCast(@alignCast(self)))) {
                loop_data.corked_socket = null;
                if (loop_data.cork_offset != 0) {
                    _, const failed = try self.write(allocator, loop_data.cork_buffer[0..loop_data.cork_offset], .{ .optionally = false, .next_length = @intCast(src_.len) });
                    loop_data.cork_offset = 0;
                    if (failed) {
                        if (!optionally and src_.len != 0) {
                            const async_socket_data = self.getAsyncSocketData();
                            try async_socket_data.buffer.append(allocator, src_);
                            return .{ src_.len, true };
                        }
                        return .{ 0, true };
                    }
                }
                return self.write(allocator, src_, .{ .optionally = optionally, .next_length = 0 });
            } else {
                return .{ 0, false };
            }
        }
    };
}
