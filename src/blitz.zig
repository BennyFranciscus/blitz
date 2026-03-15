//! # blitz ⚡
//!
//! A blazing-fast HTTP/1.1 micro web framework for Zig.
//!
//! Built on epoll with SO_REUSEPORT multi-threading, zero-copy parsing,
//! and a radix-trie router with path parameters.
//!
//! ## Quick Start
//!
//! ```zig
//! const blitz = @import("blitz");
//!
//! fn hello(_: *blitz.Request, res: *blitz.Response) void {
//!     _ = res.text("Hello, World!");
//! }
//!
//! fn greet(req: *blitz.Request, res: *blitz.Response) void {
//!     const name = req.params.get("name") orelse "stranger";
//!     // Use name to build response...
//!     _ = res.text(name);
//! }
//!
//! pub fn main() !void {
//!     var router = blitz.Router.init(std.heap.c_allocator);
//!     router.get("/", hello);
//!     router.get("/hello/:name", greet);
//!
//!     var server = blitz.Server.init(&router, .{ .port = 8080 });
//!     try server.listen();
//! }
//! ```

pub const types = @import("blitz/types.zig");
pub const router_mod = @import("blitz/router.zig");
pub const parser_mod = @import("blitz/parser.zig");
pub const server_mod = @import("blitz/server.zig");
pub const json_mod = @import("blitz/json.zig");
pub const errors_mod = @import("blitz/errors.zig");
pub const static_mod = @import("blitz/static.zig");

// Re-export main types for convenience
pub const Request = types.Request;
pub const Response = types.Response;
pub const Method = types.Method;
pub const StatusCode = types.StatusCode;
pub const Headers = types.Headers;
pub const HandlerFn = types.HandlerFn;
pub const MiddlewareFn = types.MiddlewareFn;
pub const Router = router_mod.Router;
pub const Group = router_mod.Group;
pub const Server = server_mod.Server;
pub const Config = server_mod.Config;

// JSON
pub const Json = json_mod.Json;
pub const JsonObject = json_mod.JsonObject;
pub const JsonArray = json_mod.JsonArray;

// Static file serving
pub const serveFile = static_mod.serveFile;
pub const mimeFromPath = static_mod.mimeFromPath;
pub const mimeFromExt = static_mod.mimeFromExt;
pub const sanitizePath = static_mod.sanitizePath;
pub const StaticDirConfig = static_mod.StaticDirConfig;

// Error handling
pub const sendError = errors_mod.sendError;
pub const badRequest = errors_mod.badRequest;
pub const unauthorized = errors_mod.unauthorized;
pub const forbidden = errors_mod.forbidden;
pub const notFound = errors_mod.notFound;
pub const methodNotAllowed = errors_mod.methodNotAllowed;
pub const internalError = errors_mod.internalError;
pub const jsonNotFoundHandler = errors_mod.jsonNotFoundHandler;
pub const jsonMethodNotAllowedHandler = errors_mod.jsonMethodNotAllowedHandler;

// Utilities
pub const writeUsize = types.writeUsize;
pub const writeI64 = types.writeI64;
pub const asciiEqlIgnoreCase = types.asciiEqlIgnoreCase;

// Parser
pub const parse = parser_mod.parse;

// Tests (pulled in by `zig build test`)
test {
    _ = @import("blitz/tests.zig");
    _ = @import("blitz/static.zig");
}
