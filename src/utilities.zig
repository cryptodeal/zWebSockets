const std = @import("std");

pub inline fn u32toaHex(value: u32, dst: [*]u8) usize {
    var value_ = value;
    var dst_ = dst;
    const palette = "0123456789abcdef";
    var temp: [10]u8 = undefined;
    var p: [*]u8 = &temp;
    while (true) {
        p[0] = palette[value_ & 15];
        p += 1;
        value_ >>= 4;
        if (!(value_ > 0)) break;
    }

    const ret = p - &temp;
    while (true) {
        p -= 1;
        dst_[0] = p[0];
        dst_ += 1;
        if (p == &temp) break;
    }

    return ret;
}

pub inline fn u64toa(value: u64, dst: [*]u8) usize {
    var value_ = value;
    var dst_ = dst;
    var temp: [20]u8 = undefined;
    var p: [*]u8 = &temp;
    while (true) {
        p[0] = @intCast((value_ % 10) + '0');
        p += 1;
        value_ /= 10;
        if (!(value_ > 0)) break;
    }

    const ret = (p - &temp);
    while (true) {
        p -= 1;
        dst_[0] = p[0];
        dst_ += 1;
        if (p == &temp) break;
    }
    return ret;
}
