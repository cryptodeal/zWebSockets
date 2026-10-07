const env = @import("env");
const std = @import("std");

pub const BackPressure = struct {
    buffer: std.ArrayList(u8) = .empty,
    pending_removal: usize = 0,

    pub const empty: BackPressure = .{
        .buffer = .empty,
        .pending_removal = 0,
    };

    pub fn init(other: *BackPressure) BackPressure {
        return other.move();
    }

    pub fn deinit(self: *BackPressure, allocator: std.mem.Allocator) void {
        self.buffer.deinit(allocator);
    }

    pub fn append(self: *BackPressure, allocator: std.mem.Allocator, data: []const u8) !void {
        try self.buffer.appendSlice(allocator, data);
    }

    pub fn erase(self: *BackPressure, length: usize) void {
        self.pending_removal += length;
        if (self.pending_removal > (self.buffer.items.len >> 5)) {
            self.buffer.replaceRangeAssumeCapacity(0, self.pending_removal, &.{});
            self.pending_removal = 0;
        }
    }

    pub fn len(self: *const BackPressure) usize {
        return self.buffer.items.len - self.pending_removal;
    }

    pub fn clear(self: *BackPressure, allocator: std.mem.Allocator) void {
        self.pending_removal = 0;
        self.buffer.clearAndFree(allocator);
    }

    pub fn reserve(self: *BackPressure, allocator: std.mem.Allocator, length: usize) !void {
        try self.buffer.ensureTotalCapacity(allocator, length);
    }

    pub fn resize(self: *BackPressure, allocator: std.mem.Allocator, length: usize) !void {
        try self.buffer.resize(allocator, length);
    }

    pub fn asSlice(self: *BackPressure) []u8 {
        return self.buffer.items[self.pending_removal..];
    }

    pub fn totalLength(self: *const BackPressure) usize {
        return self.buffer.items.len;
    }

    pub fn move(self: *BackPressure) BackPressure {
        const result = self.*;
        self.* = .empty;
        return result;
    }

    pub fn format(self: BackPressure, w: *std.Io.Writer) std.Io.Writer.Error!void {
        return w.print("BackPressure{{ buffer: {s}, pending_removal: {d}}}", .{ self.buffer.items, self.pending_removal });
    }
};

pub fn AsyncSocketData(comptime ssl: bool) type {
    switch (env.remote_address_userspace) {
        true => return struct {
            const Self = @This();

            pub const ssl_ = ssl;

            buffer: BackPressure = .{},
            remote_address_buffer: [16]u8,
            remote_address: []u8,

            pub const empty: Self = .{
                .buffer = .empty,
                .remote_address_buffer = undefined,
                .remote_address = &.{},
            };

            pub fn init(backpressure: *BackPressure) Self {
                return .{
                    .buffer = backpressure.move(),
                    .remote_address_buffer = undefined,
                    .remote_address = &.{},
                };
            }

            pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
                self.buffer.deinit(allocator);
            }

            pub fn format(self: Self, w: *std.Io.Writer) std.Io.Writer.Error!void {
                return w.print("AsyncSocketData{{ buffer: {any}, remote_address: {s}}}", .{ self.buffer, self.remote_address });
            }
        },
        else => return struct {
            const Self = @This();

            pub const ssl_ = ssl;

            buffer: BackPressure = .{},

            pub const empty: Self = .{
                .buffer = .empty,
            };

            pub fn init(backpressure: *BackPressure) Self {
                return .{
                    .buffer = backpressure.move(),
                };
            }

            pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
                self.buffer.deinit(allocator);
            }

            pub fn format(self: Self, w: *std.Io.Writer) std.Io.Writer.Error!void {
                return w.print("AsyncSocketData{{ buffer: {f} }}", .{self.buffer});
            }
        },
    }
}
