const http_parser = @import("http_parser.zig");
const std = @import("std");

const HttpRequest = http_parser.HttpRequest;
const HttpResponse = @import("http_response.zig").HttpResponse;
const HttpRouter = @import("http_router.zig").HttpRouter;
const Lambda = @import("lambda.zig").Lambda;

pub fn HttpContextData(comptime ssl: bool) type {
    return struct {
        const Self = @This();

        pub const RouterData = struct {
            http_response: *HttpResponse(ssl),
            http_request: *HttpRequest,
        };

        filter_handlers: std.ArrayList(Lambda(?*anyopaque, &.{ *HttpResponse(ssl), i32 }, void)) = .empty,
        missing_server_name_handler: ?Lambda(?*anyopaque, &.{[:0]const u8}, void) = null,
        router: HttpRouter(RouterData) = undefined,
        current_router: *HttpRouter(RouterData) = undefined,
        upgraded_websocket: ?*anyopaque = null,
        is_parsing_http: bool = false,
        child_apps: std.ArrayList(?*anyopaque) = .empty,
        round_robin: u32 = 0,

        pub fn init(self: *Self, allocator: std.mem.Allocator) !void {
            self.* = .{ .router = try HttpRouter(RouterData).init(allocator) };
            self.current_router = &self.router;
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            for (self.filter_handlers.items) |*item| {
                item.deinit(allocator);
            }
            self.filter_handlers.deinit(allocator);
            if (self.missing_server_name_handler) |*missing_server_name_handler| {
                missing_server_name_handler.deinit(allocator);
            }
            self.router.deinit(allocator);
            // TODO: maybe free `upgraded_websocket`?
            // TODO: maybe need to iterate and free `child_apps.items`?
            self.child_apps.deinit(allocator);
        }
    };
}
