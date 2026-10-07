const std = @import("std");

pub fn SharedPtr(comptime T: type) type {
    return struct {
        const Self = @This();
        ref_count: u32 = 0,
        value: T,

        pub fn init(allocator: std.mem.Allocator, value: T) !*Self {
            const res = try allocator.create(Self);
            res.* = .{
                .ref_count = 1,
                .value = value,
            };
            return res;
        }

        fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            std.debug.assert(self.ref_count == 0);
            allocator.destroy(self);
        }

        pub fn ref(self: *Self) *Self {
            self.ref_count += 1;
            return self;
        }

        pub fn deref(self: *Self, allocator: std.mem.Allocator) void {
            std.debug.assert(self.ref_count != 0);
            self.ref_count -= 1;
            if (self.ref_count == 0) {
                self.deinit(allocator);
            }
        }
    };
}
