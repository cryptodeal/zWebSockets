const std = @import("std");

pub const valueless_query = "";

pub inline fn getDecodedQueryValue(key: []const u8, raw_query: []const u8) ?[]const u8 {
    if (key.len == 0) return null;
    var query_string = raw_query;
    while (query_string.len != 0) {
        var statement = query_string[1..blk: {
            if (std.mem.findScalar(u8, query_string[1..], '&')) |i| break :blk i + 1 else break :blk query_string.len;
        }];
        if (statement.len != 0 and statement[0] == key[0]) {
            if (std.mem.findScalar(u8, statement, '=')) |equality| {
                const statement_key = statement[0..equality];
                var statement_value = statement[equality + 1 ..];
                if (std.mem.eql(u8, key, statement_key)) {
                    var in: []u8 = @constCast(statement_value.ptr)[0..statement_value.len];
                    var out: u32 = 0;

                    var i: usize = 0;
                    while (i < statement_value.len and in[i] != 0) : (i += 1) {
                        if (in[i] == '%') {
                            if (i + 2 >= statement_value.len) {
                                return null;
                            }

                            var hex1 = in[i + 1] - '0';
                            if (hex1 > 9) {
                                hex1 &= 223;
                                hex1 -= 7;
                            }
                            var hex2 = in[i + 2] - '0';
                            if (hex2 > 9) {
                                hex2 &= 223;
                                hex2 -= 7;
                            }
                            in[out] = hex1 * 16 + hex2;
                            i += 2;
                        } else {
                            if (in[i] == '+') {
                                in[out] = ' ';
                            } else {
                                in[out] = in[i];
                            }
                        }
                        out += 1;
                    }

                    if (out < statement_value.len) {
                        // TODO: verify this works as expected
                        in[out] = 0;
                    }
                    return statement_value[0..out];
                }
            } else {
                if (std.mem.eql(u8, key, statement)) {
                    return valueless_query;
                }
            }
        }
        query_string = query_string[statement.len + 1 ..];
    }

    return null;
}

test "Query Parser" {
    var buffer: [100]u8 = undefined;

    var buf = try std.fmt.bufPrint(&buffer, "?test1=&test2=someValue", .{});
    var res = getDecodedQueryValue("test2", buf);
    try std.testing.expect(res != null);
    try std.testing.expectEqualStrings("someValue", res.?);

    buf = try std.fmt.bufPrint(&buffer, "?test1=&test2=someValue", .{});
    res = getDecodedQueryValue("test1", buf);
    try std.testing.expect(res != null);
    try std.testing.expectEqualStrings("", res.?);
    res = getDecodedQueryValue("test2", buf);
    try std.testing.expect(res != null);
    try std.testing.expectEqualStrings("someValue", res.?);

    buf = try std.fmt.bufPrint(&buffer, "?Kest1=&test2=someValue", .{});
    res = getDecodedQueryValue("test2", buf);
    try std.testing.expect(res != null);
    try std.testing.expectEqualStrings("someValue", res.?);

    buf = try std.fmt.bufPrint(&buffer, "?Test1=&Kest2=some", .{});
    res = getDecodedQueryValue("Test1", buf);
    try std.testing.expect(res != null);
    try std.testing.expectEqualStrings("", res.?);
    res = getDecodedQueryValue("Kest2", buf);
    try std.testing.expect(res != null);
    try std.testing.expectEqualStrings("some", res.?);

    buf = try std.fmt.bufPrint(&buffer, "?Test1=&Kest2=some", .{});
    res = getDecodedQueryValue("Test1", buf);
    try std.testing.expect(res != null);
    try std.testing.expectEqualStrings("", res.?);
    res = getDecodedQueryValue("sdfsdf", buf);
    try std.testing.expect(res == null);

    buf = try std.fmt.bufPrint(&buffer, "?Kest1=&test2=some%20Value", .{});
    res = getDecodedQueryValue("test2", buf);
    try std.testing.expect(res != null);
    try std.testing.expectEqualStrings("some Value", res.?);

    buf = try std.fmt.bufPrint(&buffer, "?debug&dx=5", .{});
    res = getDecodedQueryValue("dx", buf);
    try std.testing.expect(res != null);
    try std.testing.expectEqualStrings("5", res.?);

    buf = try std.fmt.bufPrint(&buffer, "?debug&empty=&x=1", .{});
    res = getDecodedQueryValue("debug", buf);
    try std.testing.expect(res != null);
    try std.testing.expectEqualStrings("", res.?);
    try std.testing.expect(res.?.ptr == valueless_query);
    res = getDecodedQueryValue("empty", buf);
    try std.testing.expect(res != null);
    try std.testing.expectEqualStrings("", res.?);
    try std.testing.expect(res.?.ptr != valueless_query);
    res = getDecodedQueryValue("missing", buf);
    try std.testing.expect(res == null);
    try std.testing.expect(getDecodedQueryValue("debu", buf) == null);
    try std.testing.expect(getDecodedQueryValue("debugger", buf) == null);
    try std.testing.expectEqualStrings("1", getDecodedQueryValue("x", buf).?);

    buf = try std.fmt.bufPrint(&buffer, "?a=1&flag", .{});
    try std.testing.expect(getDecodedQueryValue("flag", buf).?.ptr == valueless_query);
}
