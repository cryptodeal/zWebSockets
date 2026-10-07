const args_parser = @import("args");
const builtin = @import("builtin");
const std = @import("std");
const zws = @import("zWebSockets");
const zs = @import("zSockets");

const zlib = zws.zlib;

const Options = struct {
    // This declares long options for double hyphen
    root: []const u8 = undefined,
    cooldown: i64 = undefined,
};

var cooldown: i64 = 0;
var file_map: std.StringHashMapUnmanaged(@Tuple(&.{ []const u8, bool })) = .empty;
var map_mutex: std.Io.Mutex = .init;
var inotify_fd: i32 = undefined;
var file_sizes: usize = 0;

fn loadFileContent(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, sub_path: []const u8) !@Tuple(&.{ []const u8, bool }) {
    var file = dir.openFile(io, sub_path, .{}) catch {
        return .{ &.{}, false };
    };
    defer file.close(io);
    const size = try file.length(io);
    const content = try allocator.alloc(u8, size);
    @memset(content, 0);
    var reader = file.reader(io, content);
    try reader.interface.fill(size);
    if (zws.env.with_zlib) {
        var z_stream: zlib.z_stream = .{};
        if (zlib.deflateInit2(&z_stream, zlib.Z_BEST_COMPRESSION, zlib.Z_DEFLATED, 15 + 16, 8, zlib.Z_DEFAULT_STRATEGY) == zlib.Z_OK) {
            z_stream.next_in = @ptrCast(@alignCast(content.ptr));
            z_stream.avail_in = @intCast(content.len);
            const bound = zlib.deflateBound(&z_stream, @intCast(content.len));
            var compressed = try allocator.alloc(u8, @intCast(bound));
            @memset(compressed, 0);
            z_stream.next_out = @ptrCast(@alignCast(compressed.ptr));
            z_stream.avail_out = @intCast(bound);
            const ret = zlib.deflate(&z_stream, zlib.Z_FINISH);
            if (ret == zlib.Z_STREAM_END) {
                const compressed_size: usize = @intCast(z_stream.total_out);
                _ = zlib.deflateEnd(&z_stream);
                compressed = try allocator.realloc(compressed, compressed_size);
                if (compressed_size < size) {
                    allocator.free(content);
                    file_sizes += compressed_size;
                    return .{ compressed, true };
                }
            } else {
                allocator.free(compressed);
                _ = zlib.deflateEnd(&z_stream);
            }
        }
    }
    file_sizes += size;
    return .{ content, false };
}

fn loadFiles(allocator: std.mem.Allocator, io: std.Io, root: []const u8, opts: struct { inotify_fd: i32 = -1 }) !void {
    file_sizes = 0;
    const cwd = std.Io.Dir.cwd();
    var new_map: std.StringHashMapUnmanaged(@Tuple(&.{ []const u8, bool })) = .empty;
    var dir: std.Io.Dir = switch (std.fs.path.isAbsolute(root)) {
        true => try .openDirAbsolute(io, root, .{}),
        else => try .openDir(cwd, io, root, .{}),
    };
    defer dir.close(io);
    var iterator = try dir.walk(allocator);
    defer iterator.deinit();
    while (try iterator.next(io)) |entry| {
        if (entry.kind == .file and !std.mem.startsWith(u8, entry.path, ".")) {
            const relative_path = try std.fmt.allocPrint(allocator, "/{s}", .{entry.path});
            errdefer allocator.free(relative_path);
            const loaded_data = try loadFileContent(allocator, io, dir, entry.path);
            errdefer allocator.free(loaded_data[0]);
            try new_map.put(allocator, relative_path, loaded_data);
            if (comptime builtin.os.tag == .linux) {
                if (opts.inotify_fd >= 0) {
                    const realpath = try dir.realPathFileAlloc(io, entry.path, allocator);
                    defer allocator.free(realpath);
                    _ = std.os.linux.inotify_add_watch(opts.inotify_fd, realpath.ptr, std.os.linux.IN.MODIFY);
                }
            }
        } else if (entry.kind == .directory) {
            if (comptime builtin.os.tag == .linux) {
                if (opts.inotify_fd >= 0) {
                    const realpath = try dir.realPathFileAlloc(io, entry.path, allocator);
                    defer allocator.free(realpath);
                    _ = std.os.linux.inotify_add_watch(opts.inotify_fd, realpath.ptr, std.os.linux.IN.CREATE | std.os.linux.IN.MODIFY | std.os.linux.IN.MOVE);
                }
            }
        }
    }
    {
        try map_mutex.lock(io);
        defer map_mutex.unlock(io);
        // free file_map entries
        var file_map_iter = file_map.iterator();
        while (file_map_iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr[0]);
        }
        file_map.deinit(allocator);
        file_map = new_map.move();
        std.debug.print("Loaded {d} MB of files into RAM\n", .{(file_sizes / 1024 / 1024)});
    }
}

fn inotifyReloaderFunction(allocator: std.mem.Allocator, io: std.Io, root: []const u8, fd: i32) !void {
    var buffer: [4096]u8 = undefined;
    while (true) {
        _ = try std.posix.read(fd, &buffer);
        try loadFiles(allocator, io, root, .{ .inotify_fd = fd });
        if (cooldown != 0) {
            std.debug.print("Sleeping for {d} seconds after reload\n", .{cooldown});
            try std.Io.sleep(io, std.Io.Duration.fromSeconds(cooldown));
        }
    }
}

pub fn main(init: std.process.Init) !void {
    const args = try args_parser.parseForCurrentProcess(Options, init, .print);
    defer args.deinit();

    var gpa = std.heap.DebugAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    // const allocator = std.heap.smp_allocator;

    if (args.options.cooldown < 0) {
        std.debug.print("Cooldown must be a non-negative integer\n", .{});
        return error.InvalidCooldown;
    }
    cooldown = args.options.cooldown;
    const root = args.options.root;

    var inotify_reloader: std.Thread = undefined;

    if (comptime builtin.os.tag == .linux) {
        inotify_fd = blk: {
            const rc = std.os.linux.inotify_init1(0);
            switch (std.os.linux.errno(rc)) {
                .SUCCESS => break :blk @intCast(rc),
                .INVAL => unreachable,
                .MFILE => return error.ProcessFdQuotaExceeded,
                .NFILE => return error.SystemFdQuotaExceeded,
                .NOMEM => return error.SystemResources,
                else => |err| return std.posix.unexpectedErrno(err),
            }
        };
        try loadFiles(allocator, init.io, root, .{ .inotify_fd = inotify_fd });
        inotify_reloader = try std.Thread.spawn(.{ .allocator = allocator }, inotifyReloaderFunction, .{ allocator, init.io, root, inotify_fd });
    } else {
        try loadFiles(allocator, init.io, root, .{});
    }

    var app = try zws.App.init(allocator, init.io, .{});
    defer app.deinit(allocator, init.io) catch unreachable;

    var handler_key: u8 = undefined;
    try (try zws.Loop.get(allocator, init.io, null)).addPostHandler(allocator, &handler_key, .init(null, (struct {
        pub fn call(_: ?*anyopaque, _: std.mem.Allocator, io: std.Io, _: *zws.Loop) !void {
            try map_mutex.lock(io);
            defer map_mutex.unlock(io);
        }
    }).call, null));

    try (try zws.Loop.get(allocator, init.io, null)).addPreHandler(allocator, &handler_key, .init(
        null,
        (struct {
            pub fn call(_: ?*anyopaque, _: std.mem.Allocator, io: std.Io, _: *zws.Loop) !void {
                try map_mutex.lock(io);
                defer map_mutex.unlock(io);
            }
        }).call,
        null,
    ));

    _ = try app.get(allocator, "/", .init(
        null,
        (struct {
            pub fn call(_: ?*anyopaque, a: std.mem.Allocator, io: std.Io, res: *zws.HttpResponse(zws.App.Ssl), _: *zws.HttpRequest) !void {
                if (file_map.get("/index.html")) |it| {
                    if (it[1]) {
                        _ = try res.writeHeader(a, "Content-Encoding", "gzip");
                    }
                    try res.end(a, io, it[0], false);
                } else {
                    _ = try res.writeStatus(a, "404 Not Found");
                    _ = try res.end(a, io, "Not Found", false);
                }
            }
        }).call,
        null,
    ));

    _ = try app.get(allocator, "/*", .init(
        null,
        (struct {
            pub fn call(_: ?*anyopaque, a: std.mem.Allocator, io: std.Io, res: *zws.HttpResponse(zws.App.Ssl), req: *zws.HttpRequest) !void {
                if (file_map.get(req.getUrl())) |it| {
                    if (it[1]) {
                        _ = try res.writeHeader(a, "Content-Encoding", "gzip");
                    }
                    try res.end(a, io, it[0], false);
                } else {
                    _ = try res.writeStatus(a, "404 Not Found");
                    _ = try res.end(a, io, "Not Found", false);
                }
            }
        }).call,
        null,
    ));

    _ = try app.listen(allocator, init.io, .{ .port = 8000 }, .init(
        null,
        (struct {
            pub fn call(_: ?*anyopaque, _: std.mem.Allocator, _: std.Io, ls: ?*zs.ListenSocket) !void {
                if (ls) |_| {
                    std.debug.print("Listening on port: 8000\n", .{});
                }
            }
        }).call,
        null,
    ));

    _ = try app.run(allocator, init.io);
}
