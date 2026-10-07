const std = @import("std");

const AsyncSocketData = @import("async_socket_data.zig").AsyncSocketData;
const BackPressure = @import("async_socket_data.zig").BackPressure;
const CompressOptions = @import("per_message_deflate.zig").CompressOptions;
const DeflationStream = @import("per_message_deflate.zig").DeflationStream;
const InflationStream = @import("per_message_deflate.zig").InflationStream;
const Subscriber = @import("topic_tree.zig").Subscriber;

const Self = @This();
const WebSocketState = @import("websocket_protocol.zig").WebSocketState;

fragment_buffer: std.ArrayList(u8) = .empty,
control_tip_length: u32 = 0,
is_shutting_down: bool = false,
has_timed_out: bool = false,
compression_status: enum(i8) {
    disabled,
    enabled,
    compressed_frame,
},
deflation_stream: ?*DeflationStream = null,
inflation_stream: ?*InflationStream = null,
subscriber: ?*Subscriber = null,
async_socket_data: AsyncSocketData(false),
websocket_state: WebSocketState(true) = .{},

pub fn init(allocator: std.mem.Allocator, per_message_deflate: bool, compress_options: CompressOptions, backpressure: *BackPressure) !Self {
    var self: Self = .{
        .async_socket_data = AsyncSocketData(false).init(backpressure),
        .compression_status = if (per_message_deflate) .enabled else .disabled,
    };

    if (per_message_deflate) {
        if (@as(CompressOptions, @enumFromInt(@intFromEnum(compress_options) & CompressOptions.compressor_mask)) != CompressOptions.shared_compressor) {
            self.deflation_stream = try DeflationStream.init(allocator, compress_options);
        }
        if (@as(CompressOptions, @enumFromInt(@intFromEnum(compress_options) & CompressOptions.decompressor_mask)) != CompressOptions.shared_decompressor) {
            self.inflation_stream = try InflationStream.init(allocator, compress_options);
        }
    }
    return self;
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    if (self.deflation_stream) |ds| {
        ds.deinit(allocator);
        self.deflation_stream = null;
    }
    if (self.inflation_stream) |is| {
        is.deinit(allocator);
        self.inflation_stream = null;
    }
    if (self.subscriber) |sub| {
        sub.deinit(allocator);
    }
}

pub fn format(self: Self, w: *std.Io.Writer) std.Io.Writer.Error!void {
    return w.print("WebSocketData{{ fragment_buffer: {s}, control_tip_length: {d}, is_shutting_down: {any}, has_timed_out: {any}, compression_status: {s}, async_socket_data: {f} }}", .{
        self.fragment_buffer.items,
        self.control_tip_length,
        self.is_shutting_down,
        self.has_timed_out,
        @tagName(self.compression_status),
        self.async_socket_data,
    });
}
