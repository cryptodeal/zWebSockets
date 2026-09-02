const std = @import("std");

pub const ProxyHdrV2 = extern struct {
    sig: [12]u8,
    ver_cmd: u8,
    fam: u8,
    len: u16,
};

pub const ProxyAddr = extern union {
    ipv4_addr: extern struct {
        src_addr: u32,
        dst_addr: u32,
        src_port: u16,
        dst_port: u16,
    },
    ipv6_addr: extern struct {
        src_addr: [16]u8,
        dst_addr: [16]u8,
        src_port: u16,
        dst_port: u16,
    },
};

pub const ProxyParser = struct {
    addr: ProxyAddr = undefined,
    done: bool = false,
    family: u8 = 0,

    pub fn getSourceAddress(self: *const ProxyParser) ?[]const u8 {
        if (self.family == 0) {
            return null;
        }
        if ((self.family & 0xf0) >> 4 == 1) {
            return std.mem.asBytes(&self.addr.ipv4_addr.src_addr);
        } else {
            return &self.addr.ipv6_addr.src_addr;
        }
    }

    pub fn getSourcePort(self: *const ProxyParser) u32 {
        if (self.family == 0) {
            return 0;
        }

        if ((self.family & 0xf0) >> 4 == 1) {
            return self.addr.ipv4_addr.src_port;
        } else {
            return self.addr.ipv6_addr.src_port;
        }
    }

    pub fn parse(self: *ProxyParser, data: []const u8) struct { bool, u32 } {
        if (data.len < 4) {
            return .{ false, 0 };
        }

        if (std.mem.eql(u8, data, "\r\n\r\n")) {
            return .{ true, 0 };
        }

        if (data.len < 16) {
            return .{ false, 0 };
        }

        var header: ProxyHdrV2 = undefined;
        @memcpy(std.mem.asBytes(&header), data[0..16]);
        if (!std.mem.eql(u8, &header.sig, "\x0D\x0A\x0D\x0A\x00\x0D\x0A\x51\x55\x49\x54\x0A")) {
            return .{ false, 0 };
        }

        if ((header.ver_cmd & 0xf0) >> 4 != 2) {
            return .{ false, 0 };
        }

        const host_length = std.mem.nativeToBig(u16, header.len);

        if (data.len < 16 + host_length) {
            return .{ false, 0 };
        }

        if (@sizeOf(ProxyAddr) < host_length) {
            return .{ false, 0 };
        }

        if (!self.done) {
            self.family = header.fam;
            @memcpy(std.mem.asBytes(&self.addr), data[16 .. 16 + host_length]);
            self.done = true;
        }
        return .{ true, 16 + host_length };
    }
};
