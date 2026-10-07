const per_message_deflate = @import("per_message_deflate.zig");
const std = @import("std");
const zs = @import("zSockets");

const CompressOptions = per_message_deflate.CompressOptions;
const DeflationStream = per_message_deflate.DeflationStream;
const InflationStream = per_message_deflate.InflationStream;
const Lambda = @import("lambda.zig").Lambda;
const LoopData = @import("loop_data.zig");
const ZlibContext = per_message_deflate.ZlibContext;

pub const PreparedMessage = struct {
    original_message: []const u8,
    compressed_message: []const u8,
    compressed: bool,
    op_code: i32,
};

pub const Loop = struct {
    fn wakeupCb(allocator: std.mem.Allocator, io: std.Io, loop: *zs.Loop) !void {
        const loop_data: *LoopData = loop.ext[0].get(LoopData).?;
        try loop_data.defer_mutex.lock(io);
        const old_defer_queue = loop_data.current_defer_queue;
        loop_data.current_defer_queue = @rem(loop_data.current_defer_queue + 1, 2);
        loop_data.defer_mutex.unlock(io);
        for (loop_data.defer_queues[old_defer_queue].items) |*x| {
            try x.call(.{ allocator, io });
            x.deinit(allocator);
        }
        loop_data.defer_queues[old_defer_queue].clearRetainingCapacity();
    }

    fn onPre(allocator: std.mem.Allocator, io: std.Io, loop: *zs.Loop) !void {
        const loop_data: *LoopData = loop.ext[0].get(LoopData).?;
        var iterator = loop_data.pre_handlers.valueIterator();
        while (iterator.next()) |x| {
            try x.call(.{ allocator, io, @as(*Loop, @ptrCast(@alignCast(loop))) });
        }
    }

    fn onPost(allocator: std.mem.Allocator, io: std.Io, loop: *zs.Loop) !void {
        const loop_data: *LoopData = loop.ext[0].get(LoopData).?;
        var iterator = loop_data.post_handlers.valueIterator();
        while (iterator.next()) |x| {
            try x.call(.{ allocator, io, @as(*Loop, @ptrCast(@alignCast(loop))) });
        }
        if (loop_data.corked_socket) |_| {
            std.debug.print("Error: Cork buffer must not be held across event loop iterations!\n", .{});
            std.process.abort();
        }
    }

    fn internalInit(self: *Loop, allocator: std.mem.Allocator, io: std.Io) !*Loop {
        @as(*zs.Loop, @ptrCast(@alignCast(self))).ext[0].get(LoopData).?.* = try LoopData.init(allocator, io);
        return self;
    }

    pub fn init(allocator: std.mem.Allocator, io: std.Io, hint: ?*anyopaque) !*Loop {
        const loop = try @as(*Loop, @ptrCast(@alignCast(try zs.Loop.init(allocator, io, hint, &wakeupCb, &onPre, &onPost, &.{LoopData})))).internalInit(allocator, io);
        const loop_data: *LoopData = @as(*zs.Loop, @ptrCast(@alignCast(loop))).ext[0].get(LoopData).?;
        loop_data.date_timer = try zs.createTimer(allocator, io, @ptrCast(@alignCast(loop)), true, &.{*LoopData});
        @memcpy(std.mem.asBytes(zs.getTimerExt(loop_data.date_timer, 0, *LoopData).?), std.mem.asBytes(&loop_data));
        zs.timerSet(loop_data.date_timer, (struct {
            pub fn call(_: std.mem.Allocator, io_: std.Io, t: *zs.Timer) !void {
                var ld: *LoopData = undefined;
                @memcpy(std.mem.asBytes(&ld), std.mem.asBytes(zs.getTimerExt(t, 0, *LoopData).?));
                try ld.updateDate(io_);
            }
        }).call, 1000, 1000);
        return loop;
    }

    pub const LoopCleaner = struct {
        loop: ?*Loop = null,
        clean_me: bool = false,

        pub const init: LoopCleaner = .{};

        pub fn deinit(self: *LoopCleaner, allocator: std.mem.Allocator) void {
            if (self.loop) |loop| {
                if (self.clean_me) loop.deinit(allocator);
            }
        }
    };

    threadlocal var loop_cleaner: LoopCleaner = .init;

    fn getLazyLoop() *LoopCleaner {
        return &loop_cleaner;
    }

    pub fn prepareMessage(self: *Loop, allocator: std.mem.Allocator, message: []const u8, op_code: i32, compress: bool) !PreparedMessage {
        var prepared_message: PreparedMessage = .{
            .compressed = compress,
            .op_code = op_code,
            .original_message = message,
            .compressed_message = undefined,
        };

        const loop_data: *LoopData = @as(*zs.Loop, @ptrCast(@alignCast(self))).ext[0].get(LoopData).?;
        if (compress) {
            if (loop_data.zlib_context == null) {
                loop_data.zlib_context = try ZlibContext.init(allocator);
                loop_data.inflation_stream = try InflationStream.init(allocator, @enumFromInt(CompressOptions.dedicated_decompressor));
                loop_data.deflation_stream = try DeflationStream.init(allocator, @enumFromInt(CompressOptions.dedicated_compressor));
            }
            prepared_message.compressed_message = try loop_data.deflation_stream.?.deflate(allocator, loop_data.zlib_context.?, prepared_message.original_message, true);
        }
        return prepared_message;
    }

    pub fn get(allocator: std.mem.Allocator, io: std.Io, existing_native_loop: ?*anyopaque) !*Loop {
        if (getLazyLoop().loop == null) {
            getLazyLoop().loop = try init(allocator, io, existing_native_loop);
            if (existing_native_loop == null) {
                getLazyLoop().clean_me = true;
            }
        }
        return getLazyLoop().loop.?;
    }

    pub fn deinit(self: *Loop, allocator: std.mem.Allocator) void {
        const loop_data: *LoopData = @as(*zs.Loop, @ptrCast(@alignCast(self))).ext[0].get(LoopData).?;
        loop_data.deinit(allocator);
        @as(*zs.Loop, @ptrCast(@alignCast(self))).deinit(allocator);
        getLazyLoop().loop = null;
    }

    pub fn addPostHandler(self: *Loop, allocator: std.mem.Allocator, key: ?*anyopaque, handler: Lambda(?*anyopaque, &.{ std.mem.Allocator, std.Io, *Loop }, anyerror!void)) !void {
        var loop_data: *LoopData = @as(*zs.Loop, @ptrCast(@alignCast(self))).ext[0].get(LoopData).?;
        try loop_data.post_handlers.put(allocator, key, handler);
    }

    pub fn removePostHandler(self: *Loop, allocator: std.mem.Allocator, key: ?*anyopaque) void {
        const loop_data: *LoopData = @as(*zs.Loop, @ptrCast(@alignCast(self))).ext[0].get(LoopData).?;
        var entry = loop_data.post_handlers.fetchRemove(key).?;
        entry.value.deinit(allocator);
    }

    pub fn addPreHandler(self: *Loop, allocator: std.mem.Allocator, key: ?*anyopaque, handler: Lambda(?*anyopaque, &.{ std.mem.Allocator, std.Io, *Loop }, anyerror!void)) !void {
        const loop_data: *LoopData = @as(*zs.Loop, @ptrCast(@alignCast(self))).ext[0].get(LoopData).?;
        try loop_data.pre_handlers.put(allocator, key, handler);
    }

    pub fn removePreHandler(self: *Loop, allocator: std.mem.Allocator, key: ?*anyopaque) void {
        const loop_data: *LoopData = @as(*zs.Loop, @ptrCast(@alignCast(self))).ext[0].get(LoopData).?;
        var entry = loop_data.pre_handlers.fetchRemove(key).?;
        entry.value.deinit(allocator);
    }

    pub fn @"defer"(self: *Loop, allocator: std.mem.Allocator, io: std.Io, cb: Lambda(?*anyopaque, &.{ std.mem.Allocator, std.Io }, anyerror!void)) !void {
        const loop_data: *LoopData = @as(*zs.Loop, @ptrCast(@alignCast(self))).ext[0].get(LoopData).?;
        try loop_data.defer_mutex.lock(io);
        try loop_data.defer_queues[loop_data.current_defer_queue].append(allocator, cb);
        loop_data.defer_mutex.unlock(io);
        zs.loop.wakeupLoop(@as(*zs.Loop, @ptrCast(@alignCast(self))));
    }

    pub fn run(self: *Loop, allocator: std.mem.Allocator, io: std.Io) !void {
        try @as(*zs.Loop, @ptrCast(@alignCast(self))).run(allocator, io);
    }

    pub fn integrate(self: *Loop) void {
        zs.loop.integrate(@as(*zs.Loop, @ptrCast(@alignCast(self))));
    }

    pub fn setSilent(self: *Loop, silent: bool) void {
        @as(*zs.Loop, @ptrCast(@alignCast(self))).ext[0].get(LoopData).?.no_mark = silent;
    }
};

pub inline fn run(allocator: std.mem.Allocator, io: std.Io) !void {
    try (try Loop.get(allocator, io, null)).run(allocator, io);
}
