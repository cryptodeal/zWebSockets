const env = @import("env");
const rand = @import("rand.zig").rand;
const std = @import("std");
const zs = @import("zSockets");

pub const err_too_big_message = "Received too big message";
pub const err_websocket_timeout = "WebSocket timed out from inactivity";
pub const err_invalid_text = "Received invalid UTF-8";
pub const err_too_big_message_inflation = "Received too big message, or other inflation error";
pub const err_invalid_close_payload = "Received invalid close payload";
pub const err_protocol = "Received invalid WebSocket frame";
pub const err_tcp_fin = "Received TCP FIN before WebSocket close frame";

pub const OpCode = enum(u8) {
    continuation = 0,
    text = 1,
    binary = 2,
    close = 8,
    ping = 9,
    pong = 10,
};

pub const WebSocketType = enum {
    client,
    server,
};

pub fn WebSocketState(comptime is_server: bool) type {
    return struct {
        pub const short_message_header = if (is_server) 6 else 2;
        pub const medium_message_header = if (is_server) 8 else 4;
        pub const long_message_header = if (is_server) 14 else 10;

        state: struct {
            wants_head: bool = true,
            spill_length: u4 = 0,
            op_stack: i2 = -1,
            last_fin: bool = true,

            spill: [long_message_header - 1]u8 = undefined,
            op_code: [2]OpCode = undefined,
        } = .{},

        remaining_bytes: u32 = 0,
        mask: [if (is_server) 4 else 1]u8 = undefined,
    };
}

pub const Protocol = struct {

    // threadlocal var rand: std.Random = std.
    pub fn bitCast(comptime T: type, c: []u8) T {
        var val: T = undefined;
        @memcpy(std.mem.asBytes(&val), c[0..@sizeOf(T)]);
        return val;
    }

    pub fn isValidUtf8(s: []const u8) bool {
        if (comptime env.use_simdutf) {}
        var s_ = s.ptr;
        const e = s_ + s.len;
        while (s_ != e) {
            if (@intFromPtr(s_ + 16) <= @intFromPtr(e)) {
                var tmp: [2]u64 = undefined;
                @memcpy(std.mem.sliceAsBytes(&tmp), s_[0..16]);
                if (((tmp[0] & 0x8080808080808080) | (tmp[1] & 0x8080808080808080)) == 0) {
                    s_ += 16;
                    continue;
                }
            }
            while ((s_[0] & 0x80) == 0) {
                s_ += 1;
                if (s_ == e) {
                    return true;
                }
            }

            if ((s_[0] & 0x60) == 0x40) {
                if (@intFromPtr(s_ + 1) >= @intFromPtr(e) or (s_[1] & 0xc0) != 0x80 or (s_[0] & 0xfe) == 0xc0) {
                    return false;
                }
                s_ += 2;
            } else if ((s_[0] & 0xf0) == 0xe0) {
                if (@intFromPtr(s_ + 2) >= @intFromPtr(e) or (s_[1] & 0xc0) != 0x80 or (s_[2] & 0xc0) != 0x80 or
                    (s_[0] == 0xe0 and (s_[1] & 0xe0) == 0x80) or (s_[0] == 0xed and (s_[1] & 0xe0) == 0xa0))
                {
                    return false;
                }
                s_ += 3;
            } else if ((s_[0] & 0xf8) == 0xf0) {
                if (@intFromPtr(s_ + 3) >= @intFromPtr(e) or (s_[1] & 0xc0) != 0x80 or (s_[2] & 0xc0) != 0x80 or (s_[3] & 0xc0) != 0x80 or
                    (s_[0] == 0xf0 and (s_[1] & 0xf0) == 0x80) or (s_[0] == 0xf4 and s_[1] > 0x8f) or s_[0] > 0xf4)
                {
                    return false;
                }
                s_ += 4;
            } else {
                return false;
            }
        }
        return true;
    }

    pub const CloseFrame = struct {
        code: u16,
        message: []const u8,
    };

    pub inline fn parseClosePayload(src: []const u8) CloseFrame {
        var cf: CloseFrame = .{ .code = 1005, .message = &.{} };
        if (src.len >= 2) {
            @memcpy(std.mem.asBytes(&cf.code), src[0..2]);
            cf = .{ .code = std.mem.nativeToBig(u16, cf.code), .message = src[2..] };
            if (cf.code < 1000 or cf.code > 4999 or (cf.code > 1011 and cf.code < 4000) or
                (cf.code >= 1004 and cf.code <= 1006) or !isValidUtf8(cf.message))
            {
                return .{ .code = 1006, .message = err_invalid_close_payload };
            }
        }
        return cf;
    }

    pub inline fn formatClosePayload(dst: []u8, code: u16, message: []const u8) usize {
        var code_ = code;
        if (code_ != 0 and code_ != 1005 and code_ != 1006) {
            code_ = std.mem.nativeToBig(u16, code_);
            @memcpy(dst[0..@sizeOf(u16)], std.mem.asBytes(&code_));
            if (message.len != 0) {
                @memcpy(dst[2 .. 2 + message.len], message);
            }
            return message.len + 2;
        }
        return 0;
    }

    pub inline fn messageFrameSize(message_size: usize) usize {
        if (message_size < 126) {
            return 2 + message_size;
        } else if (message_size <= std.math.maxInt(u16)) {
            return 4 + message_size;
        }
        return 10 + message_size;
    }

    pub const Snd = enum(u8) {
        continuation,
        no_fin,
        compressed,
    };

    pub inline fn formatMessage(comptime is_server: bool, dst: [*]u8, src: []const u8, op_code: OpCode, reported_length: usize, compressed: bool, fin: bool) usize {
        var message_length: usize = undefined;
        var header_length: usize = undefined;
        if (reported_length < 126) {
            header_length = 2;
            dst[1] = @intCast(reported_length);
        } else if (reported_length <= @as(usize, @intCast(std.math.maxInt(u16)))) {
            header_length = 4;
            dst[1] = 126;
            const tmp: u16 = std.mem.nativeToBig(u16, @intCast(reported_length));
            @memcpy(std.mem.sliceAsBytes(dst[2 .. 2 + @sizeOf(u16)]), std.mem.asBytes(&tmp));
        } else {
            header_length = 10;
            dst[1] = 127;
            const tmp: u64 = std.mem.nativeToBig(u64, reported_length);
            @memcpy(std.mem.sliceAsBytes(dst[2 .. 2 + @sizeOf(u64)]), std.mem.asBytes(&tmp));
        }

        dst[0] = @intCast(@as(u8, if (fin) 128 else 0) | (if (compressed and @intFromEnum(op_code) != 0) @intFromEnum(Snd.compressed) else 0) | @intFromEnum(op_code));

        var mask: [4]u8 = undefined;
        if (comptime !is_server) {
            dst[1] |= 0x80;
            const random = rand.int(u32);
            @memcpy(&mask, std.mem.asBytes(&random));
            @memcpy(dst[header_length .. header_length + 4], std.mem.asBytes(&random));
            header_length += 4;
        }

        message_length = header_length + src.len;
        @memcpy(dst[header_length .. header_length + src.len], src);

        if (comptime !is_server) {
            var start = dst + header_length;
            const stop = start + src.len;
            var i: usize = 0;
            while (start != stop) : ({
                start += 1;
                i += 1;
            }) {
                start[0] ^= mask[i % 4];
            }
        }
        return message_length;
    }
};

pub fn WebSocketProtocol(comptime is_server: bool, comptime Impl: type) type {
    return struct {
        const Self = @This();

        const short_message_header = if (is_server) 6 else 2;
        const medium_message_header = if (is_server) 8 else 4;
        const long_message_header = if (is_server) 14 else 10;

        pub const consume_post_padding = 4;
        pub const consume_pre_padding = long_message_header - 1;

        inline fn isFin(frame: [*]u8) bool {
            return (frame[0] & 128) != 0;
        }

        inline fn getOpCode(frame: [*]u8) u8 {
            return frame[0] & 15;
        }

        inline fn payloadLength(frame: [*]u8) u8 {
            return frame[1] & 127;
        }

        inline fn rsv23(frame: [*]u8) bool {
            return (frame[0] & 48) != 0;
        }

        inline fn rsv1(frame: [*]u8) bool {
            return (frame[0] & 64) != 0;
        }

        inline fn unrolledXor(comptime n: u32, noalias data: []u8, noalias mask: []u8) void {
            if (comptime n != 1) {
                unrolledXor(n - 1, data, mask);
            }
            data[n - 1] ^= mask[(n - 1) % 4];
        }

        inline fn unmaskImprecise8(comptime destination: u32, src: []u8, mask: u64) void {
            var src_ = src.ptr;
            var n = (src.len >> 3) + 1;
            while (n != 0) : (n -= 1) {
                var loaded: u64 = undefined;
                @memcpy(std.mem.asBytes(&loaded), src_);
                loaded ^= mask;
                @memcpy(src_ - destination, std.mem.asBytes(&loaded));
                src_ += 8;
            }
        }

        inline fn unmaskImprecise4(comptime destination: u32, src: []u8, mask: u32) void {
            var src_ = src.ptr;
            var n = (src.len >> 2) + 1;
            while (n != 0) : (n -= 1) {
                var loaded: u32 = undefined;
                @memcpy(std.mem.asBytes(&loaded), src_);
                loaded ^= mask;
                @memcpy(src_ - destination, std.mem.asBytes(&loaded));
                src_ += 4;
            }
        }

        inline fn unmaskImpreciseCopyMask(comptime header_size: u32, src: []u8) void {
            const src_ = src.ptr;
            if (comptime header_size != 6) {
                const mask = [_]u8{ (src_ - 4)[0], (src_ - 3)[0], (src_ - 2)[0], (src_ - 1)[0], (src_ - 4)[0], (src_ - 3)[0], (src_ - 2)[0], (src_ - 1)[0] };
                var mask_int: u64 = undefined;
                @memcpy(std.mem.asBytes(&mask_int), &mask);
                unmaskImprecise8(header_size, src, mask_int);
            } else {
                const mask = [_]u8{ (src_ - 4)[0], (src_ - 3)[0], (src_ - 2)[0], (src_ - 1)[0] };
                var mask_int: u32 = undefined;
                @memcpy(std.mem.asBytes(&mask_int), &mask);
                unmaskImprecise4(header_size, src, mask_int);
            }
        }

        inline fn rotateMask(offset: u32, mask: []u8) void {
            const original_mask = [_]u8{ mask[0], mask[1], mask[2], mask[3] };
            mask[(0 + offset) % 4] = original_mask[0];
            mask[(1 + offset) % 4] = original_mask[1];
            mask[(2 + offset) % 4] = original_mask[2];
            mask[(3 + offset) % 4] = original_mask[3];
        }

        inline fn unmaskInplace(data: [*]u8, stop: [*]u8, mask: []u8) void {
            var data_ = data;
            while (@intFromPtr(data_) < @intFromPtr(stop)) {
                data_[0] ^= mask[0];
                data_ += 1;
                data_[0] ^= mask[1];
                data_ += 1;
                data_[0] ^= mask[2];
                data_ += 1;
                data_[0] ^= mask[3];
                data_ += 1;
            }
        }

        fn consumeMessage(allocator: std.mem.Allocator, io: std.Io, comptime message_header: u32, comptime T: type, pay_length: T, src: *[*]u8, length: *usize, w_state: *WebSocketState(is_server), user: ?*anyopaque) !bool {
            if (getOpCode(src.*) != 0) {
                if (w_state.state.op_stack == 1 or (!w_state.state.last_fin and getOpCode(src.*) < 2)) {
                    try Impl.forceClose(allocator, io, w_state, user, err_protocol);
                    return true;
                }
                w_state.state.op_stack += 1;
                w_state.state.op_code[@intCast(w_state.state.op_stack)] = @enumFromInt(getOpCode(src.*));
            } else if (w_state.state.op_stack == -1) {
                try Impl.forceClose(allocator, io, w_state, user, err_protocol);
                return true;
            }
            w_state.state.last_fin = isFin(src.*);

            if (Impl.refusePayloadLength(pay_length, w_state, user)) {
                try Impl.forceClose(allocator, io, w_state, user, err_too_big_message);
                return true;
            }

            if (pay_length + message_header <= length.*) {
                const fin = isFin(src.*);
                if (comptime is_server) {
                    unmaskImpreciseCopyMask(message_header, src.*[message_header .. message_header + pay_length]);
                    if (try Impl.handleFragment(allocator, io, src.*[0..pay_length], 0, @intFromEnum(w_state.state.op_code[@intCast(w_state.state.op_stack)]), fin, w_state, user)) {
                        return true;
                    }
                } else {
                    if (try Impl.handleFragment(allocator, io, (src.* + message_header)[0..pay_length], 0, @intFromEnum(w_state.state.op_code[@intCast(w_state.state.op_stack)]), isFin(src.*), w_state, user)) {
                        return true;
                    }
                }

                if (fin) {
                    w_state.state.op_stack -= 1;
                }

                src.* += pay_length + message_header;
                length.* -= pay_length + message_header;
                w_state.state.spill_length = 0;
                return false;
            } else {
                w_state.state.spill_length = 0;
                w_state.state.wants_head = false;
                w_state.remaining_bytes = @intCast(pay_length - length.* + message_header);
                const fin = isFin(src.*);
                if (comptime is_server) {
                    @memcpy(&w_state.mask, src.* + message_header);
                    var mask: u64 = undefined;
                    @memcpy(std.mem.asBytes(&mask)[0..4], src.* + message_header - 4);
                    @memcpy(std.mem.asBytes(&mask)[4..], src.* + message_header - 4);
                    unmaskImprecise8(0, (src.* + message_header)[0..length.*], mask);
                    rotateMask(4 - (@as(u32, @intCast(length.*)) - message_header) % 4, &w_state.mask);
                }
                _ = try Impl.handleFragment(allocator, io, (src.* + message_header)[0 .. length.* - message_header], w_state.remaining_bytes, @intFromEnum(w_state.state.op_code[@intCast(w_state.state.op_stack)]), fin, w_state, user);
                return true;
            }
        }

        inline fn unmaskAll(noalias data: []u8, noalias mask: []u8) void {
            var i: usize = 0;
            while (i < zs.constants.recv_buffer_length) : (i += 16) {
                unrolledXor(16, data[i..], mask);
            }
        }

        fn consumeContinuation(allocator: std.mem.Allocator, io: std.Io, src: *[*]u8, length: *usize, w_state: *WebSocketState(is_server), user: ?*anyopaque) !bool {
            if (w_state.remaining_bytes <= length.*) {
                if (comptime is_server) {
                    const n = w_state.remaining_bytes >> 2;
                    unmaskInplace(src.*, src.* + (n * 4), &w_state.mask);
                    for (0..w_state.remaining_bytes % 4) |i| {
                        src.*[n * 4 + i] ^= w_state.mask[i];
                    }
                }
                if (try Impl.handleFragment(allocator, io, src.*[0..w_state.remaining_bytes], 0, @intCast(@intFromEnum(w_state.state.op_code[@intCast(w_state.state.op_stack)])), w_state.state.last_fin, w_state, user)) {
                    return false;
                }
                if (w_state.state.last_fin) {
                    w_state.state.op_stack -= 1;
                }
                src.* += w_state.remaining_bytes;
                length.* -= w_state.remaining_bytes;
                w_state.state.wants_head = true;
                return true;
            } else {
                if (comptime is_server) {
                    const null_mask: u32 = 0;
                    if (!std.mem.eql(u8, &w_state.mask, std.mem.asBytes(&null_mask))) {
                        if (zs.constants.recv_buffer_length == length.*) {
                            unmaskAll(src.*[0..length.*], &w_state.mask);
                        } else {
                            unmaskInplace(src.*, src.* + ((length.* >> 2) + 1) * 4, &w_state.mask);
                        }
                    }
                }
                w_state.remaining_bytes -= @intCast(length.*);
                if (try Impl.handleFragment(allocator, io, src.*[0..length.*], w_state.remaining_bytes, @intFromEnum(w_state.state.op_code[@intCast(w_state.state.op_stack)]), w_state.state.last_fin, w_state, user)) {
                    return false;
                }

                if (is_server and (length.* % 4) != 0) {
                    rotateMask(@intCast(4 - (length.* % 4)), &w_state.mask);
                }
                return false;
            }
        }

        pub fn init() Self {
            return .{};
        }

        pub fn consume(allocator: std.mem.Allocator, io: std.Io, src: []u8, w_state: *WebSocketState(is_server), user: ?*anyopaque) !void {
            var src_ = src.ptr;
            var length = src.len;
            if (w_state.state.spill_length != 0) {
                src_ -= w_state.state.spill_length;
                length += w_state.state.spill_length;
                @memcpy(src_, w_state.state.spill[0..w_state.state.spill_length]);
            }
            if (w_state.state.wants_head or try consumeContinuation(allocator, io, &src_, &length, w_state, user)) {
                while (length >= short_message_header) {
                    if ((rsv1(src_) and !Impl.setCompressed(w_state, user)) or rsv23(src_) or (getOpCode(src_) > 2 and getOpCode(src_) < 8) or
                        getOpCode(src_) > 10 or (getOpCode(src_) > 2 and (!isFin(src_) or payloadLength(src_) > 125)))
                    {
                        try Impl.forceClose(allocator, io, w_state, user, err_protocol);
                        return;
                    }
                    if (payloadLength(src_) < 126) {
                        if (try consumeMessage(allocator, io, short_message_header, u8, payloadLength(src_), &src_, &length, w_state, user)) {
                            return;
                        }
                    } else if (payloadLength(src_) == 126) {
                        if (length < medium_message_header) {
                            break;
                        } else if (try consumeMessage(allocator, io, medium_message_header, u16, std.mem.nativeToBig(u16, Protocol.bitCast(u16, (src_ + 2)[0..@sizeOf(u16)])), &src_, &length, w_state, user)) {
                            return;
                        }
                    } else if (length < long_message_header) {
                        break;
                    } else if (try consumeMessage(allocator, io, long_message_header, u64, std.mem.nativeToBig(u64, Protocol.bitCast(u64, (src_ + 2)[0..@sizeOf(u64)])), &src_, &length, w_state, user)) {
                        return;
                    }
                }
                if (length != 0) {
                    @memcpy(&w_state.state.spill, src_[0..length]);
                    w_state.state.spill_length = @intCast(length & 0xf);
                }
            }
        }
    };
}
