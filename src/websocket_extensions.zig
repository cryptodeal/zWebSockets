const env = @import("env");
const std = @import("std");

pub const ExtensionTokens = enum(i32) {
    permessage_deflate = 1838,
    server_no_context_takeover = 2807,
    client_no_context_takeover = 2783,
    server_max_window_bits = 2372,
    client_max_window_bits = 2348,
    x_webkit_deflate_frame = 2149,
    no_context_takeover = 2049,
    max_window_bits = 1614,
    _,
};

pub const ExtensionsParser = struct {
    threadlocal var response_buffer: [128]u8 = undefined;
    threadlocal var response: std.ArrayList(u8) = undefined;

    last_int: ?*i32 = null,

    per_message_deflate: bool = false,
    server_no_context_takeover: bool = false,
    client_no_context_takeover: bool = false,
    server_max_window_bits: i32 = 0,
    client_max_window_bits: i32 = 0,

    x_webkit_deflate_frame: bool = false,
    no_context_takeover: bool = false,
    max_window_bits: i32 = 0,

    pub fn getToken(in: *[*]const u8, stop: [*]const u8) i32 {
        while (in.* != stop and !std.ascii.isAlphanumeric(in.*[0])) {
            in.* += 1;
        }

        var hashed_token: i32 = 0;
        while (in.* != stop and (std.ascii.isAlphanumeric(in.*[0]) or in.*[0] == '-' or in.*[0] == '_')) {
            if (std.ascii.isDigit(in.*[0])) {
                if (hashed_token > std.math.minInt(i16) and hashed_token < std.math.maxInt(i16)) {
                    hashed_token = hashed_token * 10 - @as(i32, @intCast(in.*[0] - '0'));
                }
            } else {
                hashed_token += @intCast(in.*[0]);
            }
            in.* += 1;
        }
        return hashed_token;
    }

    pub fn init(data: []const u8) ExtensionsParser {
        var data_ = data.ptr;
        var self: ExtensionsParser = .{};
        const stop = data.ptr + data.len;
        var token: i32 = 1;
        while (token != 0 and token != @intFromEnum(ExtensionTokens.permessage_deflate) and token != @intFromEnum(ExtensionTokens.x_webkit_deflate_frame)) : (token = getToken(&data_, stop)) {}
        self.per_message_deflate = (token == @intFromEnum(ExtensionTokens.permessage_deflate));
        self.x_webkit_deflate_frame = (token == @intFromEnum(ExtensionTokens.x_webkit_deflate_frame));
        token = getToken(&data_, stop);
        while (token != 0) : (token = getToken(&data_, stop)) {
            switch (@as(ExtensionTokens, @enumFromInt(token))) {
                .x_webkit_deflate_frame => return self,
                .no_context_takeover => self.no_context_takeover = true,
                .max_window_bits => {
                    self.max_window_bits = 1;
                    self.last_int = &self.max_window_bits;
                },
                .permessage_deflate => return self,
                .server_no_context_takeover => self.server_no_context_takeover = true,
                .client_no_context_takeover => self.client_no_context_takeover = true,
                .server_max_window_bits => {
                    self.server_max_window_bits = 1;
                    self.last_int = &self.server_max_window_bits;
                },
                .client_max_window_bits => {
                    self.client_max_window_bits = 1;
                    self.last_int = &self.client_max_window_bits;
                },
                else => {
                    if (token < 0 and self.last_int != null) {
                        self.last_int.?.* = -token;
                    }
                },
            }
        }
        return self;
    }
};

pub inline fn negotiateCompression(
    want_compression: bool,
    wanted_compression_window: i32,
    wanted_inflation_window: i32,
    offer: []const u8,
    opts: struct {
        shared_and_dedicated_compressor_mix: bool = false,
        @"8_window_bits": bool = false,
    },
) @Tuple(&.{ bool, i32, i32, []const u8 }) {
    if (!want_compression) {
        return .{ false, 0, 0, "" };
    }

    const ep = ExtensionsParser.init(offer);
    ExtensionsParser.response = .initBuffer(&ExtensionsParser.response_buffer);

    var compression_window = wanted_compression_window;
    var inflation_window = wanted_inflation_window;
    var compression = false;
    if (ep.x_webkit_deflate_frame) {
        compression = true;
        ExtensionsParser.response.appendSliceAssumeCapacity("x-webkit-deflate-frame");
        if (ep.no_context_takeover) {
            if (!opts.shared_and_dedicated_compressor_mix) {
                if (wanted_compression_window != 0) {
                    return .{ false, 0, 0, "" };
                }
            }
            compression_window = 0;
        }
        if (ep.max_window_bits != 0 and ep.max_window_bits < compression_window) {
            compression_window = ep.max_window_bits;
            if (!opts.@"8_window_bits") {
                if (compression_window == 8) {
                    return .{ false, 0, 0, "" };
                }
            }
        }
        if (wanted_inflation_window < 15) {
            if (wanted_inflation_window == 0) {
                ExtensionsParser.response.appendSliceAssumeCapacity("; no_context_takeover");
            } else {
                ExtensionsParser.response.printAssumeCapacity("; max_window_bits={d}", .{wanted_inflation_window});
            }
        }
    } else if (ep.per_message_deflate) {
        compression = true;
        ExtensionsParser.response.appendSliceAssumeCapacity("permessage-deflate");
        if (ep.client_no_context_takeover) {
            inflation_window = 0;
        } else if (ep.client_max_window_bits != 0 and ep.client_max_window_bits != 1) {
            inflation_window = @min(ep.client_max_window_bits, inflation_window);
        }
        if (inflation_window < 15) {
            if (inflation_window == 0 or ep.client_max_window_bits == 0) {
                ExtensionsParser.response.appendSliceAssumeCapacity("; client_no_context_takeover");
                inflation_window = 0;
            } else {
                ExtensionsParser.response.printAssumeCapacity("; client_max_window_bits={d}", .{inflation_window});
            }
        }
        if (ep.server_no_context_takeover) {
            if (opts.shared_and_dedicated_compressor_mix) {
                compression_window = 0;
            }
        } else if (ep.server_max_window_bits != 0) {
            compression_window = @min(ep.server_max_window_bits, compression_window);
            if (!opts.@"8_window_bits") {
                if (compression_window == 8) {
                    compression_window = 9;
                }
            }
        }
        if (compression_window < 15) {
            if (compression_window == 0) {
                ExtensionsParser.response.appendSliceAssumeCapacity("; server_no_context_takeover");
            } else {
                ExtensionsParser.response.printAssumeCapacity("; server_max_window_bits={d}", .{compression_window});
            }
        }
    }
    if ((compression_window != 0 and compression_window < 8) or compression_window > 15 or (inflation_window != 0 and inflation_window < 8) or inflation_window > 15) {
        return .{ false, 0, 0, "" };
    }

    return .{ compression, compression_window, inflation_window, ExtensionsParser.response.items };
}

// test helper functions

test "Negotiation" {
    const testNegotiation = (struct {
        pub fn call(
            want_compression: bool,
            wanted_compression_window: i32,
            wanted_inflation_window: i32,
            offer: []const u8,
            neg_compression: bool,
            neg_compression_window: i32,
            neg_inflation_window: i32,
            neg_response: []const u8,
        ) !void {
            const compression, const compression_window, const inflation_window, const response = negotiateCompression(
                want_compression,
                wanted_compression_window,
                wanted_inflation_window,
                offer,
                .{ .@"8_window_bits" = true, .shared_and_dedicated_compressor_mix = true },
            );
            try std.testing.expect(compression == neg_compression);
            try std.testing.expect(compression_window == neg_compression_window);
            try std.testing.expect(inflation_window == neg_inflation_window);
            try std.testing.expectEqualStrings(neg_response, response);
        }
    }).call;

    try testNegotiation(false, 15, 15, "permessage-deflate", false, 0, 0, "");
    try testNegotiation(false, 15, 15, "x-webkit-deflate-frame", false, 0, 0, "");
    try testNegotiation(true, 15, 15, "", false, 15, 15, "");
    try testNegotiation(true, 15, 15, "", false, 15, 15, "");

    try testNegotiation(true, 15, 11, "permessage-deflate; ", true, 15, 0, "permessage-deflate; client_no_context_takeover");
    try testNegotiation(true, 15, 0, "permessage-deflate; ", true, 15, 0, "permessage-deflate; client_no_context_takeover");
    try testNegotiation(true, 15, 11, "permessage-deflate; client_max_window_bits=14", true, 15, 11, "permessage-deflate; client_max_window_bits=11");
    try testNegotiation(true, 15, 11, "permessage-deflate; client_max_window_bits=9", true, 15, 9, "permessage-deflate; client_max_window_bits=9");

    try testNegotiation(true, 0, 15, "permessage-deflate; ", true, 0, 15, "permessage-deflate; server_no_context_takeover");
    try testNegotiation(true, 8, 15, "permessage-deflate; ", true, 8, 15, "permessage-deflate; server_max_window_bits=8");
    try testNegotiation(true, 15, 15, "permessage-deflate; server_max_window_bits=8", true, 8, 15, "permessage-deflate; server_max_window_bits=8");
    try testNegotiation(true, 11, 15, "permessage-deflate; server_max_window_bits=14", true, 11, 15, "permessage-deflate; server_max_window_bits=11");

    try testNegotiation(true, 11, 15, "x-webkit-deflate-frame; no_context_takeover; max_window_bits=8", true, 0, 15, "x-webkit-deflate-frame");
    try testNegotiation(true, 11, 12, "x-webkit-deflate-frame; no_context_takeover; max_window_bits=8", true, 0, 12, "x-webkit-deflate-frame; max_window_bits=12");
    try testNegotiation(true, 11, 12, "x-webkit-deflate-frame; max_window_bits=8", true, 8, 12, "x-webkit-deflate-frame; max_window_bits=12");
    try testNegotiation(true, 15, 0, "x-webkit-deflate-frame; max_window_bits=15", true, 15, 0, "x-webkit-deflate-frame; no_context_takeover");

    try testNegotiation(true, 15, 15, "x-webkit-deflate-frame", true, 15, 15, "x-webkit-deflate-frame");
    try testNegotiation(true, 15, 15, "permessage-deflate", true, 15, 15, "permessage-deflate");

    try testNegotiation(true, 15, 15, "x-webkit-deflate-frame; max_window_bits=3", false, 0, 0, "");
    try testNegotiation(true, 15, 15, "x-webkit-deflate-frame; max_window_bits=16", true, 15, 15, "x-webkit-deflate-frame");

    try testNegotiation(true, 15, 15, "permessage-deflate; server_max_window_bits=3", false, 0, 0, "");
    try testNegotiation(true, 15, 15, "permessage-deflate; client_max_window_bits=3", false, 0, 0, "");

    try testNegotiation(true, 15, 15, "permessage-deflate; server_max_window_bits=17", true, 15, 15, "permessage-deflate");
    try testNegotiation(true, 15, 15, "permessage-deflate; client_max_window_bits=17", true, 15, 15, "permessage-deflate");
}
