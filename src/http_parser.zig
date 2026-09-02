const env = @import("env");
const chunked_encoding = @import("chunked_encoding.zig");
const std = @import("std");

const getDecodedQueryValue = @import("query_parser.zig").getDecodedQueryValue;
const BloomFilter = @import("bloom_filter.zig");
const Lambda = @import("lambda.zig").Lambda;
const ProxyParser = @import("proxy_parser.zig").ProxyParser;
const HttpErrors = @import("http_errors.zig").HttpErrors;

const state_is_chunked = chunked_encoding.state_is_chunked;
const isParsingChunkedEncoding = chunked_encoding.isParsingChunkedEncoding;
const isParsingInvalidChunkedEncoding = chunked_encoding.isParsingInvalidChunkedEncoding;
const ChunkIterator = chunked_encoding.ChunkIterator;

pub const minimum_http_post_padding = 32;
pub const full_ptr: ?*anyopaque = @ptrFromInt(~@as(usize, 0));

pub const max_fallback_size = env.http_max_headers_size;

pub const HttpRequest = struct {
    pub const Header = struct {
        key: []const u8,
        value: []const u8,
    };

    pub const HeaderIterator = struct {
        ptr: ?*Header,

        pub fn notEql(self: *const HeaderIterator, other: *const HeaderIterator) bool {
            if (self.ptr != other.ptr) {
                return other.ptr != null or self.ptr.?.key.len != 0;
            }
            return false;
        }

        pub fn next(self: *HeaderIterator) HeaderIterator {
            self.ptr = @ptrCast(@alignCast(@as([*]Header, @ptrCast(@alignCast(self.ptr))) + 1));
            return self.*;
        }
    };

    pub const max_headers_size = env.http_max_headers_size;

    headers: [env.http_max_headers_count]Header = @splat(.{ .key = &.{}, .value = &.{} }),
    ancient_http: bool = false,
    query_separator: u32 = 0,
    did_yield: bool = false,
    bf: BloomFilter = .empty,
    current_parameters: struct { i32, [*][]const u8 } = undefined,
    current_parameters_offset: ?*std.StringHashMapUnmanaged(u16) = null,

    pub fn isAncient(self: *const HttpRequest) bool {
        return self.ancient_http;
    }

    pub fn getYield(self: *const HttpRequest) bool {
        return self.did_yield;
    }

    pub fn begin(self: *HttpRequest) HeaderIterator {
        return .{ .ptr = &self.headers[1] };
    }

    pub fn end(_: *const HttpRequest) HeaderIterator {
        return .{ .ptr = null };
    }

    pub fn setYield(self: *HttpRequest, yield: bool) void {
        self.did_yield = yield;
    }

    pub fn getHeader(self: *HttpRequest, lower_cased_header: []const u8) ?[]const u8 {
        if (self.bf.mightHave(lower_cased_header)) {
            for (self.headers[1..]) |h| {
                if (h.key.len == 0) break;
                if (h.key.len == lower_cased_header.len and std.mem.eql(u8, h.key, lower_cased_header)) {
                    return h.value;
                }
            }
        }
        return null;
    }

    pub fn getUrl(self: *HttpRequest) []const u8 {
        return self.headers[0].value[0..self.query_separator];
    }

    pub fn getFullUrl(self: *HttpRequest) []const u8 {
        return self.headers[0].value;
    }

    pub fn getCaseSensitiveMethod(self: *HttpRequest) []const u8 {
        return self.headers[0].key;
    }

    pub fn getMethod(self: *HttpRequest) []const u8 {
        for (0..self.headers[0].key.len) |i| {
            @as([]u8, @constCast(self.headers[0].key))[i] |= 32;
        }
        return self.headers[0].key;
    }

    pub fn getQuery(self: *const HttpRequest) ?[]const u8 {
        if (self.query_separator < self.headers[0].value.len) {
            return self.headers[0].value[self.query_separator + 1 ..];
        } else {
            return null;
        }
    }

    pub fn getQueryValue(self: *const HttpRequest, key: []const u8) ?[]const u8 {
        return getDecodedQueryValue(key, self.headers[0].value[self.query_separator + 1 ..]);
    }

    pub fn setParameters(self: *HttpRequest, parameters: struct { i32, *[]const u8 }) void {
        self.current_parameters = parameters;
    }

    pub fn setParameterOffsets(self: *HttpRequest, offsets: *std.StringHashMapUnmanaged(u16)) void {
        self.current_parameters_offset = offsets;
    }

    pub fn getParameter(self: *HttpRequest, name: []const u8) ?[]const u8 {
        if (self.current_parameters_offset) |cpo| {
            if (cpo.find(name)) |it| {
                return getParameterByIndex(it[1]);
            } else return null;
        } else return null;
    }

    pub fn getParameterByIndex(self: *HttpRequest, index: u16) ?[]const u8 {
        if (self.current_parameters[0] < @as(i32, @intCast(index))) {
            return null;
        } else {
            return self.current_parameters[1][index];
        }
    }
};

pub const HttpParser = struct {
    fallback: std.ArrayList(u8) = .empty,
    remaining_streaming_bytes: usize = 0,

    const empty: HttpParser = .{};

    pub fn deinit(self: *HttpParser, allocator: std.mem.Allocator) void {
        self.fallback.deinit(allocator);
    }

    fn toUnsignedInteger(str: []const u8) u64 {
        if (str.len > 18) {
            return std.math.maxInt(u64);
        }

        var unsigned_integer_value: u64 = 0;
        for (str) |c| {
            if (c < '0' or c > '9') {
                return std.math.maxInt(u64);
            }
            unsigned_integer_value = unsigned_integer_value * 10 + (@as(u64, @intCast(c)) - '0');
        }
        return unsigned_integer_value;
    }

    inline fn hasLess(x: u64, n: u64) u64 {
        return (((x) -% ~@as(u64, 0) / 255 * (n)) & ~(x) & ~@as(u64, 0) / 255 * 128);
    }

    inline fn hasMore(x: u64, n: u64) u64 {
        return ((((x) + ~@as(u64, 0) / 255 * (127 - (n))) | (x)) & ~@as(u64, 0) / 255 * 128);
    }

    inline fn hasBetween(x: u64, m: u64, n: u64) u64 {
        return (((~@as(u64, 0) / 255 * (127 + (n)) - ((x) & ~@as(u64, 0) / 255 * 127)) & ~(x) & (((x) & ~@as(u64, 0) / 255 * 127) + ~@as(u64, 0) / 255 * (127 - (m)))) & ~@as(u64, 0) / 255 * 128);
    }

    inline fn notFieldNameWord(x: u64) bool {
        return hasLess(x, '-') |
            hasBetween(x, '-', '0') |
            hasBetween(x, '9', 'A') |
            hasBetween(x, 'Z', 'a') |
            hasMore(x, 'z');
    }

    inline fn isUnlikelyFieldNameByte(c: u8) bool {
        return ((c == '~') | (c == '|') | (c == '`') | (c == '_') | (c == '^') | (c == '.') | (c == '+') | (c == '*') | (c == '!')) or ((c >= 48) & (c <= 57)) or ((c <= 39) & (c >= 35));
    }

    inline fn isFieldNameByteFastLowercased(in: *u8) bool {
        if (((in.* >= 97) & (in.* <= 122)) | (in.* == '-')) {
            @branchHint(.likely);
            return true;
        } else if ((in.* >= 65) & (in.* <= 90)) {
            @branchHint(.unlikely);
            in.* |= 32;
            return true;
        } else if (isUnlikelyFieldNameByte(in.*)) {
            @branchHint(.unlikely);
            return true;
        }
        return false;
    }

    inline fn consumeFieldName(p: [*]u8) ?*anyopaque {
        var p_ = p;
        while (true) {
            while ((p_[0] >= 65) & (p_[0] <= 90)) {
                @branchHint(.likely);
                p_[0] |= 32;
                p_ += 1;
            }
            while (((p_[0] >= 97) & (p_[0] <= 122))) {
                @branchHint(.likely);
                p_ += 1;
            }
            if (p_[0] == ':') {
                return @ptrCast(@alignCast(p_));
            }
            if (p_[0] == '-') {
                p_ += 1;
            } else if (!((p_[0] >= 65) & (p_[0] <= 90))) {
                break;
            }
        }

        while (isFieldNameByteFastLowercased(&p_[0])) {
            p_ += 1;
        }
        return @ptrCast(@alignCast(p_));
    }

    inline fn consumeRequestLine(data: [*]u8, end: [*]u8, header: *HttpRequest.Header) ?[*]u8 {
        var data_ = data;
        var start = data_;
        while (data_[0] > 32) data_ += 1;
        if (@intFromPtr(&data_[1]) == @intFromPtr(end)) {
            @branchHint(.unlikely);
            return null;
        }
        if (data_[0] == 32 and data_[1] == '/') {
            @branchHint(.likely);
            header.key = start[0 .. @intFromPtr(data_) - @intFromPtr(start)];
            data_ += 1;
            start = data_;
            while (true) : (data_ += 8) {
                var word: u64 = undefined;
                @memcpy(std.mem.asBytes(&word), data_);
                if (hasLess(word, 33) != 0) {
                    while (data_[0] > 32) data_ += 1;
                    header.value = start[0 .. @intFromPtr(data_) - @intFromPtr(start)];
                    if (@intFromPtr(data_ + 11) >= @intFromPtr(end)) {
                        if (std.mem.eql(u8, " HTTP/1.1\r\n", data_[0..@min(11, @intFromPtr(end) - @intFromPtr(data_))])) {
                            return null;
                        }
                        return @ptrFromInt(0x1);
                    }
                    if (std.mem.eql(u8, " HTTP/1.1\r\n", data_[0..11])) {
                        return data_ + 11;
                    }
                    if (data_[0] == '\r') {
                        return null;
                    }
                    return @ptrFromInt(0x1);
                }
            }
        }
        if (data_[0] == '\r') {
            return null;
        }
        return @ptrFromInt(0x1);
    }

    inline fn tryConsumeFieldValue(p: [*]u8) ?*anyopaque {
        var p_ = p;
        while (true) : (p_ += 8) {
            var word: u64 = undefined;
            @memcpy(std.mem.asBytes(&word), p_);
            if (hasLess(word, 32) != 0) {
                while (p_[0] > 31) p_ += 1;
                return @ptrCast(@alignCast(p_));
            }
        }
    }

    // TODO: can probably just use zig error handling here
    fn getHeaders(post_padded_buffer: [*]u8, end: [*]u8, headers: [*]HttpRequest.Header, reserved: ?*anyopaque, err: *u32) u32 {
        var post_padded_buffer_ = post_padded_buffer;
        var headers_ = headers;
        var preliminary_key: [*]u8 = undefined;
        var preliminary_value: [*]u8 = undefined;
        const start = post_padded_buffer_;
        if (env.with_proxy) {
            var pp: *ProxyParser = @ptrCast(@alignCast(reserved));
            const done, const offset = pp.parse(post_padded_buffer_[0 .. @intFromPtr(end) - @intFromPtr(post_padded_buffer_)]);
            if (!done) {
                return 0;
            } else {
                post_padded_buffer_ += offset;
            }
        }

        if (consumeRequestLine(post_padded_buffer_, end, &headers_[0])) |ppb| {
            post_padded_buffer_ = ppb;
        } else return 0;
        if (2 > @intFromPtr(post_padded_buffer_)) {
            return @intFromEnum(HttpErrors.@"505_http_version_not_supported");
        }
        headers_ += 1;
        for (1..env.http_max_headers_count - 1) |_| {
            preliminary_key = post_padded_buffer_;
            post_padded_buffer_ = @ptrCast(@alignCast(consumeFieldName(post_padded_buffer_)));
            headers_[0].key = preliminary_key[0 .. @intFromPtr(post_padded_buffer_) - @intFromPtr(preliminary_key)];
            if (post_padded_buffer_[0] != ':') {
                if (post_padded_buffer_ == end) {
                    return 0;
                }
                err.* = @intFromEnum(HttpErrors.@"400_bad_request");
                return 0;
            }
            post_padded_buffer_ += 1;

            preliminary_value = post_padded_buffer_;
            while (true) {
                post_padded_buffer_ = @ptrCast(@alignCast(tryConsumeFieldValue(post_padded_buffer_)));
                if (post_padded_buffer_[0] != '\r') {
                    if (post_padded_buffer_[0] == '\t') {
                        post_padded_buffer_ += 1;
                        continue;
                    }
                    err.* = @intFromEnum(HttpErrors.@"400_bad_request");
                    return 0;
                }
                break;
            }
            if (post_padded_buffer_[1] == '\n') {
                headers_[0].value = preliminary_value[0 .. @intFromPtr(post_padded_buffer_) - @intFromPtr(preliminary_value)];
                post_padded_buffer_ += 2;
                while (headers_[0].value.len != 0 and headers_[0].value[headers_[0].value.len - 1] < 33) {
                    headers_[0].value = headers_[0].value[0 .. headers_[0].value.len - 1];
                }
                while (headers_[0].value.len != 0 and headers_[0].value[0] < 33) {
                    headers_[0].value = headers_[0].value[1..];
                }
                headers_ += 1;
                if (post_padded_buffer_[0] == '\r') {
                    if (post_padded_buffer_[1] == '\n') {
                        // TODO: might need to allow key to be null
                        headers_[0].key = &.{};
                        return @intCast(((post_padded_buffer_ + 2) - start));
                    } else {
                        if (@intFromPtr(post_padded_buffer_ + 1) < @intFromPtr(end)) {
                            err.* = @intFromEnum(HttpErrors.@"400_bad_request");
                        }
                        return 0;
                    }
                }
            } else {
                return 0;
            }
        }
        err.* = @intFromEnum(HttpErrors.@"431_request_header_fields_too_large");
        return 0;
    }

    // TODO: find workaround for zig's lack of lambda support
    fn fenceAndConsumePostPadded(
        self: *HttpParser,
        allocator: std.mem.Allocator,
        comptime consume_minimally: bool,
        data: [*]u8,
        length: u32,
        user: ?*anyopaque,
        reserved: ?*anyopaque,
        req: *HttpRequest,
        request_handler_context: anytype,
        request_handler: *const fn (std.mem.Allocator, @TypeOf(request_handler_context), ?*anyopaque, *HttpRequest) anyerror!?*anyopaque,
        data_handler_context: anytype,
        data_handler: *const fn (std.mem.Allocator, @TypeOf(data_handler_context), ?*anyopaque, []const u8, u64) anyerror!?*anyopaque,
    ) !struct { u32, ?*anyopaque } {
        var consumed_total: u32 = 0;
        var err: u32 = 0;

        var data_ = data;
        var length_ = length;

        data_[length_] = '\r';
        data_[length_ + 1] = 'a';
        var consumed = getHeaders(data_, data_ + length_, &req.headers, reserved, &err);
        while (length_ != 0 and consumed != 0) : (consumed = getHeaders(data_, data_ + length_, &req.headers, reserved, &err)) {
            data_ += consumed;
            length_ -= consumed;
            consumed_total += consumed;

            if (consumed > max_fallback_size) {
                return .{ @intFromEnum(HttpErrors.@"431_request_header_fields_too_large"), full_ptr };
            }

            req.ancient_http = false;

            req.bf.reset();
            var h: [*]HttpRequest.Header = &req.headers;
            h += 1;
            while (h[0].key.len != 0) : (h += 1) {
                if (req.bf.mightHave(h[0].key)) {
                    @branchHint(.unlikely);
                    if (std.mem.eql(u8, h[0].key, "host") and req.getHeader("host") != null) {
                        return .{ @intFromEnum(HttpErrors.@"400_bad_request"), full_ptr };
                    }
                }
                req.bf.add(h[0].key);
            }

            if (req.getHeader("host") == null) {
                return .{ @intFromEnum(HttpErrors.@"400_bad_request"), full_ptr };
            }

            const transfer_encoding_string = req.getHeader("transfer-encoding");
            const content_length_string = req.getHeader("content-length");
            if (transfer_encoding_string != null and content_length_string != null) {
                return .{ @intFromEnum(HttpErrors.@"400_bad_request"), full_ptr };
            }

            if (std.mem.findScalar(u8, req.headers[0].value, '?')) |query_separator_index| {
                req.query_separator = @intCast(query_separator_index);
            } else {
                req.query_separator = @intCast(req.headers[0].value.len);
            }

            const returned_user = try request_handler(allocator, request_handler_context, user, req);
            if (returned_user != user) {
                return .{ consumed_total, returned_user };
            }

            if (transfer_encoding_string) |_| {
                self.remaining_streaming_bytes = state_is_chunked;
                if (!consume_minimally) {
                    var data_to_consume = data_[0..length_];
                    var chunk_iterator = ChunkIterator.init(@ptrCast(&data_to_consume), &self.remaining_streaming_bytes, false);
                    while (chunk_iterator.next()) |chunk| {
                        _ = try data_handler(allocator, data_handler_context, user, chunk, if (chunk.len != 0) std.math.maxInt(u64) else 0);
                    }
                    if (isParsingInvalidChunkedEncoding(self.remaining_streaming_bytes)) {
                        return .{ @intFromEnum(HttpErrors.@"400_bad_request"), full_ptr };
                    }
                    data_ = data_to_consume.ptr;
                    length_ = @intCast(data_to_consume.len);
                    consumed_total += length_ - @as(u32, @intCast(data_to_consume.len));
                }
            } else if (content_length_string) |cls| {
                self.remaining_streaming_bytes = toUnsignedInteger(cls);
                if (self.remaining_streaming_bytes == std.math.maxInt(u64)) {
                    return .{ @intFromEnum(HttpErrors.@"400_bad_request"), full_ptr };
                }
                if (!consume_minimally) {
                    const emittable = @min(self.remaining_streaming_bytes, length_);
                    _ = try data_handler(allocator, data_handler_context, user, data_[0..emittable], self.remaining_streaming_bytes - emittable);
                    self.remaining_streaming_bytes -= emittable;
                    data_ += emittable;
                    length_ -= emittable;
                    consumed_total += emittable;
                }
            } else {
                _ = try data_handler(allocator, data_handler_context, user, &.{}, 0);
            }

            if (consume_minimally) {
                break;
            }
        }
        if (err != 0) {
            return .{ err, full_ptr };
        }
        return .{ consumed_total, user };
    }

    pub fn consumePostPadded(
        self: *HttpParser,
        allocator: std.mem.Allocator,
        data: [*]u8,
        length: u32,
        user: ?*anyopaque,
        reserved: ?*anyopaque,
        request_handler_context: anytype,
        request_handler: *const fn (std.mem.Allocator, @TypeOf(request_handler_context), ?*anyopaque, *HttpRequest) anyerror!?*anyopaque,
        data_handler_context: anytype,
        data_handler: *const fn (std.mem.Allocator, @TypeOf(data_handler_context), ?*anyopaque, []const u8, u64) anyerror!?*anyopaque,
    ) !struct { u32, ?*anyopaque } {
        var data_ = data;
        var length_ = length;
        var req: HttpRequest = .{};

        if (self.remaining_streaming_bytes != 0) {
            if (isParsingChunkedEncoding(self.remaining_streaming_bytes)) {
                var data_to_consume = data_[0..length_];
                var chunk_iterator = ChunkIterator.init(@ptrCast(&data_to_consume), &self.remaining_streaming_bytes, false);
                while (chunk_iterator.next()) |chunk| {
                    _ = try data_handler(allocator, data_handler_context, user, chunk, if (chunk.len != 0) std.math.maxInt(u64) else 0);
                }
                if (isParsingInvalidChunkedEncoding(self.remaining_streaming_bytes)) {
                    return .{ @intFromEnum(HttpErrors.@"400_bad_request"), full_ptr };
                }
                data_ = data_to_consume.ptr;
                length_ = @intCast(data_to_consume.len);
            } else {
                if (self.remaining_streaming_bytes >= length_) {
                    const returned_user = try data_handler(allocator, data_handler_context, user, data_[0..length_], self.remaining_streaming_bytes - length_);
                    self.remaining_streaming_bytes -= length_;
                    return .{ 0, returned_user };
                } else {
                    const returned_user = try data_handler(allocator, data_handler_context, user, data_[0..self.remaining_streaming_bytes], 0);
                    data_ += self.remaining_streaming_bytes;
                    length_ -= @intCast(self.remaining_streaming_bytes);
                    self.remaining_streaming_bytes = 0;
                    if (returned_user != user) {
                        return .{ 0, returned_user };
                    }
                }
            }
        } else if (self.fallback.items.len != 0) {
            const had: u32 = @intCast(self.fallback.items.len);
            const max_copy_distance = @min(max_fallback_size - self.fallback.items.len, length_);
            // TODO: `@sizeOf(std.ArrayList(u8))` just feels wrong lol
            try self.fallback.ensureTotalCapacity(allocator, self.fallback.items.len + max_copy_distance + @max(minimum_http_post_padding, @sizeOf(std.ArrayList(u8))));
            self.fallback.appendSliceAssumeCapacity(data_[0..max_copy_distance]);

            const consumed = try self.fenceAndConsumePostPadded(allocator, true, self.fallback.items.ptr, @intCast(self.fallback.items.len), user, reserved, &req, request_handler_context, request_handler, data_handler_context, data_handler);
            if (consumed[1] != user) {
                return consumed;
            }
            if (consumed[0] != 0) {
                self.fallback.clearRetainingCapacity();
                data_ += consumed[0] - had;
                length_ -= consumed[0] - had;
                if (self.remaining_streaming_bytes != 0) {
                    if (isParsingChunkedEncoding(self.remaining_streaming_bytes)) {
                        var data_to_consume = data_[0..length_];
                        var chunk_iterator = ChunkIterator.init(@ptrCast(&data_to_consume), &self.remaining_streaming_bytes, false);
                        while (chunk_iterator.next()) |chunk| {
                            _ = try data_handler(allocator, data_handler_context, user, chunk, if (chunk.len != 0) std.math.maxInt(u64) else 0);
                        }
                        if (isParsingInvalidChunkedEncoding(self.remaining_streaming_bytes)) {
                            return .{ @intFromEnum(HttpErrors.@"400_bad_request"), full_ptr };
                        }
                        data_ = data_to_consume.ptr;
                        length_ = @intCast(data_to_consume.len);
                    } else {
                        if (self.remaining_streaming_bytes >= length_) {
                            const returned_user = try data_handler(allocator, data_handler_context, user, data_[0..length_], self.remaining_streaming_bytes - length_);
                            self.remaining_streaming_bytes -= length_;
                            return .{ 0, returned_user };
                        } else {
                            const returned_user = try data_handler(allocator, data_handler_context, user, data_[0..self.remaining_streaming_bytes], 0);
                            data_ += self.remaining_streaming_bytes;
                            length_ -= @intCast(self.remaining_streaming_bytes);
                            self.remaining_streaming_bytes = 0;
                            if (returned_user != user) {
                                return .{ 0, returned_user };
                            }
                        }
                    }
                }
            } else {
                if (self.fallback.items.len == max_fallback_size) {
                    return .{ @intFromEnum(HttpErrors.@"431_request_header_fields_too_large"), full_ptr };
                }
                return .{ 0, user };
            }
        }

        const consumed = try self.fenceAndConsumePostPadded(allocator, false, data_, length_, user, reserved, &req, request_handler_context, request_handler, data_handler_context, data_handler);
        if (consumed[1] != user) {
            return consumed;
        }
        data_ += consumed[0];
        length_ -= consumed[0];
        if (length_ != 0) {
            if (length_ < max_fallback_size) {
                self.fallback.appendSliceAssumeCapacity(data_[0..length_]);
            } else {
                return .{ @intFromEnum(HttpErrors.@"431_request_header_fields_too_large"), full_ptr };
            }
        }
        return .{ 0, user };
    }
};

test "Http Parser" {
    const allocator = std.testing.allocator;
    var data = [_]u8{ 0x47, 0x45, 0x54, 0x20, 0x2f, 0x20, 0x48, 0x54, 0x54, 0x50, 0x2f, 0x31, 0x2e, 0x31, 0xd, 0xa, 0x61, 0x73, 0x63, 0x69, 0x69, 0x3a, 0x20, 0x74, 0x65, 0x73, 0x74, 0xd, 0xa, 0x75, 0x74, 0x66, 0x38, 0x3a, 0x20, 0xd1, 0x82, 0xd0, 0xb5, 0xd1, 0x81, 0xd1, 0x82, 0xd, 0xa, 0x48, 0x6f, 0x73, 0x74, 0x3a, 0x20, 0x31, 0x32, 0x37, 0x2e, 0x30, 0x2e, 0x30, 0x2e, 0x31, 0xd, 0xa, 0x43, 0x6f, 0x6e, 0x6e, 0x65, 0x63, 0x74, 0x69, 0x6f, 0x6e, 0x3a, 0x20, 0x63, 0x6c, 0x6f, 0x73, 0x65, 0xd, 0xa, 0xd, 0xa, 'E', 'E', 'E', 'E', 'E', 'E', 'E', 'E' };
    const size = @sizeOf(@TypeOf(data)) - 8;
    const user: ?*anyopaque = null;
    const reserved: ?*anyopaque = null;

    var http_parser: HttpParser = .{};

    const request_handler = (struct {
        pub fn call(_: std.mem.Allocator, _: ?*anyopaque, s: ?*anyopaque, http_request: *HttpRequest) !?*anyopaque {
            try std.testing.expectEqualStrings("get", http_request.getMethod());
            // for (&http_request.headers) |hdr| {
            //     std.debug.print("{s}: {s}\n", .{ hdr.key, hdr.value });
            // }
            try std.testing.expect(http_request.getHeader("utf8") != null);
            return s;
        }
    }).call;

    const data_handler = (struct {
        pub fn call(_: std.mem.Allocator, _: void, _: ?*anyopaque, _: []const u8, _: u64) !?*anyopaque {
            return user;
        }
    }).call;

    _ = try http_parser.consumePostPadded(allocator, &data, size, user, reserved, reserved, request_handler, {}, data_handler);
}
