# blitz ⚡

A blazing-fast HTTP/1.1 micro web framework for Zig.

## Features

- **Radix-trie router** with path parameters (`:id`) and wildcards (`*filepath`)
- **Zero-copy HTTP parsing** — request data stays in the read buffer
- **Epoll + SO_REUSEPORT** — one accept socket per core, no lock contention
- **Pre-computed responses** — bypass serialization for static content
- **Pipeline batching** — handle multiple HTTP requests per read
- **Clean API** — define routes and handlers, blitz handles the rest

## Quick Start

```zig
const std = @import("std");
const blitz = @import("blitz.zig");

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
router.route(.PATCH, "/path", handler);

// Path parameters
router.get("/users/:id", getUserHandler);

// Wildcards
router.get("/static/*filepath", staticHandler);

// Custom 404
router.notFound(my404Handler);
```

### Request

```zig
fn handler(req: *blitz.Request, res: *blitz.Response) void {
    // Method
    if (req.method == .GET) { ... }

    // Path parameters
    const id = req.params.get("id") orelse "unknown";

    // Query parameters
    const page = req.queryParam("page") orelse "1";

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

    // JSON
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
│   ├── router.zig     # Radix-trie router with path params & wildcards
│   ├── parser.zig     # Zero-copy HTTP/1.1 request parser
│   └── server.zig     # Epoll event loop, connection management
├── main.zig           # HttpArena benchmark entry point
examples/
└── hello.zig          # Simple example app
```

## Design Decisions

- **No allocations in hot path** — responses are written to a pre-allocated ArrayList
- **Edge-triggered epoll** — fewer syscalls than level-triggered
- **SO_REUSEPORT** — kernel distributes connections across worker threads
- **Pre-computed responses** — for benchmarks, build the full HTTP response at startup
- **Radix trie over hash map** — better cache locality for path matching

## Building

```bash
zig build -Doptimize=ReleaseFast
```

## Running

```bash
./zig-out/bin/blitz
```

## HttpArena

blitz is built to compete in [HttpArena](https://github.com/MDA2AV/HttpArena) benchmarks. See `meta.json` for the benchmark configuration.

## License

MIT
