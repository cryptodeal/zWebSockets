const env = @import("env");
const std = @import("std");

pub const HttpErrors = enum(u32) {
    @"505_http_version_not_supported" = 1,
    @"431_request_header_fields_too_large" = 2,
    @"400_bad_request" = 3,
};

pub const http_error_responses = if (!env.httpresponse_no_writemark) [_][]const u8{
    "",
    "HTTP/1.1 505 HTTP Version Not Supported\r\nConnection: close\r\n\r\n<h1>HTTP Version Not Supported</h1><p>This server does not support HTTP/1.0.</p><hr><i>uWebSockets/20 Server</i>",
    "HTTP/1.1 431 Request Header Fields Too Large\r\nConnection: close\r\n\r\n<h1>Request Header Fields Too Large</h1><hr><i>uWebSockets/20 Server</i>",
    "HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n<h1>Bad Request</h1><hr><i>uWebSockets/20 Server</i>",
} else [_][]const u8{
    "",
    "HTTP/1.1 505 HTTP Version Not Supported\r\nConnection: close\r\n\r\n",
    "HTTP/1.1 431 Request Header Fields Too Large\r\nConnection: close\r\n\r\n",
    "HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n",
};
