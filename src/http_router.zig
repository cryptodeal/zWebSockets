const std = @import("std");
const Lambda = @import("lambda.zig").Lambda;

pub fn HttpRouter(comptime UserData: type) type {
    return struct {
        const Self = @This();

        pub const any_method_token = "*";

        pub const Priority = enum(u32) {
            high = 0xd0000000,
            medium = 0xe0000000,
            low = 0xf0000000,
        };

        pub const max_url_segments = 100;
        pub const handler_mask: u32 = 0x0fffffff;

        pub const Node = struct {
            name: []const u8,
            children: std.ArrayList(*Node) = .empty,
            handlers: std.ArrayList(u32) = .empty,
            is_high_priority: bool = false,

            pub fn init(allocator: std.mem.Allocator, name: []const u8) !*Node {
                const self = try allocator.create(Node);
                self.* = .{
                    .name = name,
                };
                return self;
            }

            pub fn deinit(self: *Node, allocator: std.mem.Allocator) void {
                for (self.children.items) |child| {
                    child.deinit(allocator);
                }
                // allocator.free(self.name);
                self.children.deinit(allocator);
                self.handlers.deinit(allocator);
                allocator.destroy(self);
            }
        };

        pub const RouteParameters = struct {
            params: [max_url_segments][]const u8 = undefined,
            params_top: i32 = -1,

            pub fn reset(self: *RouteParameters) void {
                self.params_top = -1;
            }

            pub fn push(self: *RouteParameters, param: []const u8) void {
                self.params_top += 1;
                self.params[@intCast(self.params_top)] = param;
            }

            pub fn pop(self: *RouteParameters) void {
                self.params_top -= 1;
            }
        };

        pub const Handler = Lambda(?*anyopaque, &.{ std.mem.Allocator, std.Io, *Self }, anyerror!bool);

        user_data: UserData = undefined,
        handlers: std.ArrayList(Handler) = .empty,
        current_url: []const u8 = undefined,
        url_segment_vector: [max_url_segments][]const u8 = undefined,
        url_segment_top: i32 = 0,
        root: Node = .{ .name = "rootNode" },
        route_parameters: RouteParameters = .{},

        fn lexicalOrder(name: []const u8) u32 {
            if (name.len == 0) {
                return 2;
            }
            if (name[0] == ':') {
                return 1;
            }
            if (name[0] == '*') {
                return 0;
            }
            return 2;
        }

        fn getNode(self: *Self, allocator: std.mem.Allocator, parent: *Node, child: []const u8, is_high_priority: bool) !*Node {
            for (parent.children.items) |node| {
                if (std.mem.eql(u8, node.name, child) and node.is_high_priority == is_high_priority) {
                    return node;
                }
            }

            const new_node = try Node.init(allocator, child);
            new_node.is_high_priority = is_high_priority;
            var idx: usize = parent.children.items.len;
            for (parent.children.items, 0..) |node, i| {
                if (new_node.is_high_priority != node.is_high_priority) {
                    if (new_node.is_high_priority) {
                        idx = i;
                        break;
                    }
                    continue;
                }
                if (node.name.len != 0 and (parent != &self.root) and (lexicalOrder(node.name) < lexicalOrder(new_node.name))) {
                    idx = i;
                    break;
                }
            }
            try parent.children.insert(allocator, idx, new_node);
            return new_node;
        }

        inline fn setUrl(self: *Self, url: []const u8) void {
            self.current_url = url;
            self.url_segment_top = -1;
        }

        inline fn getUrlSegment(self: *Self, url_segment: i32) struct { []const u8, bool } {
            if (url_segment > self.url_segment_top) {
                if (self.current_url.len == 0 or url_segment > (max_url_segments - 1)) {
                    return .{ &.{}, true };
                }
                self.current_url = self.current_url[1..];
                var segment_length = std.mem.findScalar(u8, self.current_url, '/');
                if (segment_length) |sl| {
                    self.url_segment_vector[@intCast(url_segment)] = self.current_url[0..sl];
                    self.url_segment_top += 1;
                    self.current_url = self.current_url[sl..];
                } else {
                    segment_length = self.current_url.len;
                    self.url_segment_vector[@intCast(url_segment)] = self.current_url[0..segment_length.?];
                    self.url_segment_top += 1;
                    self.current_url = self.current_url[segment_length.?..];
                }
            }
            return .{ self.url_segment_vector[@intCast(url_segment)], false };
        }

        fn executeHandlers(self: *Self, allocator: std.mem.Allocator, io: std.Io, parent: *Node, url_segment: i32, user_data: *UserData) !bool {
            const segment, const is_stop = self.getUrlSegment(url_segment);
            if (is_stop) {
                for (parent.handlers.items) |handler| {
                    if (try self.handlers.items[handler & handler_mask].call(.{ allocator, io, self })) {
                        return true;
                    }
                }
                return false;
            }

            for (parent.children.items) |p| {
                if (p.name.len != 0 and p.name[0] == '*') {
                    for (p.handlers.items) |handler| {
                        if (try self.handlers.items[handler & handler_mask].call(.{ allocator, io, self })) {
                            return true;
                        }
                    }
                } else if (p.name.len != 0 and p.name[0] == ':' and segment.len != 0) {
                    self.route_parameters.push(segment);
                    if (try self.executeHandlers(allocator, io, p, url_segment + 1, user_data)) {
                        return true;
                    }
                    self.route_parameters.pop();
                } else if (std.mem.eql(u8, p.name, segment)) {
                    if (try self.executeHandlers(allocator, io, p, url_segment + 1, user_data)) {
                        return true;
                    }
                }
            }
            return false;
        }

        fn findHandler(self: *Self, method: []const u8, pattern: []const u8, priority: Priority) u32 {
            for (self.root.children.items) |node| {
                if (std.mem.eql(u8, method, node.name)) {
                    self.setUrl(pattern);
                    var n = node;
                    var i: i32 = 0;
                    while (!self.getUrlSegment(i)[1]) : (i += 1) {
                        const segment = self.getUrlSegment(i)[0];
                        var next: ?*Node = null;
                        for (n.children.items) |child| {
                            if (((segment.len != 0 and child.name.len != 0 and segment[0] == ':' and child.name[0] == ':') or std.mem.eql(u8, child.name, segment)) and child.is_high_priority == (priority == .high)) {
                                next = child;
                                break;
                            }
                        }
                        if (next == null) {
                            return std.math.maxInt(u32);
                        }
                        n = next.?;
                    }
                    for (n.handlers.items) |handler| {
                        if ((handler & ~handler_mask) == @intFromEnum(priority)) {
                            return handler;
                        }
                    }
                    return std.math.maxInt(u32);
                }
            }
            return std.math.maxInt(u32);
        }

        pub fn init(allocator: std.mem.Allocator) !Self {
            var self: HttpRouter(UserData) = .{};
            _ = try self.getNode(allocator, &self.root, any_method_token, false);
            return self;
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            for (self.handlers.items) |*handler| {
                handler.deinit(allocator);
            }
            self.handlers.deinit(allocator);
            for (self.root.children.items) |child| {
                child.deinit(allocator);
            }
            self.root.children.deinit(allocator);
            self.root.handlers.deinit(allocator);
            // allocator.destroy(self);
        }

        pub fn getParameters(self: *Self) struct { i32, [*][]const u8 } {
            return .{ self.route_parameters.params_top, &self.route_parameters.params };
        }

        pub fn getUserData(self: *Self) *UserData {
            return &self.user_data;
        }

        pub fn route(self: *Self, allocator: std.mem.Allocator, io: std.Io, method: []const u8, url: []const u8) !bool {
            self.setUrl(url);
            self.route_parameters.reset();
            for (self.root.children.items) |p| {
                if (std.mem.eql(u8, p.name, method)) {
                    if (try self.executeHandlers(allocator, io, p, 0, &self.user_data)) {
                        return true;
                    } else {
                        break;
                    }
                }
            }

            if (self.root.children.items.len == 0) {
                @branchHint(.unlikely);
                return false;
            }
            return self.executeHandlers(allocator, io, self.root.children.items[self.root.children.items.len - 1], 0, &self.user_data);
        }

        pub fn add(self: *Self, allocator: std.mem.Allocator, methods: []const []const u8, pattern: []const u8, handler: Handler, priority: Priority) !void {
            _ = try self.remove(allocator, methods[0], pattern, priority);
            for (methods) |method| {
                var node = try self.getNode(allocator, &self.root, method, false);
                self.setUrl(pattern);
                var i: i32 = 0;
                while (!self.getUrlSegment(i)[1]) : (i += 1) {
                    var stripped_segment = self.getUrlSegment(i)[0];
                    if (stripped_segment.len != 0 and stripped_segment[0] == ':') {
                        stripped_segment = ":";
                    }
                    node = try self.getNode(allocator, node, stripped_segment, priority == Priority.high);
                }
                var idx: usize = node.handlers.items.len;
                for (node.handlers.items, 0..) |h, j| {
                    if (@as(u32, @intCast(@intFromEnum(priority) | self.handlers.items.len)) < h) {
                        idx = j;
                        break;
                    }
                }
                try node.handlers.insert(allocator, idx, @intCast(@intFromEnum(priority) | self.handlers.items.len));
            }
            try self.handlers.append(allocator, handler);
            std.sort.block(*Node, self.root.children.items, {}, (struct {
                pub fn call(_: void, lhs: *Node, rhs: *Node) bool {
                    if (std.mem.eql(u8, lhs.name, "GET") and !std.mem.eql(u8, rhs.name, "GET")) {
                        return true;
                    } else if (std.mem.eql(u8, rhs.name, "GET") and !std.mem.eql(u8, lhs.name, "GET")) {
                        return false;
                    } else if (std.mem.eql(u8, lhs.name, any_method_token) and !std.mem.eql(u8, rhs.name, any_method_token)) {
                        return false;
                    } else if (std.mem.eql(u8, rhs.name, any_method_token) and !std.mem.eql(u8, lhs.name, any_method_token)) {
                        return true;
                    } else {
                        return std.mem.lessThan(u8, lhs.name, rhs.name);
                    }
                }
            }).call);
        }

        pub fn cullNode(self: *Self, allocator: std.mem.Allocator, parent: ?*Node, node: *Node, handler: u32) bool {
            {
                var i: usize = 0;
                while (i < node.children.items.len) {
                    if (!self.cullNode(allocator, node, node.children.items[i], handler)) {
                        i += 1;
                    }
                }
            }
            if (parent) |p| {
                {
                    var i: usize = 0;
                    while (i < node.handlers.items.len) {
                        if ((node.handlers.items[i] & handler_mask) > (handler & handler_mask)) {
                            node.handlers.items[i] = ((node.handlers.items[i] & handler_mask) - 1) | (node.handlers.items[i] & ~handler_mask);
                        } else if (node.handlers.items[i] == handler) {
                            _ = node.handlers.orderedRemove(i);
                            continue;
                        }
                        i += 1;
                    }
                }
                if (node.handlers.items.len == 0 and node.children.items.len == 0) {
                    for (p.children.items, 0..) |child, i| {
                        if (child == node) {
                            const old_child = p.children.orderedRemove(i);
                            old_child.deinit(allocator);
                            return true;
                        }
                    }
                }
            }
            return false;
        }

        pub fn remove(self: *Self, allocator: std.mem.Allocator, method: []const u8, pattern: []const u8, priority: Priority) !bool {
            const handler = self.findHandler(method, pattern, priority);
            if (handler == std.math.maxInt(u32)) {
                return false;
            }
            _ = self.cullNode(allocator, null, &self.root, handler);
            var handler_fn = self.handlers.orderedRemove(handler & handler_mask);
            handler_fn.deinit(allocator);
            return true;
        }
    };
}

test "Method Priority" {
    const allocator = std.testing.allocator;
    var r = try HttpRouter(i32).init(allocator);
    defer r.deinit(allocator);
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(allocator);

    try r.add(allocator, &.{"*"}, "/static/route", .init(
        &result,
        (struct {
            pub fn call(ctx: ?*anyopaque, a: std.mem.Allocator, _: std.Io, _: *HttpRouter(i32)) !bool {
                var out: *std.ArrayList(u8) = @ptrCast(@alignCast(ctx));
                try out.appendSlice(a, "AS");
                return true;
            }
        }).call,
        null,
    ), .low);

    try r.add(allocator, &.{"PATCH"}, "/static/route", .init(
        &result,
        (struct {
            pub fn call(ctx: ?*anyopaque, a: std.mem.Allocator, _: std.Io, _: *HttpRouter(i32)) !bool {
                var out: *std.ArrayList(u8) = @ptrCast(@alignCast(ctx));
                try out.appendSlice(a, "PS");
                return false;
            }
        }).call,
        null,
    ), .medium);

    try r.add(allocator, &.{"GET"}, "/static/route", .init(
        &result,
        (struct {
            pub fn call(ctx: ?*anyopaque, a: std.mem.Allocator, _: std.Io, _: *HttpRouter(i32)) !bool {
                var out: *std.ArrayList(u8) = @ptrCast(@alignCast(ctx));
                try out.appendSlice(a, "GS");
                return true;
            }
        }).call,
        null,
    ), .medium);

    try std.testing.expect(try r.route(allocator, std.testing.io, "nonsense", "/static/route"));
    try std.testing.expect((try r.route(allocator, std.testing.io, "GET", "/static")) == false);
    try std.testing.expectEqualStrings("AS", result.items);

    result.clearAndFree(allocator);
    try std.testing.expect(try r.route(allocator, std.testing.io, "POST", "/static/route"));
    try std.testing.expectEqualStrings("AS", result.items);

    result.clearAndFree(allocator);
    try std.testing.expect(try r.route(allocator, std.testing.io, "GET", "/static/route"));
    try std.testing.expectEqualStrings("GS", result.items);

    result.clearAndFree(allocator);
    try std.testing.expect(try r.route(allocator, std.testing.io, "PATCH", "/static/route"));
    try std.testing.expectEqualStrings("PSAS", result.items);
}

test "Deep Parameter Routes" {
    const allocator = std.testing.allocator;
    var r = try HttpRouter(i32).init(allocator);
    defer r.deinit(allocator);
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(allocator);

    try r.add(allocator, &.{"GET"}, "/something/:id/sync", .init(
        &result,
        (struct {
            pub fn call(ctx: ?*anyopaque, a: std.mem.Allocator, _: std.Io, _: *HttpRouter(i32)) !bool {
                var out: *std.ArrayList(u8) = @ptrCast(@alignCast(ctx));
                try out.appendSlice(a, "ETT");
                return false;
            }
        }).call,
        null,
    ), .medium);

    try r.add(allocator, &.{"GET"}, "/something/:somethingId/pin", .init(
        &result,
        (struct {
            pub fn call(ctx: ?*anyopaque, a: std.mem.Allocator, _: std.Io, _: *HttpRouter(i32)) !bool {
                var out: *std.ArrayList(u8) = @ptrCast(@alignCast(ctx));
                try out.appendSlice(a, "TVÅ");
                return false;
            }
        }).call,
        null,
    ), .medium);

    try r.add(allocator, &.{"GET"}, "/something/:id/:attribute", .init(
        &result,
        (struct {
            pub fn call(ctx: ?*anyopaque, a: std.mem.Allocator, _: std.Io, _: *HttpRouter(i32)) !bool {
                var out: *std.ArrayList(u8) = @ptrCast(@alignCast(ctx));
                try out.appendSlice(a, "TRE");
                return false;
            }
        }).call,
        null,
    ), .medium);

    try std.testing.expect((try r.route(allocator, std.testing.io, "GET", "/something/1234/pin")) == false);
    try std.testing.expectEqualStrings("TVÅTRE", result.items);

    result.clearAndFree(allocator);
    try std.testing.expect((try r.route(allocator, std.testing.io, "GET", "/something/1234/sync")) == false);
    try std.testing.expectEqualStrings("ETTTRE", result.items);
}

test "Pattern Priority" {
    const allocator = std.testing.allocator;
    var r = try HttpRouter(i32).init(allocator);
    defer r.deinit(allocator);
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(allocator);

    try r.add(allocator, &.{"*"}, "/a/b/c", .init(
        &result,
        (struct {
            pub fn call(ctx: ?*anyopaque, a: std.mem.Allocator, _: std.Io, _: *HttpRouter(i32)) !bool {
                var out: *std.ArrayList(u8) = @ptrCast(@alignCast(ctx));
                try out.appendSlice(a, "AS");
                return false;
            }
        }).call,
        null,
    ), .low);

    try r.add(allocator, &.{"GET"}, "/a/:b/c", .init(
        &result,
        (struct {
            pub fn call(ctx: ?*anyopaque, a: std.mem.Allocator, _: std.Io, _: *HttpRouter(i32)) !bool {
                var out: *std.ArrayList(u8) = @ptrCast(@alignCast(ctx));
                try out.appendSlice(a, "GP");
                return false;
            }
        }).call,
        null,
    ), .medium);

    try r.add(allocator, &.{"GET"}, "/a/*", .init(
        &result,
        (struct {
            pub fn call(ctx: ?*anyopaque, a: std.mem.Allocator, _: std.Io, _: *HttpRouter(i32)) !bool {
                var out: *std.ArrayList(u8) = @ptrCast(@alignCast(ctx));
                try out.appendSlice(a, "GW");
                return false;
            }
        }).call,
        null,
    ), .medium);

    try r.add(allocator, &.{"GET"}, "/a/b/c", .init(
        &result,
        (struct {
            pub fn call(ctx: ?*anyopaque, a: std.mem.Allocator, _: std.Io, _: *HttpRouter(i32)) !bool {
                var out: *std.ArrayList(u8) = @ptrCast(@alignCast(ctx));
                try out.appendSlice(a, "GS");
                return false;
            }
        }).call,
        null,
    ), .medium);

    try r.add(allocator, &.{"POST"}, "/a/:b/c", .init(
        &result,
        (struct {
            pub fn call(ctx: ?*anyopaque, a: std.mem.Allocator, _: std.Io, _: *HttpRouter(i32)) !bool {
                var out: *std.ArrayList(u8) = @ptrCast(@alignCast(ctx));
                try out.appendSlice(a, "PP");
                return false;
            }
        }).call,
        null,
    ), .medium);

    try r.add(allocator, &.{"*"}, "/a/:b/c", .init(
        &result,
        (struct {
            pub fn call(ctx: ?*anyopaque, a: std.mem.Allocator, _: std.Io, _: *HttpRouter(i32)) !bool {
                var out: *std.ArrayList(u8) = @ptrCast(@alignCast(ctx));
                try out.appendSlice(a, "AP");
                return false;
            }
        }).call,
        null,
    ), .low);

    try std.testing.expect((try r.route(allocator, std.testing.io, "POST", "/a/b/c")) == false);
    try std.testing.expectEqualStrings("PPASAP", result.items);

    result.clearAndFree(allocator);
    try std.testing.expect((try r.route(allocator, std.testing.io, "GET", "/a/b/c")) == false);
    try std.testing.expectEqualStrings("GSGPGWASAP", result.items);
}

test "Upgrade" {
    const allocator = std.testing.allocator;
    var r = try HttpRouter(i32).init(allocator);
    defer r.deinit(allocator);
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(allocator);

    try r.add(allocator, &.{"GET"}, "/something", .init(
        &result,
        (struct {
            pub fn call(ctx: ?*anyopaque, a: std.mem.Allocator, _: std.Io, _: *HttpRouter(i32)) !bool {
                var out: *std.ArrayList(u8) = @ptrCast(@alignCast(ctx));
                try out.appendSlice(a, "GS");
                return true;
            }
        }).call,
        null,
    ), .medium);

    try r.add(allocator, &.{"GET"}, "/*", .init(
        &result,
        (struct {
            pub fn call(ctx: ?*anyopaque, a: std.mem.Allocator, _: std.Io, _: *HttpRouter(i32)) !bool {
                var out: *std.ArrayList(u8) = @ptrCast(@alignCast(ctx));
                try out.appendSlice(a, "GW");
                return false;
            }
        }).call,
        null,
    ), .medium);

    try r.add(allocator, &.{"GET"}, "/*", .init(
        &result,
        (struct {
            pub fn call(ctx: ?*anyopaque, a: std.mem.Allocator, _: std.Io, _: *HttpRouter(i32)) !bool {
                var out: *std.ArrayList(u8) = @ptrCast(@alignCast(ctx));
                try out.appendSlice(a, "WW");
                return false;
            }
        }).call,
        null,
    ), .high);

    try std.testing.expect(try r.route(allocator, std.testing.io, "GET", "/something"));
    try std.testing.expectEqualStrings("WWGS", result.items);
    result.clearAndFree(allocator);

    try std.testing.expect((try r.route(allocator, std.testing.io, "GET", "/")) == false);
    try std.testing.expectEqualStrings("WWGW", result.items);
}

test "Bug Reports" {
    const allocator = std.testing.allocator;

    {
        var r = try HttpRouter(i32).init(allocator);
        defer r.deinit(allocator);
        var result: std.ArrayList(u8) = .empty;
        defer result.deinit(allocator);

        try r.add(allocator, &.{"GET"}, "/route", .init(
            &result,
            (struct {
                pub fn call(ctx: ?*anyopaque, a: std.mem.Allocator, _: std.Io, _: *HttpRouter(i32)) !bool {
                    var out: *std.ArrayList(u8) = @ptrCast(@alignCast(ctx));
                    try out.appendSlice(a, "ROUTE");
                    return true;
                }
            }).call,
            (struct {
                pub fn call(_: std.mem.Allocator, _: ?*anyopaque) void {}
            }).call,
        ), .medium);

        try r.add(allocator, &.{"GET"}, "/route/:id", .init(
            &result,
            (struct {
                pub fn call(ctx: ?*anyopaque, a: std.mem.Allocator, _: std.Io, _: *HttpRouter(i32)) !bool {
                    var out: *std.ArrayList(u8) = @ptrCast(@alignCast(ctx));
                    try out.appendSlice(a, "ROUID");
                    return true;
                }
            }).call,
            (struct {
                pub fn call(_: std.mem.Allocator, _: ?*anyopaque) void {}
            }).call,
        ), .medium);

        _ = try r.route(allocator, std.testing.io, "GET", "/route/21");
        try std.testing.expectEqualStrings("ROUID", result.items);

        result.clearAndFree(allocator);
        _ = try r.route(allocator, std.testing.io, "GET", "/route");
        try std.testing.expectEqualStrings("ROUTE", result.items);

        result.clearAndFree(allocator);
        _ = try r.remove(allocator, "GET", "/route", .medium);
        _ = try r.route(allocator, std.testing.io, "GET", "/route");
        try std.testing.expectEqualStrings("", result.items);

        _ = try r.remove(allocator, "GET", "/route/:id", .medium);
        _ = try r.route(allocator, std.testing.io, "GET", "/route/21");
        try std.testing.expectEqualStrings("", result.items);
    }
    {
        var r = try HttpRouter(i32).init(allocator);
        defer r.deinit(allocator);
        var result: std.ArrayList(u8) = .empty;
        defer result.deinit(allocator);

        try r.add(allocator, &.{"GET"}, "/foo//////bar/baz/qux", .init(
            &result,
            (struct {
                pub fn call(ctx: ?*anyopaque, a: std.mem.Allocator, _: std.Io, _: *HttpRouter(i32)) !bool {
                    var out: *std.ArrayList(u8) = @ptrCast(@alignCast(ctx));
                    try out.appendSlice(a, "MANYSLASH");
                    return false;
                }
            }).call,
            (struct {
                pub fn call(_: std.mem.Allocator, _: ?*anyopaque) void {}
            }).call,
        ), .medium);

        try r.add(allocator, &.{"GET"}, "/foo", .init(
            &result,
            (struct {
                pub fn call(ctx: ?*anyopaque, a: std.mem.Allocator, _: std.Io, _: *HttpRouter(i32)) !bool {
                    var out: *std.ArrayList(u8) = @ptrCast(@alignCast(ctx));
                    try out.appendSlice(a, "FOO");
                    return false;
                }
            }).call,
            (struct {
                pub fn call(_: std.mem.Allocator, _: ?*anyopaque) void {}
            }).call,
        ), .medium);

        _ = try r.route(allocator, std.testing.io, "GET", "/foo");
        _ = try r.route(allocator, std.testing.io, "GET", "/foo/");
        _ = try r.route(allocator, std.testing.io, "GET", "/foo//bar/baz/qux");
        _ = try r.route(allocator, std.testing.io, "GET", "/foo//////bar/baz/qux");
        try std.testing.expectEqualStrings("FOOMANYSLASH", result.items);
    }
    {
        var r = try HttpRouter(i32).init(allocator);
        defer r.deinit(allocator);
        var result: std.ArrayList(u8) = .empty;
        defer result.deinit(allocator);

        try r.add(allocator, &.{"GET"}, "/test/*", .init(
            &result,
            (struct {
                pub fn call(ctx: ?*anyopaque, a: std.mem.Allocator, _: std.Io, _: *HttpRouter(i32)) !bool {
                    var out: *std.ArrayList(u8) = @ptrCast(@alignCast(ctx));
                    try out.appendSlice(a, "TEST");
                    return false;
                }
            }).call,
            (struct {
                pub fn call(_: std.mem.Allocator, _: ?*anyopaque) void {}
            }).call,
        ), .medium);
        _ = try r.route(allocator, std.testing.io, "GET", "/test/");
        try std.testing.expectEqualStrings("TEST", result.items);
    }

    {
        var r = try HttpRouter(i32).init(allocator);
        defer r.deinit(allocator);
        var result: std.ArrayList(u8) = .empty;
        defer result.deinit(allocator);

        try r.add(allocator, &.{"GET"}, "/*", .init(
            &result,
            (struct {
                pub fn call(ctx: ?*anyopaque, a: std.mem.Allocator, _: std.Io, _: *HttpRouter(i32)) !bool {
                    var out: *std.ArrayList(u8) = @ptrCast(@alignCast(ctx));
                    try out.appendSlice(a, "WW");
                    return false;
                }
            }).call,
            (struct {
                pub fn call(_: std.mem.Allocator, _: ?*anyopaque) void {}
            }).call,
        ), .high);

        try r.add(allocator, &.{"GET"}, "/ok", .init(
            &result,
            (struct {
                pub fn call(ctx: ?*anyopaque, a: std.mem.Allocator, _: std.Io, _: *HttpRouter(i32)) !bool {
                    var out: *std.ArrayList(u8) = @ptrCast(@alignCast(ctx));
                    try out.appendSlice(a, "GS");
                    return false;
                }
            }).call,
            (struct {
                pub fn call(_: std.mem.Allocator, _: ?*anyopaque) void {}
            }).call,
        ), .medium);

        try r.add(allocator, &.{"GET"}, "/*", .init(
            &result,
            (struct {
                pub fn call(ctx: ?*anyopaque, a: std.mem.Allocator, _: std.Io, _: *HttpRouter(i32)) !bool {
                    var out: *std.ArrayList(u8) = @ptrCast(@alignCast(ctx));
                    try out.appendSlice(a, "GW");
                    return false;
                }
            }).call,
            (struct {
                pub fn call(_: std.mem.Allocator, _: ?*anyopaque) void {}
            }).call,
        ), .medium);

        _ = try r.route(allocator, std.testing.io, "GET", "/ok");
        try std.testing.expectEqualStrings("WWGSGW", result.items);
    }

    {
        var r = try HttpRouter(i32).init(allocator);
        defer r.deinit(allocator);
        var result: std.ArrayList(u8) = .empty;
        defer result.deinit(allocator);

        try r.add(allocator, &.{"GET"}, "/", .init(
            &result,
            (struct {
                pub fn call(ctx: ?*anyopaque, a: std.mem.Allocator, _: std.Io, _: *HttpRouter(i32)) !bool {
                    var out: *std.ArrayList(u8) = @ptrCast(@alignCast(ctx));
                    try out.appendSlice(a, "WS");
                    return false;
                }
            }).call,
            (struct {
                pub fn call(_: std.mem.Allocator, _: ?*anyopaque) void {}
            }).call,
        ), .high);

        try r.add(allocator, &.{"GET"}, "/", .init(
            &result,
            (struct {
                pub fn call(ctx: ?*anyopaque, a: std.mem.Allocator, _: std.Io, _: *HttpRouter(i32)) !bool {
                    var out: *std.ArrayList(u8) = @ptrCast(@alignCast(ctx));
                    try out.appendSlice(a, "GS");
                    return false;
                }
            }).call,
            (struct {
                pub fn call(_: std.mem.Allocator, _: ?*anyopaque) void {}
            }).call,
        ), .medium);

        _ = try r.route(allocator, std.testing.io, "GET", "/");
        try std.testing.expectEqualStrings("WSGS", result.items);
    }

    {
        var r = try HttpRouter(i32).init(allocator);
        defer r.deinit(allocator);
        var result: std.ArrayList(u8) = .empty;
        defer result.deinit(allocator);

        try r.add(allocator, &.{"GET"}, "/*", .init(
            &result,
            (struct {
                pub fn call(ctx: ?*anyopaque, a: std.mem.Allocator, _: std.Io, _: *HttpRouter(i32)) !bool {
                    var out: *std.ArrayList(u8) = @ptrCast(@alignCast(ctx));
                    try out.appendSlice(a, "WW");
                    return false;
                }
            }).call,
            (struct {
                pub fn call(_: std.mem.Allocator, _: ?*anyopaque) void {}
            }).call,
        ), .high);

        try r.add(allocator, &.{"GET"}, "/static", .init(
            &result,
            (struct {
                pub fn call(ctx: ?*anyopaque, a: std.mem.Allocator, _: std.Io, _: *HttpRouter(i32)) !bool {
                    var out: *std.ArrayList(u8) = @ptrCast(@alignCast(ctx));
                    try out.appendSlice(a, "GSL");
                    return false;
                }
            }).call,
            (struct {
                pub fn call(_: std.mem.Allocator, _: ?*anyopaque) void {}
            }).call,
        ), .medium);

        try r.add(allocator, &.{"*"}, "/*", .init(
            &result,
            (struct {
                pub fn call(ctx: ?*anyopaque, a: std.mem.Allocator, _: std.Io, _: *HttpRouter(i32)) !bool {
                    var out: *std.ArrayList(u8) = @ptrCast(@alignCast(ctx));
                    try out.appendSlice(a, "AW");
                    return false;
                }
            }).call,
            (struct {
                pub fn call(_: std.mem.Allocator, _: ?*anyopaque) void {}
            }).call,
        ), .low);

        _ = try r.route(allocator, std.testing.io, "GET", "/static");
        try std.testing.expectEqualStrings("WWGSLAW", result.items);
    }

    {
        var r = try HttpRouter(i32).init(allocator);
        defer r.deinit(allocator);
        var result: std.ArrayList(u8) = .empty;
        defer result.deinit(allocator);

        try r.add(allocator, &.{"GET"}, "/*", .init(
            &result,
            (struct {
                pub fn call(ctx: ?*anyopaque, a: std.mem.Allocator, _: std.Io, _: *HttpRouter(i32)) !bool {
                    var out: *std.ArrayList(u8) = @ptrCast(@alignCast(ctx));
                    try out.appendSlice(a, "WW");
                    return false;
                }
            }).call,
            (struct {
                pub fn call(_: std.mem.Allocator, _: ?*anyopaque) void {}
            }).call,
        ), .high);

        try r.add(allocator, &.{"GET"}, "/", .init(
            &result,
            (struct {
                pub fn call(ctx: ?*anyopaque, a: std.mem.Allocator, _: std.Io, _: *HttpRouter(i32)) !bool {
                    var out: *std.ArrayList(u8) = @ptrCast(@alignCast(ctx));
                    try out.appendSlice(a, "GSS");
                    return false;
                }
            }).call,
            (struct {
                pub fn call(_: std.mem.Allocator, _: ?*anyopaque) void {}
            }).call,
        ), .medium);

        try r.add(allocator, &.{"GET"}, "/static", .init(
            &result,
            (struct {
                pub fn call(ctx: ?*anyopaque, a: std.mem.Allocator, _: std.Io, _: *HttpRouter(i32)) !bool {
                    var out: *std.ArrayList(u8) = @ptrCast(@alignCast(ctx));
                    try out.appendSlice(a, "GSL");
                    return false;
                }
            }).call,
            (struct {
                pub fn call(_: std.mem.Allocator, _: ?*anyopaque) void {}
            }).call,
        ), .medium);

        try r.add(allocator, &.{"*"}, "/*", .init(
            &result,
            (struct {
                pub fn call(ctx: ?*anyopaque, a: std.mem.Allocator, _: std.Io, _: *HttpRouter(i32)) !bool {
                    var out: *std.ArrayList(u8) = @ptrCast(@alignCast(ctx));
                    try out.appendSlice(a, "AW");
                    return false;
                }
            }).call,
            (struct {
                pub fn call(_: std.mem.Allocator, _: ?*anyopaque) void {}
            }).call,
        ), .low);

        _ = try r.route(allocator, std.testing.io, "GET", "/static");
        try std.testing.expectEqualStrings("WWGSLAW", result.items);
    }

    {
        var r = try HttpRouter(i32).init(allocator);
        defer r.deinit(allocator);
        var result: std.ArrayList(u8) = .empty;
        defer result.deinit(allocator);

        try r.add(allocator, &.{"GET"}, "/foo", .init(
            &result,
            (struct {
                pub fn call(ctx: ?*anyopaque, a: std.mem.Allocator, _: std.Io, _: *HttpRouter(i32)) !bool {
                    var out: *std.ArrayList(u8) = @ptrCast(@alignCast(ctx));
                    try out.appendSlice(a, "FOO");
                    return false;
                }
            }).call,
            (struct {
                pub fn call(_: std.mem.Allocator, _: ?*anyopaque) void {}
            }).call,
        ), .medium);

        try r.add(allocator, &.{"GET"}, "/:id", .init(
            &result,
            (struct {
                pub fn call(ctx: ?*anyopaque, a: std.mem.Allocator, _: std.Io, _: *HttpRouter(i32)) !bool {
                    var out: *std.ArrayList(u8) = @ptrCast(@alignCast(ctx));
                    try out.appendSlice(a, "ID");
                    return false;
                }
            }).call,
            (struct {
                pub fn call(_: std.mem.Allocator, _: ?*anyopaque) void {}
            }).call,
        ), .medium);

        try r.add(allocator, &.{"GET"}, "/1ab", .init(
            &result,
            (struct {
                pub fn call(ctx: ?*anyopaque, a: std.mem.Allocator, _: std.Io, _: *HttpRouter(i32)) !bool {
                    var out: *std.ArrayList(u8) = @ptrCast(@alignCast(ctx));
                    try out.appendSlice(a, "ONEAB");
                    return false;
                }
            }).call,
            (struct {
                pub fn call(_: std.mem.Allocator, _: ?*anyopaque) void {}
            }).call,
        ), .medium);

        _ = try r.route(allocator, std.testing.io, "GET", "/1ab");
        try std.testing.expectEqualStrings("ONEABID", result.items);
    }

    {
        var r = try HttpRouter(i32).init(allocator);
        defer r.deinit(allocator);
        var result: std.ArrayList(u8) = .empty;
        defer result.deinit(allocator);

        try r.add(allocator, &.{"GET"}, "/*", .init(
            &result,
            (struct {
                pub fn call(ctx: ?*anyopaque, a: std.mem.Allocator, _: std.Io, _: *HttpRouter(i32)) !bool {
                    var out: *std.ArrayList(u8) = @ptrCast(@alignCast(ctx));
                    try out.appendSlice(a, "STAR");
                    return false;
                }
            }).call,
            (struct {
                pub fn call(_: std.mem.Allocator, _: ?*anyopaque) void {}
            }).call,
        ), .medium);

        try r.add(allocator, &.{"GET"}, "/", .init(
            &result,
            (struct {
                pub fn call(ctx: ?*anyopaque, a: std.mem.Allocator, _: std.Io, _: *HttpRouter(i32)) !bool {
                    var out: *std.ArrayList(u8) = @ptrCast(@alignCast(ctx));
                    try out.appendSlice(a, "STATIC");
                    return false;
                }
            }).call,
            (struct {
                pub fn call(_: std.mem.Allocator, _: ?*anyopaque) void {}
            }).call,
        ), .medium);

        _ = try r.route(allocator, std.testing.io, "GET", "/");
        try std.testing.expectEqualStrings("STATICSTAR", result.items);
    }
}

test "Parameters" {
    const allocator = std.testing.allocator;
    var r = try HttpRouter(i32).init(allocator);
    defer r.deinit(allocator);
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(allocator);

    try r.add(allocator, &.{"GET"}, "/candy/:kind/*", .init(
        &result,
        (struct {
            pub fn call(ctx: ?*anyopaque, a: std.mem.Allocator, _: std.Io, h: *HttpRouter(i32)) !bool {
                const params_top, const params = h.getParameters();
                try std.testing.expect(params_top == 0);
                try std.testing.expectEqualStrings("lollipop", params[0]);
                var out: *std.ArrayList(u8) = @ptrCast(@alignCast(ctx));
                try out.appendSlice(a, "GPW");
                return false;
            }
        }).call,
        null,
    ), .medium);

    try r.add(allocator, &.{"GET"}, "/candy/lollipop/*", .init(
        &result,
        (struct {
            pub fn call(ctx: ?*anyopaque, a: std.mem.Allocator, _: std.Io, h: *HttpRouter(i32)) !bool {
                const params_top, _ = h.getParameters();
                try std.testing.expect(params_top == -1);
                var out: *std.ArrayList(u8) = @ptrCast(@alignCast(ctx));
                try out.appendSlice(a, "GLW");
                return false;
            }
        }).call,
        null,
    ), .medium);

    try r.add(allocator, &.{"GET"}, "/candy/:kind/:action", .init(
        &result,
        (struct {
            pub fn call(ctx: ?*anyopaque, a: std.mem.Allocator, _: std.Io, h: *HttpRouter(i32)) !bool {
                const params_top, const params = h.getParameters();
                try std.testing.expect(params_top == 1);
                try std.testing.expectEqualStrings("lollipop", params[0]);
                try std.testing.expectEqualStrings("eat", params[1]);
                var out: *std.ArrayList(u8) = @ptrCast(@alignCast(ctx));
                try out.appendSlice(a, "GPP");
                return false;
            }
        }).call,
        null,
    ), .medium);

    try r.add(allocator, &.{"GET"}, "/candy/lollipop/:action", .init(
        &result,
        (struct {
            pub fn call(ctx: ?*anyopaque, a: std.mem.Allocator, _: std.Io, h: *HttpRouter(i32)) !bool {
                const params_top, const params = h.getParameters();
                try std.testing.expect(params_top == 0);
                try std.testing.expectEqualStrings("eat", params[0]);
                var out: *std.ArrayList(u8) = @ptrCast(@alignCast(ctx));
                try out.appendSlice(a, "GLP");
                return false;
            }
        }).call,
        null,
    ), .medium);

    try r.add(allocator, &.{"GET"}, "/candy/lollipop/eat", .init(
        &result,
        (struct {
            pub fn call(ctx: ?*anyopaque, a: std.mem.Allocator, _: std.Io, h: *HttpRouter(i32)) !bool {
                const params_top, _ = h.getParameters();
                try std.testing.expect(params_top == -1);
                var out: *std.ArrayList(u8) = @ptrCast(@alignCast(ctx));
                try out.appendSlice(a, "GLS");
                return false;
            }
        }).call,
        null,
    ), .medium);

    _ = try r.route(allocator, std.testing.io, "GET", "/candy/lollipop/eat");
    try std.testing.expectEqualStrings("GLSGLPGLWGPPGPW", result.items);
    result.clearAndFree(allocator);

    _ = try r.route(allocator, std.testing.io, "GET", "/candy/lollipop/");
    _ = try r.route(allocator, std.testing.io, "GET", "/candy/lollipop");
    _ = try r.route(allocator, std.testing.io, "GET", "/candy/");
    try std.testing.expectEqualStrings("GLWGPW", result.items);
}

test "Performance" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var r = try HttpRouter(i32).init(allocator);
    defer r.deinit(allocator);

    try r.add(allocator, &.{"GET"}, "/*", .init(
        null,
        (struct {
            pub fn call(_: ?*anyopaque, _: std.mem.Allocator, _: std.Io, _: *HttpRouter(i32)) !bool {
                return true;
            }
        }).call,
        null,
    ), .medium);

    try r.add(allocator, &.{"*"}, "/*", .init(
        null,
        (struct {
            pub fn call(_: ?*anyopaque, _: std.mem.Allocator, _: std.Io, _: *HttpRouter(i32)) !bool {
                return true;
            }
        }).call,
        null,
    ), .medium);

    const start = std.Io.Timestamp.now(io, .real);
    for (0..1000000) |_| {
        _ = try r.route(allocator, std.testing.io, "GET", "/something");
        _ = try r.route(allocator, std.testing.io, "other", "/whatever");
    }
    const end = std.Io.Timestamp.now(io, .real);

    const duration = start.durationTo(end).toMilliseconds();

    std.log.info("\nDuration: {d} ms\n", .{duration});
}
