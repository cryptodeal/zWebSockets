const std = @import("std");

const getHeaders = @import("message_parser.zig").getHeaders;

pub const ParameterParser = struct {
    remaining_line: []const u8,

    pub fn init(line: []const u8) ParameterParser {
        return .{ .remaining_line = line };
    }

    pub fn getKeyValue(self: *ParameterParser) @Tuple(&.{ []const u8, []const u8 }) {
        const key = self.getToken();
        const op = self.getToken();
        if (op.len == 0) {
            return .{ key, &.{} };
        }
        if (op[0] != ';') {
            const value = self.getToken();
            _ = self.getToken();
            return .{ key, value };
        }
        return .{ key, &.{} };
    }

    fn getToken(self: *ParameterParser) []const u8 {
        while (self.remaining_line.len and std.ascii.isWhitespace(self.remaining_line[0])) {
            self.remaining_line = self.remaining_line[1..];
        }
        if (self.remaining_line.len == 0) {
            return &.{};
        } else {
            if (self.remaining_line[0] == '\"') {
                self.remaining_line = self.remaining_line[1..];
                const quote = self.remaining_line;
                var quote_length: usize = 0;
                while (self.remaining_line.len != 0 and self.remaining_line[0] != '\"') {
                    self.remaining_line = self.remaining_line[1..];
                    quote_length += 1;
                }
                if (self.remaining_line.len == 0) {
                    return &.{};
                }
                self.remaining_line = self.remaining_line[1..];
                return quote[0..quote_length];
            } else {
                const token = self.remaining_line;
                var token_length: usize = 0;
                while (self.remaining_line.len != 0 and self.remaining_line[0] != ';' and self.remaining_line[0] != '=' and !std.ascii.isWhitespace(self.remaining_line[0])) {
                    self.remaining_line = self.remaining_line[1..];
                    token_length += 1;
                }
                return token[0..token_length];
            }
        }
        return &.{};
    }
};

pub const MultipartParser = struct {
    prepended_boundary_buffer: [72]u8 = undefined,
    prepended_boundary: []const u8 = &.{},
    remaining_body: []const u8 = &.{},
    first: bool = true,

    pub fn init(content_type: []const u8) MultipartParser {
        var self: MultipartParser = .{};
        if (content_type.len < 10 or std.mem.eql(u8, content_type[0..10], "multipart/")) {
            return self;
        }
        if (std.mem.findScalarPos(u8, content_type, 10, '=')) |pos| {
            const equal_token = 10 + pos;
            const boundary = content_type[equal_token + 1 ..];
            if (boundary.len == 0 or boundary.len > 70) {
                return self;
            }
            self.prepended_boundary_buffer[1] = '-';
            self.prepended_boundary_buffer[0] = self.prepended_boundary_buffer[1];
            @memcpy(self.prepended_boundary_buffer[2 .. 2 + boundary.len], boundary);
            self.prepended_boundary = self.prepended_boundary_buffer[0 .. boundary.len + 2];
        }
        return self;
    }

    pub fn isValid(self: *const MultipartParser) bool {
        return self.prepended_boundary.len != 0;
    }

    pub fn setBody(self: *MultipartParser, body: []const u8) void {
        self.remaining_body = body;
    }

    pub fn getNextPart(self: *MultipartParser, headers: [*]@Tuple(&.{ []const u8, []const u8 })) ?[]const u8 {
        if (self.remaining_body.len < self.prepended_boundary.len) {
            return null;
        }
        if (self.first) {
            if (std.mem.find(u8, self.remaining_body, self.prepended_boundary)) |next_boundary| {
                self.remaining_body = self.remaining_body[next_boundary + self.prepended_boundary.len ..];
                self.first = false;
            } else return null;
        }
        if (std.mem.find(u8, self.remaining_body, self.prepended_boundary)) |next_end_boundary| {
            var part = self.remaining_body[0..next_end_boundary];
            self.remaining_body = self.remaining_body[next_end_boundary + self.prepended_boundary.len ..];
            if (part.len < 4) {
                return null;
            }
            part = part[2 .. part.len - 2];
            @memset(part.ptr + part.len[0..1], '\r');
            const consumed = getHeaders(part.ptr, part.ptr + part.len, headers);
            if (!consumed) {
                return null;
            }
            part = part[consumed..];
            return part;
        } else return null;
    }
};
