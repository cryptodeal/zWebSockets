const std = @import("std");

const Lambda = @import("lambda.zig").Lambda;

pub const Topic = struct {
    name: []const u8,
    subscribers: std.AutoHashMapUnmanaged(*Subscriber, void) = .empty,

    pub fn init(allocator: std.mem.Allocator, name: []const u8) !*Topic {
        const self = try allocator.create(Topic);
        self.* = .{ .name = name };
        return self;
    }

    pub fn deinit(self: *Topic, allocator: std.mem.Allocator) void {
        // TODO: verify strategy for freeing Topics/Subscribers
        // var iterator = self.subscribers.keyIterator();
        // while (iterator.next()) |s| {
        //     s.*.deinit(allocator);
        // }
        self.subscribers.deinit(allocator);
        allocator.destroy(self);
    }
};

pub const Subscriber = struct {
    prev: ?*Subscriber = null,
    next: ?*Subscriber = null,
    message_indices: [32]u16 = undefined,
    num_message_indices: u8 = 0,
    topics: std.AutoHashMapUnmanaged(*Topic, void) = .empty,
    user: ?*anyopaque = null,

    pub fn init(allocator: std.mem.Allocator) !*Subscriber {
        const self = try allocator.create(Subscriber);
        self.* = .{};
        return self;
    }

    pub fn deinit(self: *Subscriber, allocator: std.mem.Allocator) void {
        // TODO: verify strategy for freeing Topics/Subscribers
        // var iterator = self.topics.keyIterator();
        // while (iterator.next()) |t| {
        //     t.*.deinit(allocator);
        // }
        self.topics.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn needsDrainage(self: *const Subscriber) bool {
        return self.num_message_indices != 0;
    }
};

pub fn TopicTree(comptime T: type, comptime B: type) type {
    return struct {
        const Self = @This();
        pub const IteratorFlags = enum(u32) { last = 1, first = 2, _ };

        arena: std.heap.ArenaAllocator,
        iterating_subscriber: ?*Subscriber = null,
        cb: Lambda(?*anyopaque, &.{ std.mem.Allocator, std.Io, *Subscriber, *T, IteratorFlags }, anyerror!bool),
        //  cb: *const fn (std.mem.Allocator, ctx: Context, *Subscriber, *T, IteratorFlags) anyerror!bool,
        topics: std.StringHashMapUnmanaged(*Topic) = .empty,
        drainable_subscribers: ?*Subscriber = null,
        outgoing_messages: std.ArrayList(T) = .empty,

        fn checkIteratingSubscriber(self: *Self, s: ?*Subscriber) void {
            if (self.iterating_subscriber == s) {
                std.process.fatal("Error: WebSocket must not subscribe or unsubscribe to topics while iterating its topics!\n", .{});
            }
        }

        fn drainImpl(self: *Self, allocator: std.mem.Allocator, io: std.Io, s: *Subscriber) !void {
            const num_message_indices: usize = s.num_message_indices;
            s.num_message_indices = 0;
            for (0..num_message_indices) |i| {
                const outgoing_message = &self.outgoing_messages.items[s.message_indices[i]];
                const flags: u32 = if (i == num_message_indices - 1) @intFromEnum(IteratorFlags.last) else 0;
                if (try self.cb.call(.{ allocator, io, s, outgoing_message, @as(IteratorFlags, @enumFromInt(flags | (if (i == 0) @intFromEnum(IteratorFlags.first) else 0))) })) {
                    break;
                }
            }
        }

        fn unlinkDrainableSubscriber(self: *Self, s: *Subscriber) void {
            if (s.prev) |prev| {
                prev.next = s.next;
            }
            if (s.next) |next| {
                next.prev = s.prev;
            }
            if (self.drainable_subscribers) |drainable_subscribers| {
                if (drainable_subscribers == s) self.drainable_subscribers = s.next;
            }
        }

        pub fn init(allocator: std.mem.Allocator, cb: Lambda(?*anyopaque, &.{ std.mem.Allocator, std.Io, *Subscriber, *T, IteratorFlags }, anyerror!bool)) !*Self {
            const self = try allocator.create(Self);
            self.* = .{
                .arena = std.heap.ArenaAllocator.init(allocator),
                .cb = cb,
            };
            return self;
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.arena.deinit();
            self.topics.deinit(allocator);
            self.cb.deinit(allocator);
            self.outgoing_messages.deinit(allocator);
            allocator.destroy(self);
        }

        pub fn dupe(self: *Self, msg: []const u8) ![]u8 {
            return self.arena.allocator().dupe(u8, msg);
        }

        pub fn lookupTopic(self: *Self, topic: []const u8) ?*Topic {
            return self.topics.get(topic);
        }

        pub fn subscribe(self: *Self, allocator: std.mem.Allocator, s: *Subscriber, topic: []const u8) !?*Topic {
            self.checkIteratingSubscriber(s);
            const entry = try self.topics.getOrPut(allocator, topic);
            if (!entry.found_existing) {
                entry.value_ptr.* = try Topic.init(allocator, topic);
            }
            const topics_entry = try s.topics.getOrPut(allocator, entry.value_ptr.*);
            if (topics_entry.found_existing) return null else topics_entry.value_ptr.* = {};
            try entry.value_ptr.*.subscribers.put(allocator, s, {});
            return entry.value_ptr.*;
        }

        pub fn unsubscribe(self: *Self, s: *Subscriber, topic: []const u8) struct { bool, bool, i32 } {
            self.checkIteratingSubscriber(s);
            if (self.lookupTopic(topic)) |topic_ptr| {
                // TODO: might want to free topic/subscriber here
                if (!s.topics.remove(topic_ptr)) {
                    return .{ false, false, -1 };
                }
                _ = topic_ptr.subscribers.remove(s);
                const new_count: i32 = @intCast(topic_ptr.subscribers.count());
                if (new_count == 0) {
                    _ = self.topics.remove(topic);
                }
                return .{ true, self.topics.count() == 0, new_count };
            } else {
                return .{ false, false, -1 };
            }
        }

        pub fn createSubscriber(_: *const Self, allocator: std.mem.Allocator) !*Subscriber {
            return Subscriber.init(allocator);
        }

        pub fn freeSubscriber(self: *Self, allocator: std.mem.Allocator, s: ?*Subscriber) void {
            if (s) |s_| {
                var iter = s_.topics.keyIterator();
                while (iter.next()) |key| {
                    const topic_ptr = key.*;
                    if (topic_ptr.subscribers.count() == 1) {
                        if (self.topics.fetchRemove(topic_ptr.name)) |kv| {
                            kv.value.deinit(allocator);
                        }
                    } else {
                        _ = topic_ptr.subscribers.remove(s_);
                    }
                }

                if (s_.needsDrainage()) {
                    self.unlinkDrainableSubscriber(s_);
                }
                s_.deinit(allocator);
            } else return;
        }

        pub fn drainSubscriber(self: *Self, allocator: std.mem.Allocator, io: std.Io, s: *Subscriber) !void {
            if (s.needsDrainage()) {
                self.unlinkDrainableSubscriber(s);
                try self.drainImpl(allocator, io, s);
                if (self.drainable_subscribers == null) {
                    // TODO: might want to `.free_all` if memory usage is important
                    _ = self.arena.reset(.retain_capacity);
                    self.outgoing_messages.clearRetainingCapacity();
                }
            }
        }

        pub fn drain(self: *Self, allocator: std.mem.Allocator, io: std.Io) !void {
            if (self.drainable_subscribers) |drainable_subscribers| {
                var s: ?*Subscriber = drainable_subscribers;
                while (s) |s_| : (s = s_.next) {
                    try self.drainImpl(allocator, io, s_);
                }
                self.drainable_subscribers = null;
                // TODO: might want to `.free_all` if memory usage is important
                _ = self.arena.reset(.retain_capacity);
                self.outgoing_messages.clearRetainingCapacity();
            }
        }

        pub fn publishAnyBig(self: *Self, allocator: std.mem.Allocator, io: std.Io, sender: ?*Subscriber, topic: []const u8, big_message: anytype, cb: *const fn (std.mem.Allocator, std.Io, *Subscriber, @TypeOf(big_message)) anyerror!void) !bool {
            if (self.topics.get(topic)) |it| {
                var iterator = it.subscribers.keyIterator();
                while (iterator.next()) |entry| {
                    const s = entry.*;
                    if (sender != @as(?*Subscriber, @ptrCast(@alignCast(s)))) {
                        try cb(allocator, io, s, big_message);
                    }
                }
                return true;
            } else return false;
        }

        pub fn publishBig(self: *Self, allocator: std.mem.Allocator, io: std.Io, sender: ?*Subscriber, topic: []const u8, big_message: B, cb: *const fn (std.mem.Allocator, std.Io, *Subscriber, B) anyerror!void) !bool {
            if (self.topics.get(topic)) |it| {
                var iterator = it.subscribers.keyIterator();
                while (iterator.next()) |entry| {
                    const s = entry.*;
                    if (sender != @as(?*Subscriber, @ptrCast(@alignCast(s)))) {
                        try cb(allocator, io, s, big_message);
                    }
                }
                return true;
            } else return false;
        }

        pub fn publish(self: *Self, allocator: std.mem.Allocator, io: std.Io, sender: ?*Subscriber, topic: []const u8, message: T) !bool {
            if (self.topics.get(topic)) |it| {
                if (self.outgoing_messages.items.len == std.math.maxInt(u16)) {
                    try self.drain(allocator, io);
                }
                var referenced_message = false;
                var s_iterator = it.subscribers.keyIterator();
                while (s_iterator.next()) |entry| {
                    const s = entry.*;
                    if (sender != @as(?*Subscriber, @ptrCast(@alignCast(s)))) {
                        referenced_message = true;
                        if (s.num_message_indices == 32) {
                            try self.drainSubscriber(allocator, io, s);
                        }
                        s.message_indices[s.num_message_indices] = @intCast(self.outgoing_messages.items.len);
                        s.num_message_indices += 1;
                        if (s.num_message_indices == 1) {
                            s.next = self.drainable_subscribers;
                            s.prev = null;
                            if (s.next) |next| {
                                next.prev = s;
                            }
                            self.drainable_subscribers = s;
                        }
                    }
                }
                if (referenced_message) {
                    try self.outgoing_messages.append(allocator, message);
                }
                return referenced_message;
            } else return false;
        }
    };
}

test "Correctness" {
    const allocator = std.testing.allocator;
    var actual_result: std.AutoHashMapUnmanaged(?*anyopaque, std.ArrayList(u8)) = .empty;
    defer {
        var iterator = actual_result.valueIterator();
        while (iterator.next()) |res| res.deinit(allocator);
        actual_result.deinit(allocator);
    }

    var topic_tree: *TopicTree([]u8, []const u8) = undefined;
    topic_tree = try .init(allocator, .init(
        &actual_result,
        (struct {
            pub fn call(c: ?*anyopaque, a: std.mem.Allocator, _: std.Io, s: *Subscriber, message: *[]u8, _: TopicTree([]u8, []const u8).IteratorFlags) !bool {
                const ctx: *std.AutoHashMapUnmanaged(?*anyopaque, std.ArrayList(u8)) = @ptrCast(@alignCast(c));
                const entry = try ctx.getOrPut(a, s);
                if (!entry.found_existing) entry.value_ptr.* = .empty;
                try entry.value_ptr.*.appendSlice(a, message.*);
                return false;
            }
        }).call,
        null,
    ));
    defer topic_tree.deinit(allocator);

    var s1 = try topic_tree.createSubscriber(allocator);
    defer topic_tree.freeSubscriber(allocator, s1);
    var s2 = try topic_tree.createSubscriber(allocator);
    defer topic_tree.freeSubscriber(allocator, s2);
    if (@intFromPtr(s2) < @intFromPtr(s1)) {
        const tmp = s1;
        s1 = s2;
        s2 = tmp;
    }

    _ = try topic_tree.publish(allocator, std.testing.io, null, "topic3", @constCast(@as([]const u8, "Nobody should see")));

    _ = try topic_tree.subscribe(allocator, s1, "topic3");

    _ = try topic_tree.publish(allocator, std.testing.io, s1, "topic3", @constCast(@as([]const u8, "Nobody should see")));

    _ = try topic_tree.subscribe(allocator, s2, "topic3");

    _ = try topic_tree.publish(allocator, std.testing.io, null, "topic3", @constCast(@as([]const u8, "Both should see")));

    _ = try topic_tree.publish(allocator, std.testing.io, s2, "topic3", @constCast(@as([]const u8, "s1 should see, not s2")));

    _ = try topic_tree.publish(allocator, std.testing.io, s1, "topic3", @constCast(@as([]const u8, "s2 should see, not s1")));

    _ = try topic_tree.publish(allocator, std.testing.io, null, "topic3", @constCast(@as([]const u8, "Again, both should see this as well")));

    const expected_result = [_]@Tuple(&.{ *Subscriber, []const u8 }){
        .{ s1, "Both should sees1 should see, not s2Again, both should see this as well" },
        .{ s2, "Both should sees2 should see, not s1Again, both should see this as well" },
    };
    try topic_tree.drain(allocator, std.testing.io);
    for (expected_result) |p| {
        const actual = actual_result.get(p[0]);
        try std.testing.expect(actual != null);
        try std.testing.expectEqualStrings(p[1], actual.?.items);
    }
}

test "Bug Report" {
    const allocator = std.testing.allocator;
    var actual_result: std.AutoHashMapUnmanaged(?*anyopaque, std.ArrayList(u8)) = .empty;
    defer {
        var iterator = actual_result.valueIterator();
        while (iterator.next()) |res| res.deinit(allocator);
        actual_result.deinit(allocator);
    }

    var topic_tree: *TopicTree([]u8, []const u8) = undefined;
    topic_tree = try .init(allocator, .init(
        &actual_result,
        (struct {
            pub fn call(c: ?*anyopaque, a: std.mem.Allocator, _: std.Io, s: *Subscriber, message: *[]u8, _: TopicTree([]u8, []const u8).IteratorFlags) !bool {
                const ctx: *std.AutoHashMapUnmanaged(?*anyopaque, std.ArrayList(u8)) = @ptrCast(@alignCast(c));
                const entry = try ctx.getOrPut(a, s);
                if (!entry.found_existing) entry.value_ptr.* = .empty;
                try entry.value_ptr.*.appendSlice(a, message.*);
                return false;
            }
        }).call,
        null,
    ));
    defer topic_tree.deinit(allocator);

    var s1 = try topic_tree.createSubscriber(allocator);
    defer topic_tree.freeSubscriber(allocator, s1);
    var s2 = try topic_tree.createSubscriber(allocator);
    defer topic_tree.freeSubscriber(allocator, s2);
    if (@intFromPtr(s2) < @intFromPtr(s1)) {
        const tmp = s1;
        s1 = s2;
        s2 = tmp;
    }

    _ = try topic_tree.subscribe(allocator, s1, "b1");
    _ = try topic_tree.subscribe(allocator, s2, "b2");
    _ = try topic_tree.publish(allocator, std.testing.io, s1, "b1", @constCast(@as([]const u8, "b1")));
    _ = try topic_tree.publish(allocator, std.testing.io, s1, "b2", @constCast(@as([]const u8, "b2")));
    _ = try topic_tree.publish(allocator, std.testing.io, s2, "b1", @constCast(@as([]const u8, "b1")));
    _ = try topic_tree.publish(allocator, std.testing.io, s2, "b2", @constCast(@as([]const u8, "b2")));

    const expected_result = [_]@Tuple(&.{ *Subscriber, []const u8 }){
        .{ s1, "b1" },
        .{ s2, "b2" },
    };
    try topic_tree.drain(allocator, std.testing.io);
    for (expected_result) |p| {
        const actual = actual_result.get(p[0]);
        try std.testing.expect(actual != null);
        try std.testing.expectEqualStrings(p[1], actual.?.items);
    }
}

test "Reordering v19" {
    const allocator = std.testing.allocator;
    var actual_result: std.AutoHashMapUnmanaged(?*anyopaque, std.ArrayList(u8)) = .empty;
    defer {
        var iterator = actual_result.valueIterator();
        while (iterator.next()) |res| res.deinit(allocator);
        actual_result.deinit(allocator);
    }

    var topic_tree: *TopicTree([]u8, []const u8) = undefined;
    topic_tree = try .init(allocator, .init(
        &actual_result,
        (struct {
            pub fn call(c: ?*anyopaque, a: std.mem.Allocator, _: std.Io, s: *Subscriber, message: *[]u8, _: TopicTree([]u8, []const u8).IteratorFlags) !bool {
                const ctx: *std.AutoHashMapUnmanaged(?*anyopaque, std.ArrayList(u8)) = @ptrCast(@alignCast(c));
                const entry = try ctx.getOrPut(a, s);
                if (!entry.found_existing) entry.value_ptr.* = .empty;
                try entry.value_ptr.*.appendSlice(a, message.*);
                return false;
            }
        }).call,
        null,
    ));
    defer topic_tree.deinit(allocator);

    const s1 = try topic_tree.createSubscriber(allocator);
    defer topic_tree.freeSubscriber(allocator, s1);

    var buffers: [100][4]u8 = undefined;
    var names: [100][]u8 = undefined;
    var expected_result: std.ArrayList(u8) = .empty;
    defer expected_result.deinit(allocator);

    for (0..100) |i| {
        names[i] = try std.fmt.bufPrint(&buffers[i], "{d},", .{i});
        _ = try topic_tree.subscribe(allocator, s1, names[i][0 .. names[i].len - 1]);
    }

    for (0..100) |i| {
        _ = try topic_tree.publish(allocator, std.testing.io, null, names[i][0 .. names[i].len - 1], names[i]);
        try expected_result.appendSlice(allocator, names[i]);
    }

    try topic_tree.drain(allocator, std.testing.io);

    const actual = actual_result.get(s1);
    try std.testing.expect(actual != null);
    try std.testing.expectEqualStrings(expected_result.items, actual.?.items);
}
