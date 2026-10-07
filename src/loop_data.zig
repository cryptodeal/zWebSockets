const per_message_deflate = @import("per_message_deflate.zig");
const std = @import("std");
const zs = @import("zSockets");

const Lambda = @import("lambda.zig").Lambda;
const Loop = @import("loop.zig").Loop;
const ZlibContext = per_message_deflate.ZlibContext;
const InflationStream = per_message_deflate.InflationStream;
const DeflationStream = per_message_deflate.DeflationStream;

const Self = @This();

pub const cork_buffer_size = 16 * 1024;

defer_mutex: std.Io.Mutex = .init,
current_defer_queue: u32 = 0,
defer_queues: [2]std.ArrayList(Lambda(?*anyopaque, &.{ std.mem.Allocator, std.Io }, anyerror!void)) = @splat(.empty),
post_handlers: std.AutoHashMapUnmanaged(?*anyopaque, Lambda(?*anyopaque, &.{ std.mem.Allocator, std.Io, *Loop }, anyerror!void)) = .empty,
pre_handlers: std.AutoHashMapUnmanaged(?*anyopaque, Lambda(?*anyopaque, &.{ std.mem.Allocator, std.Io, *Loop }, anyerror!void)) = .empty,
date: [32]u8 = undefined,
cache_timepoint: std.Io.Timestamp = undefined,
no_mark: bool = false,
cork_buffer: []u8,
cork_offset: u32 = 0,
corked_socket: ?*anyopaque = null,
zlib_context: ?*ZlibContext = null,
inflation_stream: ?*InflationStream = null,
deflation_stream: ?*DeflationStream = null,
date_timer: *zs.Timer = undefined,

pub fn init(allocator: std.mem.Allocator, io: std.Io) !Self {
    var self: Self = .{
        .cork_buffer = try allocator.alloc(u8, cork_buffer_size),
    };
    try self.updateDate(io);
    return self;
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    if (self.zlib_context) |zlib_ctx| {
        zlib_ctx.deinit(allocator);
        self.inflation_stream.?.deinit(allocator);
        self.deflation_stream.?.deinit(allocator);
    }
    for (&self.defer_queues) |*q| {
        for (q.items) |*cb| cb.deinit(allocator);
        q.deinit(allocator);
    }
    var iterator = self.post_handlers.valueIterator();
    while (iterator.next()) |cb| cb.deinit(allocator);
    self.post_handlers.deinit(allocator);
    iterator = self.pre_handlers.valueIterator();
    while (iterator.next()) |cb| cb.deinit(allocator);
    self.pre_handlers.deinit(allocator);
    zs.timerClose(allocator, self.date_timer);
    allocator.free(self.cork_buffer);
}

pub fn updateDate(self: *Self, io: std.Io) !void {
    self.cache_timepoint = std.Io.Timestamp.now(io, .real);
    const wday_name = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
    const mon_name = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = @intCast(self.cache_timepoint.toSeconds()) };
    const epoch_day_seconds = epoch.getDaySeconds();
    const epoch_day = epoch.getEpochDay();
    const epoch_year_day = epoch_day.calculateYearDay();
    const epoch_month_day = epoch_year_day.calculateMonthDay();

    _ = try std.fmt.bufPrint(&self.date, "{s}, {d:0>2} {s} {d} {d:0>2}:{d:0>2}:{d:0>2} GMT", .{
        wday_name[@mod(@divFloor(epoch.secs, 86400) + 4, 7)],
        (epoch_month_day.day_index + 1),
        mon_name[epoch_month_day.month.numeric() - 1],
        epoch_year_day.year,
        epoch_day_seconds.getHoursIntoDay(),
        epoch_day_seconds.getMinutesIntoHour(),
        epoch_day_seconds.getSecondsIntoMinute(),
    });
}

pub fn format(self: Self, w: *std.Io.Writer) std.Io.Writer.Error!void {
    return w.print("LoopData{{ current_defer_queue: {d}, date: {s}, no_mark: {any}, cork_buffer: {s}, cork_offset: {d}, corked_socket: {any} }}", .{ self.current_defer_queue, &self.date, self.no_mark, self.cork_buffer[0..self.cork_offset], self.cork_offset, self.corked_socket });
}
