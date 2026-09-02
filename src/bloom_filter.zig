const std = @import("std");

const Self = @This();

const ScrambleArea = packed struct {
    p0: u8,
    p1: u8,
    p2: u8,
    p3: u8,
};

filter: [256]u1,

pub const empty: Self = .{
    .filter = @splat(0),
};

inline fn perfectHash(features: u32) u32 {
    return features *% 1843993368;
}

fn getFeatures(key: []const u8) ScrambleArea {
    return .{
        .p0 = key[0],
        .p1 = key[key.len - 1],
        .p2 = key[key.len - 2],
        .p3 = key[key.len >> 1],
    };
}

pub fn mightHave(self: *const Self, key: []const u8) bool {
    if (key.len < 2) return true;
    var s = getFeatures(key);
    s = @bitCast(perfectHash(@bitCast(s)));
    return self.filter[s.p0] != 0 and self.filter[s.p1] != 0 and self.filter[s.p2] != 0 and self.filter[s.p3] != 0;
}

pub fn add(self: *Self, key: []const u8) void {
    if (key.len >= 2) {
        var s = getFeatures(key);
        s = @bitCast(perfectHash(@bitCast(s)));
        self.filter[s.p0] = 1;
        self.filter[s.p1] = 1;
        self.filter[s.p2] = 1;
        self.filter[s.p3] = 1;
    }
}

pub fn reset(self: *Self) void {
    @memset(&self.filter, 0);
}

test "BloomFilter" {
    const allocator = std.testing.allocator;
    const common_headers = [_][]const u8{
        "A-IM",
        "Accept",
        "Accept-Charset",
        "Accept-Datetime",
        "Accept-Encoding",
        "Accept-Language",
        "Access-Control-Request-Method",
        "Access-Control-Request-Headers",
        "Authorization",
        "Cache-Control",
        "Connection",
        "Content-Encoding",
        "Content-Length",
        "Content-MD5",
        "Content-Type",
        "Cookie",
        "Date",
        "Expect",
        "Forwarded",
        "From",
        "Host",
        "HTTP2-Settings",
        "If-Match",
        "If-Modified-Since",
        "If-None-Match",
        "If-Range",
        "If-Unmodified-Since",
        "Max-Forwards",
        "Origin",
        "Pragma",
        "Proxy-Authorization",
        "Range",
        "Referer",
        "TE",
        "Trailer",
        "Transfer-Encoding",
        "User-Agent",
        "Upgrade",
        "Via",
        "Warning",
    };

    // TODO: might be able to do this w/o allocations at compile time
    var lower_common_headers: std.ArrayList([]u8) = .empty;
    defer {
        for (lower_common_headers.items) |item| allocator.free(item);
        lower_common_headers.deinit(allocator);
    }
    for (common_headers) |hdr| {
        const new_val = try allocator.alloc(u8, hdr.len);
        for (hdr, 0..) |c, i| new_val[i] = std.ascii.toLower(c);
        try lower_common_headers.append(allocator, new_val);
    }

    var bf: Self = .empty;
    var total_collisions: u64 = 0;

    for (lower_common_headers.items, 0..) |hdr, i| {
        bf.reset();
        try std.testing.expect(bf.mightHave(hdr) == false);
        bf.add(hdr);
        try std.testing.expect(bf.mightHave(hdr));
        for (lower_common_headers.items[i + 1 ..]) |next_hdr| {
            if (bf.mightHave(next_hdr)) {
                std.debug.print("{s} collides with {s}\n", .{ hdr, next_hdr });
                total_collisions += 1;
            }
        }
    }

    if (total_collisions != 0) std.debug.print("Total collisions: {d}\n", .{total_collisions});
    try std.testing.expect(total_collisions == 0);

    var total_false_positives: u64 = 0;
    for (lower_common_headers.items, 0..) |hdr, i| {
        bf.reset();
        for (lower_common_headers.items, 0..) |other, j| {
            if (j != i) bf.add(other);
        }
        if (bf.mightHave(hdr)) {
            std.debug.print("{s} has false positives\n", .{hdr});
            total_false_positives += 1;
        }
    }

    if (total_false_positives != 0) std.debug.print("Total false positives: {d}\n", .{total_false_positives});
    try std.testing.expect(total_false_positives == 0);
}
