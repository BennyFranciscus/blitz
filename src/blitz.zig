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

// Re-export main types for convenience
pub const Request = types.Request;
pub const Response = types.Response;
pub const Method = types.Method;
pub const StatusCode = types.StatusCode;
pub const Headers = types.Headers;
pub const HandlerFn = types.HandlerFn;
pub const Router = router_mod.Router;
pub const Server = server_mod.Server;
pub const Config = server_mod.Config;

// Utilities
pub const writeUsize = types.writeUsize;
pub const writeI64 = types.writeI64;
pub const asciiEqlIgnoreCase = types.asciiEqlIgnoreCase;

// Parser
pub const parse = parser_mod.parse;
