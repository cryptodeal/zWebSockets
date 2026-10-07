const env = @import("env");
const libdeflate = @import("libdeflate");
const std = @import("std");
const zlib = @import("zlib");

pub const CompressOptions = enum(u16) {
    pub const compressor_mask: u16 = 0x00FF;
    pub const decompressor_mask: u16 = 0x0F00;
    pub const dedicated_decompressor: u16 = 15 << 8;
    pub const dedicated_compressor: u16 = 15 << 4 | 8;

    disabled = 0,
    shared_compressor = 1,
    shared_decompressor = 1 << 8,
    dedicated_decompressor_32kb = 15 << 8,
    dedicated_decompressor_16kb = 14 << 8,
    dedicated_decompressor_8kb = 13 << 8,
    dedicated_decompressor_4kb = 12 << 8,
    dedicated_decompressor_2kb = 11 << 8,
    dedicated_decompressor_1kb = 10 << 8,
    dedicated_decompressor_512b = 9 << 8,
    dedicated_compressor_3kb = 9 << 4 | 1,
    dedicated_compressor_4kb = 9 << 4 | 2,
    dedicated_compressor_8kb = 10 << 4 | 3,
    dedicated_compressor_16kb = 11 << 4 | 4,
    dedicated_compressor_32kb = 12 << 4 | 5,
    dedicated_compressor_64kb = 13 << 4 | 6,
    dedicated_compressor_128kb = 14 << 4 | 7,
    dedicated_compressor_256kb = 15 << 4 | 8,
    _,
};

const large_buffer_size = 1024 * 16;

pub const ZlibContext = switch (!env.with_zlib or env.mock_zlib) {
    true => struct {
        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) !*Self {
            return allocator.create(Self);
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            allocator.destroy(self);
        }
    },
    else => struct {
        const Self = @This();

        dynamic_deflation_buffer: std.ArrayList(u8) = .empty,
        dynamic_inflation_buffer: std.ArrayList(u8) = .empty,
        deflation_buffer: []u8,
        inflation_buffer: []u8,
        decompressor: if (env.with_libdeflate) *libdeflate.libdeflate_decompressor else void = undefined,
        compressor: if (env.with_libdeflate) *libdeflate.libdeflate_compressor else void = undefined,

        pub fn init(allocator: std.mem.Allocator) !*Self {
            const self = try allocator.create(Self);
            self.* = .{
                .deflation_buffer = try allocator.alloc(u8, large_buffer_size),
                .inflation_buffer = try allocator.alloc(u8, large_buffer_size),
            };
            if (env.with_libdeflate) {
                self.decompressor = libdeflate.libdeflate_alloc_decompressor();
                self.compressor = libdeflate.libdeflate_alloc_compressor(6);
            }
            return self;
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.dynamic_deflation_buffer.deinit(allocator);
            self.dynamic_inflation_buffer.deinit(allocator);
            allocator.free(self.deflation_buffer);
            allocator.free(self.inflation_buffer);
            if (env.with_libdeflate) {
                libdeflate.libdeflate_free_decompressor(self.decompressor);
                libdeflate.libdeflate_free_compressor(self.compressor);
            }
            allocator.destroy(self);
        }
    },
};

pub const DeflationStream = switch (!env.with_zlib or env.mock_zlib) {
    true => struct {
        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, _: CompressOptions) !*Self {
            return allocator.create(Self);
        }

        pub fn deflate(_: *Self, _: std.mem.Allocator, _: *ZlibContext, raw: []const u8, _: bool) ![]u8 {
            return raw;
        }
    },
    else => struct {
        const Self = @This();

        deflation_stream: zlib.z_stream = .{},

        pub fn init(allocator: std.mem.Allocator, compress_options: CompressOptions) !*Self {
            const self = try allocator.create(Self);
            self.* = .{};
            const window_bits = -@as(c_int, @intCast(((@intFromEnum(compress_options) & CompressOptions.compressor_mask) >> 4)));
            const mem_level: c_int = @intCast(@intFromEnum(compress_options) & 0xF);
            _ = zlib.deflateInit2(@as([*c]zlib.z_stream, @ptrCast(@alignCast(&self.deflation_stream))), zlib.Z_DEFAULT_COMPRESSION, zlib.Z_DEFLATED, window_bits, mem_level, zlib.Z_DEFAULT_STRATEGY);
            return self;
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            _ = zlib.deflateEnd(@ptrCast(@alignCast(&self.deflation_stream)));
            allocator.destroy(self);
        }

        pub fn deflate(self: *Self, allocator: std.mem.Allocator, zlib_context: *ZlibContext, raw: []const u8, reset: bool) ![]u8 {
            zlib_context.dynamic_deflation_buffer.clearRetainingCapacity();
            self.deflation_stream.next_in = @ptrCast(@alignCast(@constCast(raw.ptr)));
            self.deflation_stream.avail_in = @intCast(raw.len);

            const deflate_output_chunk: c_uint = large_buffer_size;
            var err: c_int = undefined;
            while (true) {
                self.deflation_stream.next_out = @as([*c]u8, @ptrCast(@alignCast(zlib_context.deflation_buffer.ptr)));
                self.deflation_stream.avail_out = deflate_output_chunk;
                err = zlib.deflate(@ptrCast(@alignCast(&self.deflation_stream)), zlib.Z_SYNC_FLUSH);
                if (zlib.Z_OK == err and self.deflation_stream.avail_out == 0) {
                    try zlib_context.dynamic_deflation_buffer.appendSlice(allocator, zlib_context.deflation_buffer[0..@intCast(deflate_output_chunk - self.deflation_stream.avail_out)]);
                    continue;
                } else break;
            }
            if (reset) {
                _ = zlib.deflateReset(@ptrCast(@alignCast(&self.deflation_stream)));
            }
            if (zlib_context.dynamic_deflation_buffer.items.len != 0) {
                try zlib_context.dynamic_deflation_buffer.appendSlice(allocator, zlib_context.deflation_buffer[0..@intCast(deflate_output_chunk - self.deflation_stream.avail_out)]);
                return zlib_context.dynamic_deflation_buffer.items[0 .. zlib_context.dynamic_deflation_buffer.items.len - 4];
            }

            return zlib_context.deflation_buffer[0..@intCast(deflate_output_chunk - self.deflation_stream.avail_out - 4)];
        }
    },
};

pub const InflationStream = switch (!env.with_zlib or env.mock_zlib) {
    true => struct {
        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, _: CompressOptions) !*Self {
            return allocator.create(Self);
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            allocator.destroy(self);
        }

        pub fn inflate(_: *Self, _: std.mem.Allocator, _: *ZlibContext, compressed: []const u8, max_payload_length: usize, _: bool) !?[]u8 {
            return compressed[0..@min(max_payload_length, compressed.len)];
        }
    },
    else => struct {
        const Self = @This();

        inflation_stream: zlib.z_stream = .{},

        pub fn init(allocator: std.mem.Allocator, compress_options: CompressOptions) !*Self {
            const self = try allocator.create(Self);
            self.* = .{};
            _ = zlib.inflateInit2(@as([*c]zlib.z_stream, @ptrCast(@alignCast(&self.inflation_stream))), -@as(c_int, @intCast(@intFromEnum(compress_options) >> 8)));
            return self;
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            _ = zlib.inflateEnd(@ptrCast(@alignCast(&self.inflation_stream)));
            allocator.destroy(self);
        }

        // TODO: clean up `constCast` usages (some should just not be passed as const)
        pub fn inflate(self: *Self, allocator: std.mem.Allocator, zlib_context: *ZlibContext, compressed: []const u8, max_payload_length: usize, reset: bool) !?[]u8 {
            if (env.with_libdeflate) {
                if (reset) {
                    var written: usize = 0;
                    var consumed: usize = undefined;
                    zlib_context.dynamic_inflation_buffer.clearRetainingCapacity();
                    try zlib_context.dynamic_inflation_buffer.ensureTotalCapacity(max_payload_length);
                    zlib_context.dynamic_inflation_buffer.expandToCapacity();
                    @constCast(compressed)[0] |= 0x1;
                    const res = libdeflate.libdeflate_deflate_decompress_ex(zlib_context.decompressor, @ptrCast(@alignCast(compressed.ptr)), compressed.len, @ptrCast(@alignCast(zlib_context.dynamic_inflation_buffer.items.ptr)), max_payload_length, &consumed, &written);
                    if (res == 0 and (consumed == compressed.len or (consumed + 1 == compressed.len and compressed[consumed] == 0))) {
                        return zlib_context.dynamic_inflation_buffer.items[0..written];
                    } else {
                        @constCast(compressed)[0] &= ~0x1;
                    }
                }
            }
            var compressed_ = @constCast(compressed);
            var tail_location: [*]u8 = compressed_.ptr + compressed_.len;
            var pre_tail_bytes: [4]u8 = undefined;
            @memcpy(&pre_tail_bytes, tail_location[0..4]);
            var tail = [_]u8{ 0x00, 0x00, 0xff, 0xff };
            @memcpy(@constCast(tail_location), &tail);
            compressed_ = compressed_.ptr[0 .. compressed_.len + 4];
            zlib_context.dynamic_inflation_buffer.clearRetainingCapacity();
            self.inflation_stream.next_in = @ptrCast(@alignCast(compressed_.ptr));
            self.inflation_stream.avail_in = @intCast(compressed_.len);
            var err: c_int = undefined;
            while (true) {
                self.inflation_stream.next_out = @ptrCast(@alignCast(zlib_context.inflation_buffer.ptr));
                self.inflation_stream.avail_out = large_buffer_size;
                err = zlib.inflate(@ptrCast(@alignCast(&self.inflation_stream)), zlib.Z_SYNC_FLUSH);
                if (err == zlib.Z_OK and self.inflation_stream.avail_out != 0) break;
                try zlib_context.dynamic_inflation_buffer.appendSlice(allocator, zlib_context.inflation_buffer[0..@intCast(large_buffer_size - self.inflation_stream.avail_out)]);
                if (!(self.inflation_stream.avail_out == 0 and zlib_context.dynamic_inflation_buffer.items.len <= max_payload_length)) break;
            }
            if (reset) {
                _ = zlib.inflateReset(@ptrCast(@alignCast(&self.inflation_stream)));
            }
            @memcpy(@constCast(tail_location), pre_tail_bytes[0..4]);
            if ((err != zlib.Z_BUF_ERROR and err != zlib.Z_OK) or zlib_context.dynamic_inflation_buffer.items.len > max_payload_length) {
                return null;
            }
            if (zlib_context.dynamic_inflation_buffer.items.len != 0) {
                try zlib_context.dynamic_inflation_buffer.appendSlice(allocator, zlib_context.inflation_buffer[0..@intCast(large_buffer_size - self.inflation_stream.avail_out)]);
                if (zlib_context.dynamic_inflation_buffer.items.len > max_payload_length) {
                    return null;
                }
                return zlib_context.dynamic_inflation_buffer.items;
            }
            if (@as(usize, @intCast(large_buffer_size - self.inflation_stream.avail_out)) > max_payload_length) {
                return null;
            }
            return zlib_context.inflation_buffer[0..@intCast(large_buffer_size - self.inflation_stream.avail_out)];
        }
    },
};
