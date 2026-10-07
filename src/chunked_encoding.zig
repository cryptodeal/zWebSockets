const std = @import("std");

pub const state_has_size = @as(u64, 1) << (@sizeOf(u64) * 8 - 1);
pub const state_is_chunked: u64 = @as(u64, 1) << (@sizeOf(u64) * 8 - 2);

pub const state_extension_mode: u64 = @as(u64, 1) << (@sizeOf(u64) * 8 - 3);
pub const state_trailer_mode: u64 = @as(u64, 1) << (@sizeOf(u64) * 8 - 4);
pub const state_extension_expects_name = @as(u64, 1) << (@sizeOf(u64) * 8 - 5);
pub const state_extension_quoted = @as(u64, 1) << (@sizeOf(u64) * 8 - 6);
pub const state_extension_expects_lf = @as(u64, 1) << (@sizeOf(u64) * 8 - 7);
pub const state_extension_in_name = @as(u64, 1) << (@sizeOf(u64) * 8 - 8);

pub const state_size_mask: u64 = ~(@as(u64, 0xFF) << (@sizeOf(u64) * 8 - 8));
pub const state_is_error: u64 = ~@as(u64, 0);
pub const state_size_overflow: u64 = @as(u64, 0x0F) << (@sizeOf(u64) * 8 - 12);

inline fn isValidTokenChar(c: u8) bool {
    if (c < 0x20 or c >= 0x7F) return false;
    return switch (c) {
        '(',
        ')',
        '<',
        '>',
        '@',
        ',',
        ';',
        ':',
        '\\',
        '"',
        '/',
        '[',
        ']',
        '?',
        '=',
        '{',
        '}',
        ' ',
        '\t',
        => false,
        else => true,
    };
}

inline fn chunkSize(state: u64) u64 {
    return state & state_size_mask;
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

inline fn consumeHexNumber(data: *[]const u8, state: *u64) void {
    while (data.*.len != 0) {
        const c = data.*[0];
        if ((state.* & state_extension_mode) == 0) {
            if (c == ';') {
                if (!hasChunkSize(state.*) and (state.* & state_size_mask) == 0 and (state.* & state_is_chunked) == 0) {
                    state.* = state_is_error;
                    return;
                }
                state.* |= state_extension_mode | state_extension_expects_name;
                data.* = data.*[1..];
                continue;
            }
            if (c == '\r') {
                state.* |= state_extension_mode | state_extension_expects_lf;
                data.* = data.*[1..];
                continue;
            }
            if (c == '\n') {
                data.* = data.*[1..];
                state.* += 2;
                state.* |= state_has_size | state_is_chunked;
                state.* &= ~(state_extension_mode | state_extension_expects_name | state_extension_in_name | state_extension_quoted | state_extension_expects_lf);
                return;
            }
            var number: u32 = 0;
            if (c >= '0' and c <= '9')
                number = c - '0'
            else if (c >= 'a' and c <= 'f')
                number = c - 'a' + 10
            else if (c >= 'A' and c <= 'F')
                number = c - 'A' + 10
            else {
                state.* = state_is_error;
                return;
            }

            if ((chunkSize(state.*) & state_size_overflow) != 0) {
                state.* = state_is_error;
                return;
            }
            const bits = state.* & state_is_chunked;
            state.* = (state.* & state_size_mask) * @as(u64, 16) + number;
            state.* |= bits;
            data.* = data.*[1..];
        } else {
            if ((state.* & state_extension_expects_lf) != 0) {
                if (c != '\n') {
                    state.* = state_is_error;
                    return;
                }
                data.* = data.*[1..];
                state.* += 2;
                state.* |= state_has_size | state_is_chunked;
                state.* &= ~(state_extension_mode | state_extension_expects_name | state_extension_in_name | state_extension_quoted | state_extension_expects_lf);
                return;
            }
            if (c == 0x00 or (c < 0x20 and c != '\r' and c != '\n' and c != '\t')) {
                state.* = state_is_error;
                return;
            }
            if (c == '\r') {
                if ((state.* & state_extension_expects_name) != 0) {
                    state.* = state_is_error;
                    return;
                }
                state.* |= state_extension_expects_lf;
                data.* = data.*[1..];
                continue;
            }
            if ((state.* & state_extension_expects_name) != 0) {
                if (!isValidTokenChar(c)) {
                    state.* = state_is_error;
                    return;
                }
                state.* &= ~state_extension_expects_name;
                state.* |= state_extension_in_name;
            } else if ((state.* & state_extension_in_name) != 0) {
                if (c == '=')
                    state.* &= ~state_extension_in_name
                else if (c == ';') {
                    state.* &= ~state_extension_in_name;
                    state.* |= state_extension_expects_name;
                } else if (!isValidTokenChar(c)) {
                    state.* = state_is_error;
                    return;
                }
            } else {
                if (c == '"') state.* ^= state_extension_quoted;
                if (c == ';' and (state.* & state_extension_quoted) == 0) state.* |= state_extension_expects_name;
            }
            data.* = data.*[1..];
            if (c == '\n' and (state.* & state_extension_quoted) == 0) {
                if ((state.* & state_extension_expects_name) != 0) {
                    state.* = state_is_error;
                    return;
                }
                state.* += 2;
                state.* |= state_has_size | state_is_chunked;
                state.* &= ~(state_extension_mode | state_extension_expects_name | state_extension_in_name | state_extension_quoted | state_extension_expects_lf);
                return;
            }
        }
    }
}

fn getNextChunk(data: *[]const u8, state: *u64, trailer: bool) ?[]const u8 {
    while (data.len != 0) {
        if ((state.* & state_trailer_mode) != 0) {
            while (data.len != 0) {
                const c = data.*[0];
                data.* = data.*[1..];
                switch (chunkSize(state.*)) {
                    0 => {
                        if (c == '\r')
                            state.* = (state.* & ~state_size_mask) | 1
                        else if (c == '\n') {
                            state.* = state_is_error;
                            return null;
                        } else state.* = (state.* & ~state_size_mask) | 2;
                    },
                    1 => {
                        if (c == '\n') {
                            state.* = 0;
                            return null;
                        }
                        state.* = state_is_error;
                    },
                    2 => {
                        if (c == '\r')
                            state.* = (state.* & ~state_size_mask) | 3
                        else if (c == '\n') {
                            state.* = state_is_error;
                            return null;
                        }
                    },
                    3 => {
                        if (c == '\n')
                            state.* = (state.* & ~state_size_mask) | 0
                        else if (c != '\r')
                            state.* = (state.* & ~state_size_mask) | 2;
                    },
                    else => {},
                }
            }
            return null;
        }
        if (((state.* & state_is_chunked) == 0) and hasChunkSize(state.*) and chunkSize(state.*) != 0) {
            while (data.len != 0 and chunkSize(state.*) != 0) {
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
                    state.* = state_trailer_mode | 0;
                } else {
                    state.* = 2 | state_has_size;
                }
                return &.{};
            }
            continue;
        }
        if (data.len >= chunkSize(state.*)) {
            var emit_soon: []const u8 = &.{};
            var should_emit = false;

            if (chunkSize(state.*) > 2) {
                if (data.*[chunkSize(state.*) - 2] != '\r' or data.*[chunkSize(state.*) - 1] != '\n') {
                    state.* = state_is_error;
                    return null;
                }
                emit_soon = data.*[0 .. chunkSize(state.*) - 2];
                should_emit = true;
            } else if (chunkSize(state.*) == 2) {
                if (data.*[0] != '\r' or data.*[1] != '\n') {
                    state.* = state_is_error;
                    return null;
                }
            } else if (chunkSize(state.*) == 1) {
                if (data.*[0] != '\n') {
                    state.* = state_is_error;
                    return null;
                }
            }
            data.* = data.*[chunkSize(state.*)..];
            state.* = state_is_chunked;
            if (should_emit) return emit_soon;
            continue;
        } else {
            var emit_soon: []const u8 = &.{};
            if (chunkSize(state.*) > 2) {
                const maximal_app_emit = chunkSize(state.*) - 2;
                if (data.len > maximal_app_emit) {
                    // Enforce partial CRLF boundary safety limit
                    if (data.*[maximal_app_emit] != '\r') {
                        state.* = state_is_error;
                        return null;
                    }
                    emit_soon = data.*[0..maximal_app_emit];
                } else {
                    emit_soon = data.*;
                }
            } else if (chunkSize(state.*) == 2) {
                if (data.*[0] != '\r') {
                    state.* = state_is_error;
                    return null;
                }
            }

            decChunkSize(state, @intCast(data.len));
            state.* |= state_is_chunked;
            data.* = data.*[data.len..];
            if (emit_soon.len != 0)
                return emit_soon
            else
                return null;
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
        std.log.err("already in chunked parsing state!\n", .{});
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
            break;
        }
        if (!isParsingChunkedEncoding(state.*)) {
            std.log.err("not in parsing chunked state!\n", .{});
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
        if (chunk.len == 0) {
            try ss.print(allocator, "0\r\n\r\n", .{});
        } else {
            try ss.print(allocator, "{x}\r\n{s}\r\n", .{ chunk.len, chunk });
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
        if (chunk.len == 0) {
            try ss.print(allocator, "0\r\n\r\n", .{});
        } else {
            try ss.print(allocator, "{x}\r\n{s}\r\n", .{ chunk.len, chunk });
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
