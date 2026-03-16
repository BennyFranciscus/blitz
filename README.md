<div align="center">

# ⚡ blitz

**A blazing-fast HTTP/1.1 micro web framework for Zig.**

[![HttpArena](https://img.shields.io/badge/HttpArena-%233_Baseline-blue)](https://httparena.fly.dev)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Zig](https://img.shields.io/badge/Zig-0.14+-orange)](https://ziglang.org)

</div>

---

## Highlights

- 🏎️ **3.06M req/s baseline** — #3 on [HttpArena](https://github.com/MDA2AV/HttpArena), ahead of nginx, hyper, and actix
- 🚀 **38.9M req/s pipelined** — pipeline batching for maximum throughput
- 🧠 **Zero-copy HTTP parsing** — request data stays in the read buffer, no allocations in the hot path
- ⚙️ **Dual backend** — epoll (default) or io_uring with multishot accept, buffer rings, and zero-copy send
- 🌳 **Radix-trie router** — path params, wildcards, route groups, per-route middleware
- 📦 **Batteries included** — JSON serialization + parsing, cookies, compression, CORS, rate limiting, WebSocket, static files
- 🔧 **Context injection** — typed application state accessible in every handler via `req.context(T)`
- 🔌 **Graceful shutdown** — SIGTERM/SIGINT handling, connection draining, Docker-ready
- 📝 **Structured logging** — text or JSON format, latency tracking, slow request detection
- 🗄️ **SQLite integration** — zero-overhead C interop wrapper, per-thread connections, prepared statements
- 🎨 **Template engine** — comptime-powered Mustache-like templates with HTML auto-escaping, conditionals, loops

## Quick Start

```zig
const std = @import("std");
const blitz = @import("blitz");

fn hello(_: *blitz.Request, res: *blitz.Response) void {
    _ = res.text("Hello, World!");
}

pub fn main() !void {
    var router = blitz.Router.init(std.heap.c_allocator);
    router.get("/", hello);

    var server = blitz.Server.init(&router, .{ .port = 8080 });
    try server.listen();
}
```

## Installation

Add blitz to your `build.zig.zon`:

```sh
zig fetch --save "https://github.com/BennyFranciscus/blitz/archive/main.tar.gz"
```

Then in `build.zig`:

```zig
const blitz_dep = b.dependency("blitz", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("blitz", blitz_dep.module("blitz"));
exe.linkLibC();
```

## Benchmarks

Tested on [HttpArena](https://github.com/MDA2AV/HttpArena) — 64-core AMD Threadripper, io_uring backend.

| Profile | Throughput |
|---------|-----------|
| Baseline (4096 conn) | **3.06M** req/s |
| Pipelined (p=16) | **38.9M** req/s |
| JSON (8.4KB body) | **1.66M** req/s |
| WebSocket echo (p=16) | **50.2M** msg/s |
| Noisy (mixed traffic) | **1.99M** req/s |

## Context Injection

Pass application state (DB connections, config, services) to handlers:

```zig
const AppState = struct {
    db: *Database,
    config: *AppConfig,
};

fn getUsers(req: *blitz.Request, res: *blitz.Response) void {
    const app = req.context(AppState);
    // Use app.db, app.config, etc.
}

pub fn main() !void {
    var state = AppState{ .db = &db, .config = &config };
    var router = blitz.Router.init(std.heap.c_allocator);
    router.get("/users", getUsers);

    var server = blitz.Server.init(&router, .{
        .port = 8080,
        .context = @ptrCast(&state),
    });
    try server.listen();
}
```

## SQLite

Built-in SQLite wrapper via `@cImport` — zero overhead, per-thread connections:

```zig
const blitz = @import("blitz");

// Open database (per-thread, no mutex overhead)
var db = try blitz.SqliteDb.open("/data/app.db", .{
    .readonly = true,
    .mmap_size = 64 * 1024 * 1024, // 64MB mmap for faster reads
});
defer db.close();

// Prepared statement — reusable across requests
var stmt = try db.prepare(
    "SELECT id, name, price FROM items WHERE price BETWEEN ?1 AND ?2 LIMIT 50"
);
defer stmt.finalize();

// Bind parameters, iterate rows
try stmt.bindDouble(1, 10.0);
try stmt.bindDouble(2, 50.0);

while (try stmt.step()) {
    const id = stmt.columnInt(0);
    const name = stmt.columnText(1);  // zero-copy slice, valid until next step/reset
    const price = stmt.columnDouble(2);
    // ... process row
}

stmt.reset(); // reuse with new bindings
```

Requires `libsqlite3-dev` at build time. Add to `build.zig`:
```zig
exe.linkSystemLibrary("sqlite3");
```

## Template Engine

Comptime-powered Mustache-like templates — parsed at compile time, zero allocations at runtime:

```zig
const blitz = @import("blitz");

// Templates are compiled at comptime — zero parsing overhead at runtime
const page = blitz.Template.compile(
    \\<h1>{{ title }}</h1>
    \\{{# if logged_in }}<p>Welcome back, {{ username }}!</p>{{/ if }}
    \\{{# unless logged_in }}<p>Please <a href="/login">log in</a>.</p>{{/ unless }}
    \\<ul>{{# each items }}<li>{{ . }}</li>{{/ each }}</ul>
);

fn handler(_: *blitz.Request, res: *blitz.Response) void {
    const items = [_][]const u8{ "Routing", "Middleware", "WebSocket" };
    var buf: [4096]u8 = undefined;
    const html = page.render(&buf, .{
        .title = "Blitz Features",
        .logged_in = true,
        .username = "Alice",
        .items = @as([]const []const u8, &items),
    }) orelse return;
    _ = res.html(html);
}
```

**Syntax:** `{{ var }}` (HTML-escaped), `{{{ var }}}` (raw), `{{# if cond }}...{{/ if }}`, `{{# unless cond }}...{{/ unless }}`, `{{# each list }}{{ . }}{{/ each }}`, `{{! comment }}`

Runtime templates also supported via `blitz.parseRuntimeTemplate()` for user-provided templates.

## Documentation

📖 **[Full API Documentation](https://bennyfranciscus.github.io/blitz/)** — routing, middleware, JSON, WebSocket, compression, and more.

## Building & Testing

```bash
zig build -Doptimize=ReleaseFast    # build
zig build test                       # 308 unit tests

# Run with epoll (default)
./zig-out/bin/blitz

# Run with io_uring (Linux 5.19+)
BLITZ_URING=1 ./zig-out/bin/blitz
```

## License

[MIT](LICENSE)
