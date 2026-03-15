# blitz ⚡

A blazing-fast HTTP/1.1 micro web framework for Zig.

## Features

- **Radix-trie router** with path parameters (`:id`) and wildcards (`*filepath`)
- **Zero-copy HTTP parsing** — request data stays in the read buffer
- **Epoll + SO_REUSEPORT** — one accept socket per core, no lock contention
- **Pre-computed responses** — bypass serialization for static content
- **Pipeline batching** — handle multiple HTTP requests per read
- **Middleware chain** — composable middleware with short-circuit support
- **Route groups** — organize routes under shared prefixes
- **JSON builder** — comptime-powered zero-allocation JSON serialization
- **Static file serving** — serve files from disk with MIME detection, path traversal protection, and cache control
- **Query string parsing** — structured typed query params with URL decoding
- **Connection pooling** — pre-allocated ConnState objects, zero malloc/free per connection
- **Structured errors** — consistent JSON error responses out of the box
- **Clean API** — define routes and handlers, blitz handles the rest

## Quick Start

```zig
const std = @import("std");
const blitz = @import("blitz");

fn hello(_: *blitz.Request, res: *blitz.Response) void {
    _ = res.text("Hello, World!");
}

fn greet(req: *blitz.Request, res: *blitz.Response) void {
    const name = req.params.get("name") orelse "stranger";
    _ = res.text(name);
}

pub fn main() !void {
    var router = blitz.Router.init(std.heap.c_allocator);
    router.get("/", hello);
    router.get("/hello/:name", greet);

    var server = blitz.Server.init(&router, .{ .port = 8080 });
    try server.listen();
}
```

## API

### Router

```zig
var router = blitz.Router.init(allocator);

router.get("/path", handler);
router.post("/path", handler);
router.put("/path", handler);
router.delete("/path", handler);
router.patch("/path", handler);
router.head("/path", handler);
router.options("/path", handler);
router.route(.PATCH, "/path", handler);

// Path parameters
router.get("/users/:id", getUserHandler);

// Wildcards
router.get("/static/*filepath", staticHandler);

// Custom 404 (or use the built-in JSON one)
router.notFound(blitz.jsonNotFoundHandler);
```

### Middleware

Middleware functions run before every handler. Return `true` to continue, `false` to short-circuit (e.g., auth failure).

```zig
// Simple middleware signature: fn(*Request, *Response) bool
fn cors(_: *blitz.Request, res: *blitz.Response) bool {
    res.headers.set("Access-Control-Allow-Origin", "*");
    return true; // continue to next middleware / handler
}

fn auth(req: *blitz.Request, res: *blitz.Response) bool {
    if (req.headers.get("Authorization") == null) {
        blitz.unauthorized(res, "Token required");
        return false; // stop here — don't call the handler
    }
    return true;
}

// Register middleware (runs in order)
router.use(cors);
router.use(auth);
```

### Route Groups

Groups share a URL prefix — great for versioned APIs.

```zig
const api = router.group("/api/v1");
api.get("/users", listUsers);       // matches /api/v1/users
api.get("/users/:id", getUser);     // matches /api/v1/users/:id
api.post("/users", createUser);     // matches /api/v1/users

// Nested groups
const admin = api.group("/admin");
admin.get("/stats", adminStats);    // matches /api/v1/admin/stats
```

### Request

```zig
fn handler(req: *blitz.Request, res: *blitz.Response) void {
    // Method
    if (req.method == .GET) { ... }

    // Path parameters
    const id = req.params.get("id") orelse "unknown";

    // Simple query parameter lookup (zero-copy)
    const page = req.queryParam("page") orelse "1";

    // Structured query parsing with typed access
    const q = req.queryParsed();
    const limit = q.getInt("limit", i64) orelse 20;
    const asc = q.getBool("asc") orelse true;
    _ = limit;
    _ = asc;

    // URL-decoded query param
    var decode_buf: [256]u8 = undefined;
    const search = q.getDecode("q", &decode_buf);
    _ = search;

    // Headers
    const ct = req.headers.get("Content-Type");

    // Body
    if (req.body) |body| { ... }
}
```

### Response

```zig
fn handler(_: *blitz.Request, res: *blitz.Response) void {
    // Plain text
    _ = res.text("hello");

    // JSON (raw string)
    _ = res.json("{\"ok\":true}");

    // HTML
    _ = res.html("<h1>Hello</h1>");

    // Custom status
    _ = res.setStatus(.not_found).text("Not Found");

    // Custom headers
    res.headers.set("X-Custom", "value");

    // Pre-computed raw response (maximum performance)
    _ = res.rawResponse("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok");
}
```

### JSON Builder

Zero-allocation JSON serialization powered by comptime. Writes directly into caller-provided buffers.

```zig
// Serialize a struct (comptime field introspection)
var buf: [512]u8 = undefined;
const json_str = blitz.Json.stringify(&buf, .{
    .name = "Alice",
    .age = @as(i64, 30),
    .active = true,
}) orelse return error.BufferOverflow;
_ = res.json(json_str);

// Build JSON objects manually
var obj_buf: [256]u8 = undefined;
var obj = blitz.JsonObject.init(&obj_buf);
obj.field("id", @as(i64, 1));
obj.field("name", "Alice");
obj.field("tags", @as([]const []const u8, &.{ "admin", "user" }));
const body = obj.finish() orelse "{}";
_ = res.json(body);

// Build JSON arrays
var arr_buf: [256]u8 = undefined;
var arr = blitz.JsonArray.init(&arr_buf);
arr.push(@as(i64, 1));
arr.push(@as(i64, 2));
arr.push(@as(i64, 3));
const list = arr.finish() orelse "[]";

// Supports: structs, slices, ints, floats, bools, strings,
//           optionals (null fields skipped), enums (as strings)
```

### Query String Parsing

Structured query string parsing with typed access, URL decoding, multi-value support, and iteration.

```zig
fn search(req: *blitz.Request, res: *blitz.Response) void {
    const q = req.queryParsed(); // GET /search?q=hello+world&page=2&debug

    // Simple string lookup (raw, no decoding)
    const term = q.get("q");                          // "hello+world"

    // URL-decoded value
    var buf: [256]u8 = undefined;
    const decoded = q.getDecode("q", &buf);           // "hello world"
    _ = decoded;

    // Typed access
    const page = q.getInt("page", i64) orelse 1;      // 2
    const debug = q.getBool("debug") orelse false;     // false (key exists but no value)
    _ = page;
    _ = debug;

    // Check key existence (even without value)
    if (q.has("debug")) { ... }

    // Multi-value params: /search?tag=zig&tag=http&tag=fast
    var tags: [8][]const u8 = undefined;
    const n = q.getAll("tag", &tags);                  // n=3
    _ = n;

    // Iterate all params
    var it = q.iterator();
    while (it.next()) |param| {
        // param.key, param.value
        _ = param;
    }

    _ = res.json("{\"ok\":true}");
}
```

**URL decoding** is also available standalone:
```zig
var buf: [256]u8 = undefined;
const decoded = blitz.urlDecode(&buf, "hello%20world+foo"); // "hello world foo"
```

### Static File Serving

Serve files from disk with automatic MIME type detection, directory traversal protection, and optional cache control.

```zig
// Serve files from ./public at /static/*
router.staticDir("/static", "./public", .{});

// With options
router.staticDir("/assets", "./dist", .{
    .cache_control = "public, max-age=31536000",  // immutable assets
    .index = true,                                  // serve index.html for directories
    .max_file_size = 10 * 1024 * 1024,             // 10MB max
});
```

**Features:**
- **40+ MIME types** — HTML, CSS, JS, images, fonts, media, archives, WASM
- **Path traversal protection** — rejects `../`, absolute paths, null bytes
- **Directory index** — automatically serves `index.html` for directory paths
- **Cache-Control** — optional header for browser caching
- **GET/HEAD only** — other methods fall through to route matching

### Error Handling

Structured JSON error responses with convenience helpers.

```zig
// In a handler:
fn getUser(req: *blitz.Request, res: *blitz.Response) void {
    const id = req.params.get("id") orelse {
        blitz.badRequest(res, "Missing user ID");
        return;
    };
    // ... look up user ...
    blitz.notFound(res, "User not found");
}

// Available error helpers:
blitz.badRequest(res, "message");      // 400
blitz.unauthorized(res, "message");    // 401
blitz.forbidden(res, "message");       // 403
blitz.notFound(res, "message");        // 404
blitz.methodNotAllowed(res, "msg");    // 405
blitz.internalError(res, "message");   // 500

// Generic:
blitz.sendError(res, .bad_request, "Custom message");

// Response format: {"error":{"status":400,"message":"Missing user ID"}}

// Built-in JSON 404 handler for the router:
router.notFound(blitz.jsonNotFoundHandler);
```

### Server

```zig
var server = blitz.Server.init(&router, .{
    .port = 8080,
    .threads = null, // auto-detect CPU count
});
try server.listen();
```

## Architecture

```
src/
├── blitz.zig          # Module root — re-exports everything
├── blitz/
│   ├── types.zig      # Request, Response, Method, StatusCode, Headers
│   ├── router.zig     # Radix-trie router with middleware, groups, params & wildcards
│   ├── parser.zig     # Zero-copy HTTP/1.1 request parser
│   ├── server.zig     # Epoll event loop, connection management
│   ├── pool.zig       # Connection pool — pre-allocated ConnState objects
│   ├── query.zig      # Query string parser with URL decoding and typed access
│   ├── json.zig       # Comptime JSON serializer (Json, JsonObject, JsonArray)
│   ├── errors.zig     # Structured error responses (sendError, badRequest, etc.)
│   ├── static.zig     # Static file serving (MIME detection, path security, file reading)
│   └── tests.zig      # Unit tests for all modules (111 tests)
├── main.zig           # HttpArena benchmark entry point
examples/
└── hello.zig          # Example app with all features
```

## Design Decisions

- **No allocations in hot path** — responses written to pre-allocated buffers
- **Edge-triggered epoll** — fewer syscalls than level-triggered
- **SO_REUSEPORT** — kernel distributes connections across worker threads
- **Pre-computed responses** — full HTTP response built at startup for static data
- **Radix trie over hash map** — better cache locality for path matching
- **Linear middleware** — `fn(*Req, *Res) bool` is simpler and faster than callback chains
- **Route groups** — prefix concatenation at init time, zero runtime overhead
- **Comptime JSON** — Zig's comptime introspects struct fields at compile time, no reflection cost at runtime
- **Static file serving** — MIME detection, path sanitization, and file reading with configurable cache headers
- **Connection pool** — pre-allocated ConnState per worker thread, O(1) acquire/release, fallback to heap when exhausted
- **Query parsing** — structured Query type with getInt/getBool/getAll/getDecode, zero-copy raw access or URL-decoded

## Building

```bash
zig build -Doptimize=ReleaseFast
```

## Testing

```bash
zig build test
```

## Running

```bash
./zig-out/bin/blitz
```

## HttpArena

blitz is built to compete in [HttpArena](https://github.com/MDA2AV/HttpArena) benchmarks. See `meta.json` for the benchmark configuration.

## License

MIT
