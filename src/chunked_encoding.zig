const std = @import("std");

pub const state_has_size: u64 = @as(u64, 1) << (@sizeOf(u64) * 8 - 1); //0x80000000;
pub const state_is_chunked: u64 = @as(u64, 1) << (@sizeOf(u64) * 8 - 2); //0x40000000;
pub const state_size_mask: u64 = ~(@as(u64, 3) << (@sizeOf(u64) * 8 - 2)); //0x3FFFFFFF;
pub const state_is_error: u64 = ~@as(u64, 0); //0xFFFFFFFF;
pub const state_size_overflow: u64 = @as(u64, 0x0F) << (@sizeOf(u64) * 8 - 8); //0x0F000000;

inline fn chunkSize(state: u64) u64 {
    return state & state_size_mask;
}

// TODO: need to update `data` in place
inline fn consumeHexNumber(data: *[]const u8, state: *u64) void {
    while (data.*.len != 0 and data.*[0] > 32) {
        var digit = data.*[0];
        if (digit >= 'a') {
            digit = digit - ('a' - ':');
        } else if (digit >= 'A') {
            digit = digit - ('A' - ':');
        }

        const number = @as(u32, @intCast(digit)) - @as(u32, @intCast('0'));
        if (number > 16 or (chunkSize(state.*) & state_size_overflow) != 0) {
            state.* = state_is_error;
            return;
        }

        const bits = state_is_chunked;
        state.* = (state.* & state_size_mask) * @as(u64, 16) + number;
        state.* |= bits;
        data.* = data.*[1..];
    }
    while (data.*.len != 0 and data.*[0] != '\n') {
        data.* = data.*[1..];
    }
    if (data.*.len != 0) {
        state.* += 2;
        state.* |= state_has_size | state_is_chunked;
        data.* = data.*[1..];
    }
}

inline fn decChunkSize(state: *u64, by: u32) void {
    state.* = (state.* & ~state_size_mask) | (chunkSize(state.*) - by);
}

inline fn hasChunkSize(state: u64) bool {
    return (state & state_has_size) != 0;
}

pub inline fn isParsingChunkedEncoding(state: u64) bool {
    return (state & ~state_size_mask) != 0;
}

pub inline fn isParsingInvalidChunkedEncoding(state: u64) bool {
    return state == state_is_error;
}

fn getNextChunk(data: *[]const u8, state: *u64, trailer: bool) ?[]const u8 {
    while (data.*.len != 0) {
        if (((state.* & state_is_chunked) == 0) and hasChunkSize(state.*) and chunkSize(state.*) != 0) {
            while (data.*.len != 0 and chunkSize(state.*) != 0) {
                data.* = data.*[1..];
                decChunkSize(state, 1);
                if (chunkSize(state.*) == 0) {
                    state.* = 0;
                    return null;
                }
            }
            continue;
        }

        if (!hasChunkSize(state.*)) {
            consumeHexNumber(data, state);
            if (isParsingInvalidChunkedEncoding(state.*)) {
                return null;
            }
            if (hasChunkSize(state.*) and chunkSize(state.*) == 2) {
                if (trailer) {
                    state.* = 4 | state_has_size;
                } else {
                    state.* = 2 | state_has_size;
                }
                return &.{};
            }
            continue;
        }

        if (data.*.len >= chunkSize(state.*)) {
            var emit_soon: []const u8 = undefined;
            var should_emit = false;
            if (chunkSize(state.*) > 2) {
                emit_soon = data.*[0 .. chunkSize(state.*) - 2];
                should_emit = true;
            }
            data.* = data.*[chunkSize(state.*)..];
            state.* = state_is_chunked;
            if (should_emit) {
                return emit_soon;
            }
            continue;
        } else {
            var emit_soon: []const u8 = &.{};
            if (chunkSize(state.*) > 2) {
                const maximal_app_emit = chunkSize(state.*) - 2;
                if (data.*.len > maximal_app_emit) {
                    emit_soon = data.*[0..maximal_app_emit];
                } else {
                    emit_soon = data.*;
                }
            }
            decChunkSize(state, @intCast(data.*.len));
            state.* |= state_is_chunked;
            data.* = data.*[data.*.len..];
            if (emit_soon.len != 0) {
                return emit_soon;
            } else {
                return null;
            }
        }
    }
    return null;
}

pub const ChunkIterator = struct {
    data: *[]const u8,
    chunk: ?[]const u8 = null,
    state: *u64,
    trailer: bool = false,

    pub fn init(data: *[]const u8, state: *u64, trailer: bool) ChunkIterator {
        return .{
            .data = data,
            .state = state,
            .trailer = trailer,
        };
    }

    pub fn next(self: *ChunkIterator) ?[]const u8 {
        self.chunk = getNextChunk(self.data, self.state, self.trailer);
        return self.chunk;
    }
};

// test helpers
fn consumeChunkEncoding(max_consume: usize, chunk_encoded: *[]const u8, state: *u64) !void {
    if (isParsingChunkedEncoding(state.*)) {
        std.debug.print("already in chunked parsing state!\n", .{});
        try std.testing.expect(false);
    }
    state.* = state_is_chunked;
    while (chunk_encoded.*.len != 0) {
        var data = chunk_encoded.*[0..@min(max_consume, chunk_encoded.*.len)];
        const data_len_before_parsing = data.len;
        var iterator = ChunkIterator.init(&data, state, true);
        while (iterator.next()) |_| {}
        chunk_encoded.* = chunk_encoded.*[data_len_before_parsing - data.len ..];
        if (state.* == 0) {
            if (chunk_encoded.*.len == 0 or chunk_encoded.*.len == 74) {
                break;
            } else {
                try std.testing.expect(false);
            }
            state.* = state_is_chunked;
        }
        if (!isParsingChunkedEncoding(state.*)) {
            std.debug.print("not in parsing chunked state!\n", .{});
            try std.testing.expect(false);
        }
    }
}

fn runBetterTest(allocator: std.mem.Allocator, max_consume: usize) !void {
    const chunks = [_][]const u8{
        "Hello there I am the first segment",
        "Why hello there",
        "",
        "I am last?",
        "And I am a little longer but it doesn't matter",
        "",
    };

    var ss: std.ArrayList(u8) = .empty;
    defer ss.deinit(allocator);
    for (chunks) |chunk| {
        try ss.print(allocator, "{x}\r\n{s}\r\n", .{ chunk.len, chunk });
        if (chunk.len == 0) {
            try ss.print(allocator, "\r\n", .{});
        }
    }
    const buffer = ss.items;
    var chunk_encoded = buffer;
    var state: u64 = 0;
    if (isParsingChunkedEncoding(state)) {
        try std.testing.expect(false);
    }
    try consumeChunkEncoding(max_consume, @ptrCast(&chunk_encoded), &state);
    try std.testing.expect(state == 0);
    try consumeChunkEncoding(max_consume, @ptrCast(&chunk_encoded), &state);
    try std.testing.expect(state == 0);
}

fn runTest(allocator: std.mem.Allocator, max_consume: usize) !void {
    var chunks = [_][]const u8{
        "Hello there I am the first segment",
        "Why hello there",
        "",
        "I am last?",
        "And I am a little longer but it doesn't matter",
        "",
    };

    var ss: std.ArrayList(u8) = .empty;
    defer ss.deinit(allocator);
    for (chunks) |chunk| {
        try ss.print(allocator, "{x}\r\n{s}\r\n", .{ chunk.len, chunk });
        if (chunk.len == 0) {
            try ss.print(allocator, "\r\n", .{});
        }
    }
    const buffer = ss.items;
    var stopped_with_clear_state: u32 = 0;
    var state: u64 = 0;
    var chunk_offset: u32 = 0;
    var chunk_encoded = buffer;

    while (chunk_encoded.len != 0) {
        var data = chunk_encoded[0..@min(max_consume, chunk_encoded.len)];
        const data_length_before_parsing = data.len;
        var chunk_iterator = ChunkIterator.init(@ptrCast(&data), &state, true);
        while (chunk_iterator.next()) |chunk| {
            // std.debug.print("<{s}>\n", .{chunk});
            try std.testing.expect(!(chunk.len == 0 and chunks[chunk_offset].len != 0));
            try std.testing.expectEqualStrings(chunks[chunk_offset][0..chunk.len], chunk);
            chunks[chunk_offset] = chunks[chunk_offset][chunk.len..];
            if (chunks[chunk_offset].len == 0) {
                chunk_offset += 1;
            }
        }
        if (state == 0) {
            stopped_with_clear_state += 1;
        }
        chunk_encoded = chunk_encoded[data_length_before_parsing - data.len ..];
    }
    try std.testing.expect(stopped_with_clear_state == 2);
}

fn testWithoutTrailer(allocator: std.mem.Allocator) !void {
    const chunks = [_][]const u8{ "Hello there I am the first segment", "" };
    var ss: std.ArrayList(u8) = .empty;
    defer ss.deinit(allocator);
    for (chunks) |chunk| {
        try ss.print(allocator, "{x}\r\n{s}\r\n", .{ chunk.len, chunk });
    }

    const buffer = ss.items;
    var data_to_consume = buffer;
    var state: u64 = state_is_chunked;

    var iterator = ChunkIterator.init(@ptrCast(&data_to_consume), &state, false);
    while (iterator.next()) |_| {}
    try std.testing.expect(state == 0);
}

test "Chunked Encoding" {
    const allocator = std.testing.allocator;
    try testWithoutTrailer(allocator);

    for (1..1000) |i| {
        try runBetterTest(allocator, i);
    }

    for (1..1000) |i| {
        try runTest(allocator, i);
    }
}
