const std = @import("std");

pub threadlocal var prng: std.Random.DefaultPrng = undefined;
pub threadlocal var rand: ?std.Random = null;

pub fn init(io: std.Io) void {
    if (rand == null) return;
    prng = .init(blk: {
        var seed: u64 = undefined;
        io.random(std.mem.asBytes(&seed));
        break :blk seed;
    });
    rand = prng.random();
}
