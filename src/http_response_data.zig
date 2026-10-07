const env = @import("env");
const std = @import("std");

const Lambda = @import("lambda.zig").Lambda;

const AsyncSocketData = @import("async_socket_data.zig").AsyncSocketData;
const HttpParser = @import("http_parser.zig").HttpParser;
const ProxyParser = @import("proxy_parser.zig").ProxyParser;

const HttpState = enum(i32) {
    status_called = 1,
    write_called = 2,
    end_called = 4,
    response_pending = 8,
    connection_close = 16,
};

inline fn markDoneImpl(comptime ssl: bool, allocator: std.mem.Allocator, self: *HttpResponseData(ssl)) void {
    if (self.on_aborted) |*on_aborted| {
        on_aborted.deinit(allocator);
        self.on_aborted = null;
    }
    if (self.on_writable) |*on_writable| {
        on_writable.deinit(allocator);
        self.on_writable = null;
    }
    self.state &= ~@intFromEnum(HttpState.response_pending);
}

inline fn callOnWritableImpl(comptime ssl: bool, allocator: std.mem.Allocator, io: std.Io, self: *HttpResponseData(ssl)) !bool {
    var borrowed_on_writable = self.on_writable.?;
    var placeholder_replaced = false;
    self.on_writable = .init(
        &placeholder_replaced,
        (struct {
            pub fn call(_: ?*anyopaque, _: std.mem.Allocator, _: std.Io, _: u128) !bool {
                return true;
            }
        }).call,
        (struct {
            pub fn call(_: std.mem.Allocator, ctx: ?*anyopaque) void {
                const replaced_flag: ?*bool = @ptrCast(@alignCast(ctx));
                if (replaced_flag) |rf| {
                    rf.* = false;
                }
            }
        }).call,
    );

    const ret = try borrowed_on_writable.call(.{ allocator, io, self.offset });
    if (!placeholder_replaced) {
        self.on_writable = borrowed_on_writable;
    } else {
        borrowed_on_writable.deinit(allocator);
    }
    return ret;
}

pub fn HttpResponseData(comptime ssl: bool) type {
    switch (env.with_proxy) {
        true => return struct {
            const Self = @This();

            pub const State = HttpState;

            async_socket_data: AsyncSocketData(ssl),
            http_parser: HttpParser,
            // TODO: might need to add error handling
            on_writable: ?Lambda(?*anyopaque, &.{ std.mem.Allocator, std.Io, u128 }, anyerror!bool) = null,
            on_aborted: ?Lambda(?*anyopaque, &.{ std.mem.Allocator, std.Io }, anyerror!void) = null,
            in_stream: ?Lambda(?*anyopaque, &.{ std.mem.Allocator, std.Io, []const u8, u64 }, anyerror!void) = null,
            offset: u128 = 0,
            received_bytes_per_timeout: u32 = 0,
            state: i32 = 0,
            proxy_parser: ProxyParser,

            // TODO: pub fn init() Self {}

            pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
                self.async_socket_data.deinit(allocator);
                self.http_parser.deinit(allocator);
                if (self.on_writable) |*on_writable| on_writable.deinit(allocator);
                if (self.on_aborted) |*on_aborted| on_aborted.deinit(allocator);
                if (self.in_stream) |*in_stream| in_stream.deinit(allocator);
            }

            pub fn markDone(self: *Self, allocator: std.mem.Allocator) void {
                markDoneImpl(ssl, allocator, self);
            }

            pub fn callOnWritable(self: *Self, allocator: std.mem.Allocator, io: std.Io) !bool {
                return callOnWritableImpl(ssl, allocator, io, self);
            }

            pub fn format(self: Self, w: *std.Io.Writer) std.Io.Writer.Error!void {
                return w.print("HttpResponseData({any}){{ async_socket_data: {f}, offset: {d}, received_bytes_per_timeout: {d}, state: {d} }}", .{ ssl, self.async_socket_data, self.offset, self.received_bytes_per_timeout, self.state });
            }
        },
        else => return struct {
            const Self = @This();

            pub const State = HttpState;

            async_socket_data: AsyncSocketData(ssl),
            http_parser: HttpParser,
            // TODO: might need to add error handling
            on_writable: ?Lambda(?*anyopaque, &.{ std.mem.Allocator, std.Io, u128 }, anyerror!bool) = null,
            on_aborted: ?Lambda(?*anyopaque, &.{ std.mem.Allocator, std.Io }, anyerror!void) = null,
            in_stream: ?Lambda(?*anyopaque, &.{ std.mem.Allocator, std.Io, []const u8, u64 }, anyerror!void) = null,
            offset: u128 = 0,
            received_bytes_per_timeout: u32 = 0,
            state: i32 = 0,

            // TODO: pub fn init() Self {}

            pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
                self.async_socket_data.deinit(allocator);
                self.http_parser.deinit(allocator);
                if (self.on_writable) |*on_writable| on_writable.deinit(allocator);
                if (self.on_aborted) |*on_aborted| on_aborted.deinit(allocator);
                if (self.in_stream) |*in_stream| in_stream.deinit(allocator);
            }

            pub fn markDone(self: *Self, allocator: std.mem.Allocator) void {
                markDoneImpl(ssl, allocator, self);
            }

            pub fn callOnWritable(self: *Self, allocator: std.mem.Allocator, io: std.Io) !bool {
                return callOnWritableImpl(ssl, allocator, io, self);
            }

            pub fn format(self: Self, w: *std.Io.Writer) std.Io.Writer.Error!void {
                return w.print("HttpResponseData({any}){{ async_socket_data: {f}, offset: {d}, received_bytes_per_timeout: {d}, state: {d} }}", .{ ssl, self.async_socket_data, self.offset, self.received_bytes_per_timeout, self.state });
            }
        },
    }
}
