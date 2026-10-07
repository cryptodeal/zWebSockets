const std = @import("std");

pub fn Lambda(comptime Context: type, comptime ParamTypes: []const type, comptime ReturnType: type) type {
    return struct {
        const Self = @This();

        context: Context,

        func: *const @Fn(blk: {
            var param_types: [ParamTypes.len + 1]type = undefined;
            param_types[0] = Context;
            for (ParamTypes, 1..) |t, i| {
                param_types[i] = t;
            }
            break :blk &param_types;
        }, blk: {
            var param_attrs: [1 + ParamTypes.len]std.builtin.Type.Fn.Param.Attributes = @splat(.{});
            break :blk &param_attrs;
        }, ReturnType, .{}),

        deinit_: ?*const fn (std.mem.Allocator, Context) void = null,

        pub fn init(ctx: Context, func: @FieldType(Self, "func"), deinit_: ?*const fn (std.mem.Allocator, Context) void) Self {
            return .{
                .context = ctx,
                .func = func,
                .deinit_ = deinit_,
            };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            if (self.deinit_) |deinit_| deinit_(allocator, self.context);
        }

        pub fn call(self: *const Self, args: anytype) ReturnType {
            return @call(.auto, self.func, .{self.context} ++ args);
        }
    };
}

test "Basic Lambda" {
    const FnCtx = struct { res: i32 };
    var res: FnCtx = .{ .res = 0 };

    var cb = Lambda(*FnCtx, &.{ i32, i32 }, void).init(
        &res,
        (struct {
            pub fn call(a: *FnCtx, b: i32, c: i32) void {
                a.res += b * c;
            }
        }).call,
        (struct {
            pub fn call(_: std.mem.Allocator, b: *FnCtx) void {
                b.res = 0;
            }
        }).call,
    );

    cb.call(.{ 1, 2 });
    try std.testing.expect(res.res == 2);
}
