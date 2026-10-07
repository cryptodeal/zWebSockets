const std = @import("std");
const zs = @import("zSockets");
const http_errors = @import("http_errors.zig");
const HttpResponse = @import("http_response.zig").HttpResponse;
const HttpRequest = @import("http_parser.zig").HttpRequest;
const Lambda = @import("lambda.zig").Lambda;
const Loop = @import("loop.zig").Loop;
const LoopData = @import("loop_data.zig");

pub const HttpCacheOptions = struct {
    lower_expiry: u32,
    upper_expiry: u32,
};

pub fn HttpCache(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const CacheType = std.StringHashMapUnmanaged(*CacheEntry);

        cache: CacheType = .empty,

        pub const CacheEntry = struct {
            const CbCtx = struct {
                entry: *CacheEntry,
                res: *HttpResponse(T.Ssl),

                pub fn init(allocator: std.mem.Allocator, entry: *CacheEntry, res: *HttpResponse(T.Ssl)) !*CbCtx {
                    const self = try allocator.create(CbCtx);
                    self.* = .{
                        .entry = entry,
                        .res = res,
                    };
                    return self;
                }

                pub fn deinit(allocator: std.mem.Allocator, ctx: ?*anyopaque) void {
                    const self: *CbCtx = @ptrCast(@alignCast(ctx));
                    allocator.destroy(self);
                }
            };

            waiting_http_responses: std.AutoHashMapUnmanaged(*HttpResponse(T.Ssl), void) = .empty,
            buffer: @Tuple(&.{ std.ArrayList(u8), std.ArrayList(u8) }) = .{ .empty, .empty },
            headers: @Tuple(&.{ std.ArrayList([]const u8), std.ArrayList([]const u8) }) = .{ .empty, .empty },
            status: []const u8 = &.{},
            updating_cache: bool = true,
            never_initialized: bool = true,
            created: std.Io.Timestamp = .fromNanoseconds(0),

            pub fn init(allocator: std.mem.Allocator) !*CacheEntry {
                const self = try allocator.create(CacheEntry);
                self.* = .{};
                return self;
            }

            pub fn deinit(self: *CacheEntry, allocator: std.mem.Allocator) void {
                self.waiting_http_responses.deinit(allocator);
                self.buffer[0].deinit(allocator);
                self.buffer[1].deinit(allocator);
                // TODO: need to free headers if they're each allocated
                self.headers[0].deinit(allocator);
                self.headers[1].deinit(allocator);
                // TODO: if status is allocated, free here
                allocator.destroy(self);
            }

            pub fn addDependentWaitingRequest(self: *CacheEntry, allocator: std.mem.Allocator, res: *HttpResponse(T.Ssl)) !u32 {
                _ = res.onAborted(allocator, .init(
                    try CbCtx.init(allocator, self, res),
                    (struct {
                        pub fn call(ctx: ?*anyopaque, _: std.mem.Allocator, _: std.Io) !void {
                            const aborted_ctx: *CbCtx = @ptrCast(@alignCast(ctx));
                            _ = aborted_ctx.entry.waiting_http_responses.remove(aborted_ctx.res);
                        }
                    }).call,
                    CbCtx.deinit,
                ));
                try self.waiting_http_responses.put(allocator, res, {});
                return self.waiting_http_responses.count();
            }

            pub fn append(self: *CacheEntry, allocator: std.mem.Allocator, data: []const u8) !void {
                try self.buffer[1].appendSlice(allocator, data);
            }

            pub fn markUpdated(self: *CacheEntry, allocator: std.mem.Allocator, io: std.Io) !void {
                self.never_initialized = false;
                self.updating_cache = false;
                std.mem.swap(std.ArrayList(u8), &self.buffer[0], &self.buffer[1]);
                std.mem.swap(std.ArrayList([]const u8), &self.headers[0], &self.headers[1]);
                self.buffer[1].clearRetainingCapacity();
                // TODO: if headers are allocated, they need to be freed here
                self.headers[1].clearRetainingCapacity();
                // TODO: if status is allocated, it needs to be freed here
                self.status = &.{};
                // TODO: verify this works
                const now = @as(*LoopData, @ptrCast(@alignCast(@as(*zs.Loop, @ptrCast(@alignCast(try Loop.get(allocator, io, null)))).ext[0].get(*LoopData).?))).cache_timepoint;
                self.created = now;

                var iter = self.waiting_http_responses.keyIterator();
                while (iter.next()) |dependent_res| {
                    var c: CbCtx = .{ .entry = self, .res = dependent_res.* };
                    _ = try dependent_res.*.cork(allocator, io, .init(
                        &c,
                        (struct {
                            pub fn call(ctx: ?*anyopaque, allocator_: std.mem.Allocator, io_: std.Io) !void {
                                const cb_ctx: *CbCtx = @ptrCast(@alignCast(ctx));
                                if (cb_ctx.entry.status.len != 0) {
                                    _ = try cb_ctx.res.writeStatus(allocator_, cb_ctx.entry.status);
                                }
                                var i: usize = 0;
                                while (i < cb_ctx.entry.headers[0].items.len) : (i += 2) {
                                    _ = try cb_ctx.res.writeHeader(allocator_, cb_ctx.entry.headers[0].items[i], cb_ctx.entry.headers[0].items[i + 1]);
                                }
                                try cb_ctx.res.end(allocator_, io_, cb_ctx.entry.buffer[0].items, false);
                            }
                        }).call,
                        null,
                    ));
                }
                self.waiting_http_responses.clearRetainingCapacity();
            }
        };

        pub const HttpCacheResponse = struct {
            cache_entry: *CacheEntry,

            pub fn init(allocator: std.mem.Allocator, cache_entry: *CacheEntry) !*HttpCacheResponse {
                const self = try allocator.create(HttpCacheResponse);
                self.* = .{ .cache_entry = cache_entry };
                return self;
            }

            pub fn deinit(self: *HttpCacheResponse, allocator: std.mem.Allocator) void {
                // freed elsewhere
                // self.cache_entry.deinit(allocator);
                allocator.destroy(self);
            }

            pub fn write(self: *HttpCacheResponse, allocator: std.mem.Allocator, data: []const u8) !void {
                try self.cache_entry.append(allocator, data);
            }

            pub fn writeStatus(self: *HttpCacheResponse, status: []const u8) void {
                // TODO: might need to allocate/dupe this
                self.cache_entry.status = status;
            }

            pub fn writeHeader(self: *HttpCacheResponse, allocator: std.mem.Allocator, key: []const u8, value: []const u8) !void {
                // TODO: might need to allocate/dupe key and value
                try self.cache_entry.headers[1].append(allocator, key);
                try self.cache_entry.headers[1].append(allocator, value);
            }

            pub fn end(self: *HttpCacheResponse, allocator: std.mem.Allocator, io: std.Io, data: []const u8, close_connection: bool) !void {
                try self.cache_entry.append(allocator, data);
                try self.cache_entry.markUpdated(allocator, io);
                _ = close_connection;
            }

            pub fn endWithoutBody(self: *HttpCacheResponse, allocator: std.mem.Allocator, io: std.Io, close_connection: bool) !void {
                self.cache_entry.buffer[1].clearRetainingCapacity();
                try self.cache_entry.markUpdated(allocator, io);
                _ = close_connection;
            }

            pub fn close(self: *HttpCacheResponse, allocator: std.mem.Allocator, io: std.Io) !void {
                self.cache_entry.buffer[1].clearRetainingCapacity();
                try self.cache_entry.append(allocator, http_errors.http_error_responses[@intFromEnum(http_errors.HttpErrors.http_error_502_bad_gateway)]);
                try self.cache_entry.markUpdated(allocator, io);
            }

            pub fn onAborted(self: *HttpCacheResponse, allocator: std.mem.Allocator, handler: Lambda(?*anyopaque, &.{ std.mem.Allocator, std.Io }, anyerror!void)) *HttpCacheResponse {
                handler.deinit(allocator);
                return self;
            }

            pub fn cork(self: *HttpCacheResponse, allocator: std.mem.Allocator, io: std.Io, handler: Lambda(?*anyopaque, &.{ std.mem.Allocator, std.Io }, anyerror!void)) !*HttpCacheResponse {
                defer handler.deinit(allocator);
                try handler.call(.{ allocator, io });
                return self;
            }
        };

        const GetCtx = struct {
            cache: *Self,
            handler: Lambda(?*anyopaque, &.{ std.mem.Allocator, std.Io, *HttpCacheResponse, *HttpRequest }, anyerror!void),
            options: HttpCacheOptions,

            pub fn init(allocator: std.mem.Allocator, cache: *Self, handler: Lambda(?*anyopaque, &.{ std.mem.Allocator, std.Io, *HttpCacheResponse, *HttpRequest }, anyerror!void), opts: HttpCacheOptions) !*GetCtx {
                const self = try allocator.create(GetCtx);
                self.* = .{
                    .cache = cache,
                    .handler = handler,
                    .options = opts,
                };
                return self;
            }

            pub fn deinit(allocator: std.mem.Allocator, ctx: ?*anyopaque) void {
                const self: *GetCtx = @ptrCast(@alignCast(ctx));
                self.handler.deinit(allocator);
                allocator.destroy(self);
            }
        };

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            var iter = self.cache.iterator();
            while (iter.next()) |entry| {
                entry.value_ptr.*.deinit(allocator);
                // TODO: if we have to allocate key string value, free
            }
            self.cache.deinit(allocator);
        }

        pub fn get(self: *Self, allocator: std.mem.Allocator, url: []const u8, handler: Lambda(?*anyopaque, &.{ std.mem.Allocator, std.Io, *HttpCacheResponse, *HttpRequest }, anyerror!void), cache_options: HttpCacheOptions) !*T {
            _ = try @as(*T, @fieldParentPtr("http_cache", self)).get(allocator, url, .init(try GetCtx.init(allocator, self, handler, cache_options), (struct {
                pub fn call(ctx: ?*anyopaque, allocator_: std.mem.Allocator, io: std.Io, res: *HttpResponse(T.Ssl), req: *HttpRequest) !void {
                    const get_ctx: *GetCtx = @ptrCast(@alignCast(ctx));
                    const cache_key = req.getFullUrl();
                    const now = @as(*LoopData, @ptrCast(@alignCast(@as(*zs.Loop, @ptrCast(@alignCast(try Loop.get(allocator_, io, null)))).ext[0].get(*LoopData).?))).cache_timepoint;
                    const lower_expiry = get_ctx.options.lower_expiry;
                    const upper_expiry = get_ctx.options.upper_expiry;
                    if (get_ctx.cache.cache.get(cache_key)) |entry| {
                        if (entry.never_initialized) {
                            _ = try entry.addDependentWaitingRequest(allocator_, res);
                            return;
                        } else if (entry.created.toSeconds() + @as(i64, @intCast(upper_expiry)) > now.toSeconds()) {
                            if (entry.status.len != 0) {
                                _ = try res.writeStatus(allocator_, entry.status);
                            }
                            var i: usize = 0;
                            while (i < entry.headers[0].items.len) : (i += 2) {
                                _ = try res.writeHeader(allocator_, entry.headers[0].items[i], entry.headers[0].items[i + 1]);
                            }
                            try res.end(allocator_, io, entry.buffer[0].items, false);
                            if (entry.created.toSeconds() + @as(i64, @intCast(lower_expiry)) < now.toSeconds()) {
                                if (!entry.updating_cache) {
                                    entry.updating_cache = true;
                                    // TODO: we probably need to free this somewhere
                                    const caching_res = try HttpCacheResponse.init(allocator_, entry);
                                    defer caching_res.deinit(allocator_); // maybe here?
                                    try get_ctx.handler.call(.{ allocator_, io, caching_res, req });
                                }
                            }
                            return;
                        }
                        if (entry.updating_cache) {
                            _ = try entry.addDependentWaitingRequest(allocator_, res);
                            return;
                        } else {
                            entry.deinit(allocator_);
                        }
                    }
                    const cache_entry = try CacheEntry.init(allocator_);
                    try get_ctx.cache.cache.put(allocator_, cache_key, cache_entry);
                    // TODO: we probably need to free this somewhere
                    const caching_res = try HttpCacheResponse.init(allocator_, cache_entry);
                    defer caching_res.deinit(allocator_); // maybe here?
                    _ = try cache_entry.addDependentWaitingRequest(allocator_, res);
                    try get_ctx.handler.call(.{ allocator_, io, caching_res, req });
                }
            }).call, GetCtx.deinit));
            return @fieldParentPtr("http_cache", self);
        }
    };
}
