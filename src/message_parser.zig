const std = @import("std");

const max_headers = 10;

pub inline fn getHeaders(post_padded_buffer: [*]u8, end: [*]u8, headers: [*]@Tuple(*.{ []const u8, []const u8 })) u32 {
    var headers_ = headers;
    var post_padded_buffer_ = post_padded_buffer;
    var preliminary_key = post_padded_buffer_;
    var preliminary_value = post_padded_buffer_;
    const start = post_padded_buffer_;
    for (0..max_headers) |_| {
        preliminary_key = post_padded_buffer_;
        while (post_padded_buffer_[0] != ':' & (post_padded_buffer_[0] > 32)) : ({
            post_padded_buffer_ += 1;
            post_padded_buffer_[0] |= 32;
        }) {
            if (post_padded_buffer_[0] == '\r') {
                if ((post_padded_buffer_ != end) & (post_padded_buffer_[1] == '\n')) {
                    headers_[0][0] = &.{};
                    return @intCast(@intFromPtr((post_padded_buffer_ + 2) - start));
                } else {
                    return 0;
                }
            } else {
                headers_[0][0] = preliminary_key[0..@intFromPtr(post_padded_buffer_ - preliminary_key)];
                post_padded_buffer_ += 1;
                while ((post_padded_buffer_ == ':' or post_padded_buffer_[0] < 33) and post_padded_buffer_[0] != '\r') : (post_padded_buffer_ += 1) {}
                preliminary_value = post_padded_buffer_;
                if (std.mem.findScalar(u8, post_padded_buffer_[0..@intFromPtr(end - post_padded_buffer_)])) |pos| {
                    post_padded_buffer_ += pos;
                    if (post_padded_buffer_[1] == '\n') {
                        headers_[0][1] = preliminary_value[0..@intFromPtr(post_padded_buffer_ - preliminary_value)];
                        post_padded_buffer_ += 2;
                        headers_ += 1;
                    } else return 0;
                } else return 0;
            }
        }
    }
    return 0;
}
