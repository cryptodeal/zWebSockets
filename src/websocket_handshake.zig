const std = @import("std");

inline fn staticFor(comptime n: usize, comptime T: type, a: []u32, b: []u32) void {
    inline for (0..n) |i| {
        T.f(i, a, b);
    }
}

inline fn rol(value: u32, bits: usize) u32 {
    return (value << bits) | (value >> (32 - bits));
}

inline fn blk(b: []u32, i: usize) u32 {
    return rol(b[(i + 13) & 15] ^ b[(i + 8) & 15] ^ b[(i + 2) & 15] ^ b[i], 1);
}

const Sha1Loop1 = struct {
    inline fn f(comptime i: usize, a: []u32, b: []u32) void {
        a[i % 5] +%= ((a[(3 + i) % 5] & (a[(2 + i) % 5] ^ a[(1 + i) % 5])) ^ a[(1 + i) % 5]) +% b[i] +% 0x5a827999 +% rol(a[(4 + i) % 5], 5);
        a[(3 + i) % 5] = rol(a[(3 + i) % 5], 30);
    }
};

const Sha1Loop2 = struct {
    inline fn f(comptime i: usize, a: []u32, b: []u32) void {
        b[i] = blk(b, i);
        a[(1 + i) % 5] +%= ((a[(4 + i) % 5] & (a[(3 + i) % 5] ^ a[(2 + i) % 5])) ^ a[(2 + i) % 5]) +% b[i] +% 0x5a827999 +% rol(a[(5 + i) % 5], 5);
        a[(4 + i) % 5] = rol(a[(4 + i) % 5], 30);
    }
};

const Sha1Loop3 = struct {
    inline fn f(comptime i: usize, a: []u32, b: []u32) void {
        b[(i + 4) % 16] = blk(b, (i + 4) % 16);
        a[i % 5] +%= (a[(3 + i) % 5] ^ a[(2 + i) % 5] ^ a[(1 + i) % 5]) +% b[(i + 4) % 16] +% 0x6ed9eba1 +% rol(a[(4 + i) % 5], 5);
        a[(3 + i) % 5] = rol(a[(3 + i) % 5], 30);
    }
};

const Sha1Loop4 = struct {
    inline fn f(comptime i: usize, a: []u32, b: []u32) void {
        b[(i + 8) % 16] = blk(b, (i + 8) % 16);
        a[i % 5] +%= (((a[(3 + i) % 5] | a[(2 + i) % 5]) & a[(1 + i) % 5]) | (a[(3 + i) % 5] & a[(2 + i) % 5])) +% b[(i + 8) % 16] +% 0x8f1bbcdc +% rol(a[(4 + i) % 5], 5);
        a[(3 + i) % 5] = rol(a[(3 + i) % 5], 30);
    }
};

const Sha1Loop5 = struct {
    inline fn f(comptime i: usize, a: []u32, b: []u32) void {
        b[(i + 12) % 16] = blk(b, (i + 12) % 16);
        a[i % 5] +%= (a[(3 + i) % 5] ^ a[(2 + i) % 5] ^ a[(1 + i) % 5]) +% b[(i + 12) % 16] +% 0xca62c1d6 +% rol(a[(4 + i) % 5], 5);
        a[(3 + i) % 5] = rol(a[(3 + i) % 5], 30);
    }
};

const Sha1Loop6 = struct {
    inline fn f(comptime i: usize, a: []u32, b: []u32) void {
        b[i] +%= a[4 - i];
    }
};

inline fn sha1(hash: []u32, b: []u32) void {
    var a = [_]u32{ hash[4], hash[3], hash[2], hash[1], hash[0] };
    staticFor(16, Sha1Loop1, &a, b);
    staticFor(4, Sha1Loop2, &a, b);
    staticFor(20, Sha1Loop3, &a, b);
    staticFor(20, Sha1Loop4, &a, b);
    staticFor(20, Sha1Loop5, &a, b);
    staticFor(5, Sha1Loop6, &a, hash);
}

inline fn base64(src: []u8, dst: []u8) void {
    var dst_ = dst.ptr;
    const b64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    var i: usize = 0;
    while (i < 18) : (i += 3) {
        dst_[0] = b64[(src[i] >> 2) & 63];
        dst_ += 1;
        dst_[0] = b64[((src[i] & 3) << 4) | ((src[i + 1] & 240) >> 4)];
        dst_ += 1;
        dst_[0] = b64[((src[i + 1] & 15) << 2) | ((src[i + 2] & 192) >> 6)];
        dst_ += 1;
        dst_[0] = b64[src[i + 2] & 63];
        dst_ += 1;
    }
    dst_[0] = b64[(src[18] >> 2) & 63];
    dst_ += 1;
    dst_[0] = b64[((src[18] & 3) << 4) | ((src[19] & 240) >> 4)];
    dst_ += 1;
    dst_[0] = b64[((src[19] & 15) << 2)];
    dst_ += 1;
    dst_[0] = '=';
    dst_ += 1;
}

pub inline fn generate(input: []const u8, output: []u8) void {
    var b_output = [_]u32{ 0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476, 0xc3d2e1f0 };
    var b_input = [_]u32{ 0, 0, 0, 0, 0, 0, 0x32353845, 0x41464135, 0x2d453931, 0x342d3437, 0x44412d39, 0x3543412d, 0x43354142, 0x30444338, 0x35423131, 0x80000000 };
    inline for (0..6) |i| {
        b_input[i] = @as(u32, input[4 * i + 3] & 0xff) | @as(u32, input[4 * i + 2] & 0xff) << 8 | @as(u32, input[4 * i + 1] & 0xff) << 16 | @as(u32, input[4 * i + 0] & 0xff) << 24;
    }
    sha1(&b_output, &b_input);
    var last_b = [_]u32{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 480 };
    sha1(&b_output, &last_b);
    inline for (0..5) |i| {
        const tmp = b_output[i];
        var bytes = std.mem.sliceAsBytes(b_output[i..]);
        bytes[3] = @intCast(tmp & 0xff);
        bytes[2] = @intCast((tmp >> 8) & 0xff);
        bytes[1] = @intCast((tmp >> 16) & 0xff);
        bytes[0] = @intCast((tmp >> 24) & 0xff);
    }
    base64(std.mem.sliceAsBytes(&b_output), output);
}
