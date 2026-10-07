const std = @import("std");

pub const app = @import("app.zig");
pub const App = app.TemplatedApp(false);
pub const CompressOptions = @import("per_message_deflate.zig").CompressOptions;
pub const env = @import("env");
pub const HttpResponse = @import("http_response.zig").HttpResponse;
pub const HttpRequest = @import("http_parser.zig").HttpRequest;
pub const LocalCluster = @import("local_cluster.zig").LocalCluster;
pub const Loop = @import("loop.zig").Loop;
pub const OpCode = @import("websocket_protocol.zig").OpCode;
pub const PreparedMessage = @import("loop.zig").PreparedMessage;
pub const SslApp = app.TemplatedApp(true);
pub const WebSocket = @import("websocket.zig").WebSocket;

pub const libdeflate = @import("libdeflate");
pub const zlib = @import("zlib");

test {
    std.testing.refAllDecls(@import("bloom_filter.zig"));
    std.testing.refAllDecls(@import("chunked_encoding.zig"));
    std.testing.refAllDecls(@import("http_parser.zig"));
    // TODO: test hangs; debug and re-enable
    std.testing.refAllDecls(@import("http_response.zig"));
    std.testing.refAllDecls(@import("http_router.zig"));
    std.testing.refAllDecls(@import("query_parser.zig"));
    std.testing.refAllDecls(@import("topic_tree.zig"));
    std.testing.refAllDecls(@import("websocket_extensions.zig"));
    std.testing.refAllDecls(@import("lambda.zig"));
}
